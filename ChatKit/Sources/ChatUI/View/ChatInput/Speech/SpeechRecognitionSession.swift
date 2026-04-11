//
//  SpeechRecognitionSession.swift
//  ChatUI
//

import AVFAudio
import Speech

@MainActor
final class SpeechRecognitionSession {
    var onTranscriptUpdate: (String) -> Void = { _ in }

    private var sessionItems: [Any] = []

    func start() async throws {
        let speechAuthorization = await requestSpeechAuthorizationAsync()
        guard speechAuthorization == .authorized else {
            #if targetEnvironment(macCatalyst)
                let message = String.localized("Speech recognizer is not authorized. Please enable OpenAva in System Settings > Privacy & Security > Speech Recognition.")
            #else
                let message = String.localized("Speech recognizer is not authorized.")
            #endif
            throw NSError(domain: "SpeechRecognizer", code: 0, userInfo: [
                NSLocalizedDescriptionKey: message,
            ])
        }

        let micPermissionGranted = await requestRecordPermissionAsync()
        guard micPermissionGranted else {
            #if targetEnvironment(macCatalyst)
                let message = String.localized("Microphone is not authorized. Please enable OpenAva in System Settings > Privacy & Security > Microphone.")
            #else
                let message = String.localized("Microphone is not authorized.")
            #endif
            throw NSError(domain: "SpeechRecognizer", code: 0, userInfo: [
                NSLocalizedDescriptionKey: message,
            ])
        }

        let preferredAppLanguage = Bundle.main.preferredLocalizations.first ?? "en"
        let preferredLocaleIdentifier = (preferredAppLanguage != "en") ? preferredAppLanguage : Locale.preferredLanguages.first ?? "en"
        let localeID = preferredLocaleIdentifier.replacingOccurrences(of: "_", with: "-")
        let speechLocale = Locale(identifier: localeID)

        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

        let audioEngine = AVAudioEngine()
        let inputNode = audioEngine.inputNode
        let recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        recognitionRequest.shouldReportPartialResults = true
        recognitionRequest.requiresOnDeviceRecognition = false

        guard let speechRecognizer = SFSpeechRecognizer(locale: speechLocale) else {
            throw NSError(domain: "SpeechRecognizer", code: 0, userInfo: [
                NSLocalizedDescriptionKey: String.localized("Speech recognizer is not available."),
            ])
        }

        let recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest) { [weak self] result, _ in
            guard let self, let result else { return }
            Task { @MainActor in
                self.onTranscriptUpdate(result.bestTranscription.formattedString)
            }
        }

        installRecognitionTap(inputNode: inputNode, recognitionRequest: recognitionRequest)
        audioEngine.prepare()
        try audioEngine.start()

        sessionItems.append(audioEngine)
        sessionItems.append(inputNode)
        sessionItems.append(recognitionTask)
    }

    func stop() {
        for item in sessionItems {
            if let task = item as? SFSpeechRecognitionTask {
                task.cancel()
            }
            if let audioEngine = item as? AVAudioEngine {
                audioEngine.inputNode.removeTap(onBus: 0)
                audioEngine.stop()
            }
        }
        sessionItems.removeAll()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

private nonisolated func requestSpeechAuthorizationAsync() async -> SFSpeechRecognizerAuthorizationStatus {
    await withCheckedContinuation { continuation in
        SFSpeechRecognizer.requestAuthorization { status in
            continuation.resume(returning: status)
        }
    }
}

private nonisolated func requestRecordPermissionAsync() async -> Bool {
    await withCheckedContinuation { continuation in
        if #available(iOS 17, *) {
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        } else {
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }
}

private nonisolated func installRecognitionTap(
    inputNode: AVAudioInputNode,
    recognitionRequest: SFSpeechAudioBufferRecognitionRequest
) {
    let recordingFormat = inputNode.outputFormat(forBus: 0)
    inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
        recognitionRequest.append(buffer)
    }
}
