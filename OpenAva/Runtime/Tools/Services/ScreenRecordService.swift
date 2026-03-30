import AVFoundation
import OpenClawKit
import ReplayKit

final class ScreenRecordService: @unchecked Sendable {
    private struct UncheckedSendableBox<T>: @unchecked Sendable {
        let value: T
    }

    private final class CaptureState: @unchecked Sendable {
        private let lock = NSLock()
        var writer: AVAssetWriter?
        var videoInput: AVAssetWriterInput?
        var audioInput: AVAssetWriterInput?
        var started = false
        var sawVideo = false
        var lastVideoTime: CMTime?
        var handlerError: Error?

        func withLock<T>(_ body: (CaptureState) -> T) -> T {
            lock.lock()
            defer { self.lock.unlock() }
            return body(self)
        }
    }

    enum ScreenRecordError: LocalizedError {
        case invalidScreenIndex(Int)
        case captureFailed(String)
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case let .invalidScreenIndex(index):
                "Invalid screen index \(index)"
            case let .captureFailed(message):
                message
            case let .writeFailed(message):
                message
            }
        }
    }

    func record(
        screenIndex: Int?,
        durationMs: Int?,
        fps: Double?,
        includeAudio: Bool?,
        outPath: String?
    ) async throws -> String {
        let config = try makeRecordConfig(
            screenIndex: screenIndex,
            durationMs: durationMs,
            fps: fps,
            includeAudio: includeAudio,
            outPath: outPath
        )

        let state = CaptureState()
        let recordQueue = DispatchQueue(label: "ai.openava.screenrecord")

        try await startCapture(state: state, config: config, recordQueue: recordQueue)
        try await Task.sleep(nanoseconds: UInt64(config.durationMs) * 1_000_000)
        try await stopCapture()
        try finalizeCapture(state: state)
        try await finishWriting(state: state)

        return config.outURL.path
    }

    private struct RecordConfig {
        let durationMs: Int
        let fpsValue: Double
        let includeAudio: Bool
        let outURL: URL
    }

    private func makeRecordConfig(
        screenIndex: Int?,
        durationMs: Int?,
        fps: Double?,
        includeAudio: Bool?,
        outPath: String?
    ) throws -> RecordConfig {
        if let screenIndex, screenIndex != 0 {
            throw ScreenRecordError.invalidScreenIndex(screenIndex)
        }

        let clampedDurationMs = CaptureRateLimits.clampDurationMs(durationMs)
        let clampedFps = CaptureRateLimits.clampFps(fps, maxFps: 30)
        let fpsValue = Double(Int32(clampedFps.rounded()))
        let includeAudio = includeAudio ?? true

        let outURL = makeOutputURL(outPath: outPath)
        try? FileManager().removeItem(at: outURL)

        return RecordConfig(
            durationMs: clampedDurationMs,
            fpsValue: fpsValue,
            includeAudio: includeAudio,
            outURL: outURL
        )
    }

    private func makeOutputURL(outPath: String?) -> URL {
        if let outPath,
           !outPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return URL(fileURLWithPath: outPath)
        }

        return FileManager().temporaryDirectory
            .appendingPathComponent("openava-screen-record-\(UUID().uuidString).mp4")
    }

    private func startCapture(
        state: CaptureState,
        config: RecordConfig,
        recordQueue: DispatchQueue
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let handler = self.makeCaptureHandler(state: state, config: config, recordQueue: recordQueue)
            let completion: @Sendable (Error?) -> Void = { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }

            Task { @MainActor in
                startReplayKitCapture(
                    includeAudio: config.includeAudio,
                    handler: handler,
                    completion: completion
                )
            }
        }
    }

    private func makeCaptureHandler(
        state: CaptureState,
        config: RecordConfig,
        recordQueue: DispatchQueue
    ) -> @Sendable (CMSampleBuffer, RPSampleBufferType, Error?) -> Void {
        { sample, type, error in
            let sampleBox = UncheckedSendableBox(value: sample)
            recordQueue.async {
                let sample = sampleBox.value
                if let error {
                    state.withLock { state in
                        if state.handlerError == nil {
                            state.handlerError = error
                        }
                    }
                    return
                }

                guard CMSampleBufferDataIsReady(sample) else { return }

                switch type {
                case .video:
                    self.handleVideoSample(sample, state: state, config: config)
                case .audioApp, .audioMic:
                    self.handleAudioSample(sample, state: state, includeAudio: config.includeAudio)
                @unknown default:
                    break
                }
            }
        }
    }

    private func handleVideoSample(
        _ sample: CMSampleBuffer,
        state: CaptureState,
        config: RecordConfig
    ) {
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        let shouldSkip = state.withLock { state in
            if let lastVideoTime = state.lastVideoTime {
                let delta = CMTimeSubtract(pts, lastVideoTime)
                return delta.seconds < (1.0 / config.fpsValue)
            }
            return false
        }
        if shouldSkip { return }

        if state.withLock({ $0.writer == nil }) {
            prepareWriter(sample: sample, state: state, config: config, pts: pts)
        }

        let videoInput = state.withLock { $0.videoInput }
        let started = state.withLock { $0.started }
        guard let videoInput, started else { return }

        if videoInput.isReadyForMoreMediaData {
            if videoInput.append(sample) {
                state.withLock { state in
                    state.sawVideo = true
                    state.lastVideoTime = pts
                }
            } else if let error = state.withLock({ $0.writer?.error }) {
                state.withLock { state in
                    if state.handlerError == nil {
                        state.handlerError = ScreenRecordError.writeFailed(error.localizedDescription)
                    }
                }
            }
        }
    }

    private func prepareWriter(
        sample: CMSampleBuffer,
        state: CaptureState,
        config: RecordConfig,
        pts: CMTime
    ) {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sample) else {
            state.withLock { state in
                if state.handlerError == nil {
                    state.handlerError = ScreenRecordError.captureFailed("Missing image buffer")
                }
            }
            return
        }

        let width = CVPixelBufferGetWidth(imageBuffer)
        let height = CVPixelBufferGetHeight(imageBuffer)
        do {
            let writer = try AVAssetWriter(outputURL: config.outURL, fileType: .mp4)
            let settings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
            ]
            let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            videoInput.expectsMediaDataInRealTime = true
            guard writer.canAdd(videoInput) else {
                throw ScreenRecordError.writeFailed("Cannot add video input")
            }
            writer.add(videoInput)

            if config.includeAudio {
                let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: nil)
                audioInput.expectsMediaDataInRealTime = true
                if writer.canAdd(audioInput) {
                    writer.add(audioInput)
                    state.withLock { state in
                        state.audioInput = audioInput
                    }
                }
            }

            guard writer.startWriting() else {
                throw ScreenRecordError.writeFailed(
                    writer.error?.localizedDescription ?? "Failed to start writer"
                )
            }
            writer.startSession(atSourceTime: pts)
            state.withLock { state in
                state.writer = writer
                state.videoInput = videoInput
                state.started = true
            }
        } catch {
            state.withLock { state in
                if state.handlerError == nil {
                    state.handlerError = error
                }
            }
        }
    }

    private func handleAudioSample(
        _ sample: CMSampleBuffer,
        state: CaptureState,
        includeAudio: Bool
    ) {
        let audioInput = state.withLock { $0.audioInput }
        let started = state.withLock { $0.started }
        guard includeAudio, let audioInput, started else { return }

        if audioInput.isReadyForMoreMediaData {
            _ = audioInput.append(sample)
        }
    }

    private func stopCapture() async throws {
        let stopError = await withCheckedContinuation { continuation in
            Task { @MainActor in
                stopReplayKitCapture { error in
                    continuation.resume(returning: error)
                }
            }
        }
        if let stopError {
            throw stopError
        }
    }

    private func finalizeCapture(state: CaptureState) throws {
        if let handlerError = state.withLock({ $0.handlerError }) {
            throw handlerError
        }

        let writer = state.withLock { $0.writer }
        let videoInput = state.withLock { $0.videoInput }
        let audioInput = state.withLock { $0.audioInput }
        let sawVideo = state.withLock { $0.sawVideo }
        guard let writer, let videoInput, sawVideo else {
            throw ScreenRecordError.captureFailed("No frames captured")
        }

        videoInput.markAsFinished()
        audioInput?.markAsFinished()
        _ = writer
    }

    private func finishWriting(state: CaptureState) async throws {
        guard let writer = state.withLock({ $0.writer }) else {
            throw ScreenRecordError.captureFailed("Missing writer")
        }

        let writerBox = UncheckedSendableBox(value: writer)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writerBox.value.finishWriting {
                let writer = writerBox.value
                if let error = writer.error {
                    continuation.resume(throwing: ScreenRecordError.writeFailed(error.localizedDescription))
                } else if writer.status != .completed {
                    continuation.resume(throwing: ScreenRecordError.writeFailed("Failed to finalize video"))
                } else {
                    continuation.resume()
                }
            }
        }
    }
}

@MainActor
private func startReplayKitCapture(
    includeAudio: Bool,
    handler: @escaping @Sendable (CMSampleBuffer, RPSampleBufferType, Error?) -> Void,
    completion: @escaping @Sendable (Error?) -> Void
) {
    let recorder = RPScreenRecorder.shared()
    recorder.isMicrophoneEnabled = includeAudio
    recorder.startCapture(handler: handler, completionHandler: completion)
}

@MainActor
private func stopReplayKitCapture(_ completion: @escaping @Sendable (Error?) -> Void) {
    RPScreenRecorder.shared().stopCapture { error in completion(error) }
}

#if DEBUG
    extension ScreenRecordService {
        nonisolated static func _test_clampDurationMs(_ ms: Int?) -> Int {
            CaptureRateLimits.clampDurationMs(ms)
        }

        nonisolated static func _test_clampFps(_ fps: Double?) -> Double {
            CaptureRateLimits.clampFps(fps, maxFps: 30)
        }
    }
#endif
