import Foundation

struct ChatContextMetadata: Codable, Equatable {
    static let fileName = "metadata.json"

    var selectedModelID: String?
    var thinkingStrength: ChatThinkingStrength
    var members: [String]
    var createdAt: Date
    var updatedAt: Date
    var autoCompactEnabled: Bool
    var defaultTopology: TeamTopologyKind

    init(
        selectedModelID: String?,
        thinkingStrength: ChatThinkingStrength = .medium,
        members: [String] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        autoCompactEnabled: Bool = true,
        defaultTopology: TeamTopologyKind = .automatic
    ) {
        self.selectedModelID = selectedModelID
        self.thinkingStrength = thinkingStrength
        self.members = members
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.autoCompactEnabled = autoCompactEnabled
        self.defaultTopology = defaultTopology
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        selectedModelID = try container.decodeIfPresent(String.self, forKey: .selectedModelID)
        thinkingStrength = try container.decode(ChatThinkingStrength.self, forKey: .thinkingStrength)
        members = try container.decode([String].self, forKey: .members)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        autoCompactEnabled = try container.decode(Bool.self, forKey: .autoCompactEnabled)
        defaultTopology = try container.decode(TeamTopologyKind.self, forKey: .defaultTopology)
    }

    static func load(from directoryURL: URL) -> ChatContextMetadata? {
        let url = directoryURL.appendingPathComponent(fileName, isDirectory: false)
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ChatContextMetadata.self, from: data)
    }

    static func persist(_ metadata: ChatContextMetadata, to directoryURL: URL, fileManager: FileManager) {
        let url = directoryURL.appendingPathComponent(fileName, isDirectory: false)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(metadata) else {
            return
        }
        try? fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try? data.write(to: url, options: [.atomic])
    }
}
