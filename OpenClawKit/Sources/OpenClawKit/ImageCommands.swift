import Foundation

public enum OpenClawImageCommand: String, Codable, Sendable {
    case removeBackground = "image.remove_background"
}

public struct OpenClawImageRemoveBackgroundParams: Codable, Sendable, Equatable {
    public var inputPath: String
    public var outputPath: String?

    public init(inputPath: String, outputPath: String? = nil) {
        self.inputPath = inputPath
        self.outputPath = outputPath
    }
}

public struct OpenClawImageRemoveBackgroundPayload: Codable, Sendable, Equatable {
    public var inputPath: String
    public var outputPath: String
    public var format: String
    public var width: Int
    public var height: Int
    public var bytes: Int

    public init(
        inputPath: String,
        outputPath: String,
        format: String,
        width: Int,
        height: Int,
        bytes: Int
    ) {
        self.inputPath = inputPath
        self.outputPath = outputPath
        self.format = format
        self.width = width
        self.height = height
        self.bytes = bytes
    }
}
