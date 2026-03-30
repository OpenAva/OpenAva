import Foundation
import OpenClawKit
import Speech

@MainActor
final class SpeechService {
    private let fileManager = FileManager.default
    private let baseDirectoryURL: URL?

    init(baseDirectoryURL: URL? = nil) {
        self.baseDirectoryURL = baseDirectoryURL?.standardizedFileURL
    }

    func transcribe(params: OpenClawSpeechTranscribeParams) async throws -> OpenClawSpeechTranscribePayload {
        let trimmedPath = params.filePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else {
            throw NSError(domain: "Speech", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "INVALID_REQUEST: filePath is required",
            ])
        }

        let authorizationStatus = await Self.requestSpeechAuthorizationIfNeeded()
        guard authorizationStatus == .authorized else {
            throw NSError(domain: "Speech", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "SPEECH_PERMISSION_REQUIRED: grant Speech Recognition permission",
            ])
        }

        let audioURL = try resolveFileURL(path: trimmedPath)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: audioURL.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw NSError(domain: "Speech", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "AUDIO_NOT_FOUND: \(trimmedPath)",
            ])
        }

        let localeIdentifier = params.locale?.trimmingCharacters(in: .whitespacesAndNewlines)
        let recognizerLocale = localeIdentifier.flatMap(Locale.init(identifier:)) ?? Locale.current
        guard let recognizer = SFSpeechRecognizer(locale: recognizerLocale), recognizer.isAvailable else {
            throw NSError(domain: "Speech", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "SPEECH_UNAVAILABLE: recognizer unavailable for locale \(recognizerLocale.identifier)",
            ])
        }

        if params.requiresOnDeviceRecognition == true, !recognizer.supportsOnDeviceRecognition {
            throw NSError(domain: "Speech", code: 5, userInfo: [
                NSLocalizedDescriptionKey: "SPEECH_UNAVAILABLE: on-device recognition not supported for locale \(recognizerLocale.identifier)",
            ])
        }

        let request = SFSpeechURLRecognitionRequest(url: audioURL)
        request.shouldReportPartialResults = false
        request.requiresOnDeviceRecognition = params.requiresOnDeviceRecognition ?? false
        request.addsPunctuation = params.addsPunctuation ?? true
        let contextualStrings = (params.contextualStrings ?? []).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        if !contextualStrings.isEmpty {
            request.contextualStrings = contextualStrings
        }
        request.taskHint = Self.resolveTaskHint(params.taskHint)

        let result = try await recognize(using: recognizer, request: request)
        let transcription = result.bestTranscription
        let segments = transcription.segments.map { segment in
            OpenClawSpeechSegmentPayload(
                text: segment.substring,
                startSeconds: segment.timestamp,
                durationSeconds: segment.duration,
                confidence: Double(segment.confidence)
            )
        }

        return OpenClawSpeechTranscribePayload(
            text: transcription.formattedString,
            locale: recognizer.locale.identifier,
            filePath: trimmedPath,
            isFinal: result.isFinal,
            segments: segments
        )
    }

    private func recognize(
        using recognizer: SFSpeechRecognizer,
        request: SFSpeechURLRecognitionRequest
    ) async throws -> SFSpeechRecognitionResult {
        final class RecognitionBox {
            var task: SFSpeechRecognitionTask?
        }

        let box = RecognitionBox()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<SFSpeechRecognitionResult, Error>) in
                let lock = NSLock()
                var didResume = false
                var latestResult: SFSpeechRecognitionResult?

                func resume(with result: Result<SFSpeechRecognitionResult, Error>) {
                    lock.lock()
                    defer { lock.unlock() }
                    guard !didResume else { return }
                    didResume = true
                    continuation.resume(with: result)
                }

                box.task = recognizer.recognitionTask(with: request) { result, error in
                    if let result {
                        latestResult = result
                        if result.isFinal {
                            resume(with: .success(result))
                            return
                        }
                    }

                    if let error {
                        resume(with: .failure(error))
                        return
                    }

                    // URL recognition should eventually yield a final result or an error.
                    // If the task completes without either, return the latest partial result.
                    if box.task?.state == .completed, let latestResult {
                        resume(with: .success(latestResult))
                        return
                    }

                    if box.task?.state == .completed {
                        resume(with: .failure(NSError(domain: "Speech", code: 9, userInfo: [
                            NSLocalizedDescriptionKey: "SPEECH_FAILED: recognition finished without a transcript",
                        ])))
                    }
                }
            }
        }, onCancel: {
            box.task?.cancel()
        })
    }

    private func resolveFileURL(path: String) throws -> URL {
        let workspaceURL = try workspaceDirectoryURL()

        let fileURL: URL
        if path.hasPrefix("/") {
            fileURL = URL(fileURLWithPath: path)
            guard fileURL.standardizedFileURL.path.hasPrefix(workspaceURL.path) else {
                throw NSError(domain: "Speech", code: 6, userInfo: [
                    NSLocalizedDescriptionKey: "ACCESS_DENIED: \(path)",
                ])
            }
        } else {
            fileURL = workspaceURL.appendingPathComponent(path)
        }

        let normalizedURL = fileURL.standardizedFileURL
        guard normalizedURL.path.hasPrefix(workspaceURL.path) else {
            throw NSError(domain: "Speech", code: 7, userInfo: [
                NSLocalizedDescriptionKey: "ACCESS_DENIED: \(path)",
            ])
        }
        return normalizedURL
    }

    private func workspaceDirectoryURL() throws -> URL {
        if let baseDirectoryURL {
            return baseDirectoryURL
        }

        guard let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw NSError(domain: "Speech", code: 8, userInfo: [
                NSLocalizedDescriptionKey: "INVALID_REQUEST: workspace unavailable",
            ])
        }
        return documentsURL
    }

    private static func requestSpeechAuthorizationIfNeeded() async -> SFSpeechRecognizerAuthorizationStatus {
        let status = SFSpeechRecognizer.authorizationStatus()
        guard status == .notDetermined else {
            return status
        }

        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { authorizationStatus in
                continuation.resume(returning: authorizationStatus)
            }
        }
    }

    private static func resolveTaskHint(_ value: OpenClawSpeechTaskHint?) -> SFSpeechRecognitionTaskHint {
        switch value ?? .unspecified {
        case .unspecified:
            return .unspecified
        case .dictation:
            return .dictation
        case .search:
            return .search
        case .confirmation:
            return .confirmation
        }
    }
}
