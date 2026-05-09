import Foundation

struct ChatContextMetadata: Codable, Equatable {
    static let fileName = "metadata.json"

    var selectedModelID: UUID?
    var thinkingStrength: ChatThinkingStrength
    var createdAtMs: Int64
    var autoCompactEnabled: Bool

    init(
        selectedModelID: UUID?,
        thinkingStrength: ChatThinkingStrength = .medium,
        createdAtMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
        autoCompactEnabled: Bool = true
    ) {
        self.selectedModelID = selectedModelID
        self.thinkingStrength = thinkingStrength
        self.createdAtMs = createdAtMs
        self.autoCompactEnabled = autoCompactEnabled
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        selectedModelID = try container.decodeIfPresent(UUID.self, forKey: .selectedModelID)
        thinkingStrength = try container.decodeIfPresent(ChatThinkingStrength.self, forKey: .thinkingStrength) ?? .medium
        createdAtMs = try container.decode(Int64.self, forKey: .createdAtMs)
        autoCompactEnabled = try container.decodeIfPresent(Bool.self, forKey: .autoCompactEnabled) ?? true
    }

    static func load(from directoryURL: URL) -> ChatContextMetadata? {
        let url = directoryURL.appendingPathComponent(fileName, isDirectory: false)
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try? JSONDecoder().decode(ChatContextMetadata.self, from: data)
    }

    static func persist(_ metadata: ChatContextMetadata, to directoryURL: URL, fileManager: FileManager) {
        let url = directoryURL.appendingPathComponent(fileName, isDirectory: false)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(metadata) else {
            return
        }
        try? fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try? data.write(to: url, options: [.atomic])
    }
}
