import AVFoundation
import Foundation

@MainActor
public final class TalkSystemSpeechSynthesizer: NSObject {
    public enum SpeakError: Error {
        case canceled
    }

    public static let shared = TalkSystemSpeechSynthesizer()

    private let synth = AVSpeechSynthesizer()
    private var speakContinuation: CheckedContinuation<Void, Error>?
    private var currentUtterance: AVSpeechUtterance?
    private var didStartCallback: (() -> Void)?
    private var currentToken = UUID()
    private var watchdog: Task<Void, Never>?

    public var isSpeaking: Bool {
        synth.isSpeaking
    }

    override private init() {
        super.init()
        synth.delegate = self
    }

    public func stop() {
        currentToken = UUID()
        watchdog?.cancel()
        watchdog = nil
        didStartCallback = nil
        synth.stopSpeaking(at: .immediate)
        finishCurrent(with: SpeakError.canceled)
    }

    public func speak(
        text: String,
        language: String? = nil,
        onStart: (() -> Void)? = nil
    ) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        stop()
        let token = UUID()
        currentToken = token
        didStartCallback = onStart

        let utterance = AVSpeechUtterance(string: trimmed)
        let selectedVoice = preferredVoice(for: language)
        if let selectedVoice {
            utterance.voice = selectedVoice
        }
        utterance.rate = preferredRate(for: selectedVoice?.language ?? language)
        utterance.pitchMultiplier = 1.08
        utterance.volume = 1.0
        currentUtterance = utterance

        // Use a conservative timeout to avoid cutting off normal speech mid-sentence.
        // CJK-heavy text is usually spoken much slower than 0.08s/char.
        let estimatedSeconds = max(8.0, min(300.0, 2.5 + Double(trimmed.count) * 0.24))
        watchdog?.cancel()
        watchdog = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(estimatedSeconds * 1_000_000_000))
            if Task.isCancelled { return }
            guard self.currentToken == token else { return }
            if self.synth.isSpeaking {
                self.synth.stopSpeaking(at: .immediate)
            }
            self.finishCurrent(
                with: NSError(domain: "TalkSystemSpeechSynthesizer", code: 408, userInfo: [
                    NSLocalizedDescriptionKey: "system TTS timed out after \(estimatedSeconds)s",
                ])
            )
        }

        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { cont in
                self.speakContinuation = cont
                self.synth.speak(utterance)
            }
        }, onCancel: {
            Task { @MainActor in
                self.stop()
            }
        })

        if currentToken != token {
            throw SpeakError.canceled
        }
    }

    private func matchesCurrentUtterance(_ utteranceID: ObjectIdentifier) -> Bool {
        guard let currentUtterance else { return false }
        return ObjectIdentifier(currentUtterance) == utteranceID
    }

    private func handleFinish(utteranceID: ObjectIdentifier, error: Error?) {
        guard matchesCurrentUtterance(utteranceID) else { return }
        watchdog?.cancel()
        watchdog = nil
        finishCurrent(with: error)
    }

    private func preferredVoice(for language: String?) -> AVSpeechSynthesisVoice? {
        let targetLanguage = language ?? Locale.preferredLanguages.first
        guard let targetLanguage else { return nil }

        let voices = AVSpeechSynthesisVoice.speechVoices().filter {
            normalizedLanguage($0.language) == normalizedLanguage(targetLanguage)
                || baseLanguage($0.language) == baseLanguage(targetLanguage)
        }
        if let enhanced = voices.first(where: { $0.quality == .enhanced }) {
            return enhanced
        }

        if let exact = voices.first(where: {
            normalizedLanguage($0.language) == normalizedLanguage(targetLanguage)
        }) {
            return exact
        }

        return voices.first ?? AVSpeechSynthesisVoice(language: targetLanguage)
    }

    private func preferredRate(for language: String?) -> Float {
        let base = baseLanguage(language)
        let multiplier: Float = ["zh", "ja", "ko"].contains(base) ? 1.12 : 1.08
        let tuned = AVSpeechUtteranceDefaultSpeechRate * multiplier
        return min(AVSpeechUtteranceMaximumSpeechRate, max(AVSpeechUtteranceMinimumSpeechRate, tuned))
    }

    private func normalizedLanguage(_ value: String?) -> String {
        (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func baseLanguage(_ value: String?) -> String {
        normalizedLanguage(value).split(separator: "-").first.map(String.init) ?? ""
    }

    private func finishCurrent(with error: Error?) {
        currentUtterance = nil
        didStartCallback = nil
        let cont = speakContinuation
        speakContinuation = nil
        if let error {
            cont?.resume(throwing: error)
        } else {
            cont?.resume(returning: ())
        }
    }
}

extension TalkSystemSpeechSynthesizer: AVSpeechSynthesizerDelegate {
    public nonisolated func speechSynthesizer(
        _: AVSpeechSynthesizer,
        didStart utterance: AVSpeechUtterance
    ) {
        let utteranceID = ObjectIdentifier(utterance)
        Task { @MainActor in
            guard self.matchesCurrentUtterance(utteranceID) else { return }
            let callback = self.didStartCallback
            self.didStartCallback = nil
            callback?()
        }
    }

    public nonisolated func speechSynthesizer(
        _: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        let utteranceID = ObjectIdentifier(utterance)
        Task { @MainActor in
            self.handleFinish(utteranceID: utteranceID, error: nil)
        }
    }

    public nonisolated func speechSynthesizer(
        _: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        let utteranceID = ObjectIdentifier(utterance)
        Task { @MainActor in
            self.handleFinish(utteranceID: utteranceID, error: SpeakError.canceled)
        }
    }
}
