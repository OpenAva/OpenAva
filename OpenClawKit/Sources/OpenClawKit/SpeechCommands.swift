import Foundation

public enum OpenClawSpeechCommand: String, Codable, Sendable {
    case transcribe = "speech.transcribe"
}

public enum OpenClawSpeechTaskHint: String, Codable, Sendable {
    case unspecified
    case dictation
    case search
    case confirmation
}

public struct OpenClawSpeechTranscribeParams: Codable, Sendable, Equatable {
    public var filePath: String
    public var locale: String?
    public var taskHint: OpenClawSpeechTaskHint?
    public var requiresOnDeviceRecognition: Bool?
    public var addsPunctuation: Bool?
    public var contextualStrings: [String]?

    public init(
        filePath: String,
        locale: String? = nil,
        taskHint: OpenClawSpeechTaskHint? = nil,
        requiresOnDeviceRecognition: Bool? = nil,
        addsPunctuation: Bool? = nil,
        contextualStrings: [String]? = nil
    ) {
        self.filePath = filePath
        self.locale = locale
        self.taskHint = taskHint
        self.requiresOnDeviceRecognition = requiresOnDeviceRecognition
        self.addsPunctuation = addsPunctuation
        self.contextualStrings = contextualStrings
    }
}

public struct OpenClawSpeechSegmentPayload: Codable, Sendable, Equatable {
    public var text: String
    public var startSeconds: Double
    public var durationSeconds: Double
    public var confidence: Double

    public init(text: String, startSeconds: Double, durationSeconds: Double, confidence: Double) {
        self.text = text
        self.startSeconds = startSeconds
        self.durationSeconds = durationSeconds
        self.confidence = confidence
    }
}

public struct OpenClawSpeechTranscribePayload: Codable, Sendable, Equatable {
    public var text: String
    public var locale: String
    public var filePath: String
    public var isFinal: Bool
    public var segments: [OpenClawSpeechSegmentPayload]

    public init(
        text: String,
        locale: String,
        filePath: String,
        isFinal: Bool,
        segments: [OpenClawSpeechSegmentPayload]
    ) {
        self.text = text
        self.locale = locale
        self.filePath = filePath
        self.isFinal = isFinal
        self.segments = segments
    }
}
