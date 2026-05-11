import Foundation

struct ChatContextMetadata: Codable, Equatable {
    static let fileName = "metadata.json"

    var selectedModelID: UUID?
    var thinkingStrength: ChatThinkingStrength
    var agentPoolIDs: [UUID]
    var createdAt: Date
    var updatedAt: Date
    var autoCompactEnabled: Bool
    var defaultTopology: TeamTopologyKind
    var avatarKind: AgentAvatarKind?
    var avatarSeed: String?

    init(
        selectedModelID: UUID?,
        thinkingStrength: ChatThinkingStrength = .medium,
        agentPoolIDs: [UUID] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        autoCompactEnabled: Bool = true,
        defaultTopology: TeamTopologyKind = .automatic,
        avatarKind: AgentAvatarKind? = nil,
        avatarSeed: String? = nil
    ) {
        self.selectedModelID = selectedModelID
        self.thinkingStrength = thinkingStrength
        self.agentPoolIDs = agentPoolIDs
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.autoCompactEnabled = autoCompactEnabled
        self.defaultTopology = defaultTopology
        self.avatarKind = avatarKind
        self.avatarSeed = avatarSeed
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        selectedModelID = try container.decodeIfPresent(UUID.self, forKey: .selectedModelID)
        thinkingStrength = try container.decode(ChatThinkingStrength.self, forKey: .thinkingStrength)
        agentPoolIDs = try container.decode([UUID].self, forKey: .agentPoolIDs)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        autoCompactEnabled = try container.decode(Bool.self, forKey: .autoCompactEnabled)
        defaultTopology = try container.decode(TeamTopologyKind.self, forKey: .defaultTopology)
        avatarKind = try container.decodeIfPresent(AgentAvatarKind.self, forKey: .avatarKind)
        avatarSeed = try container.decodeIfPresent(String.self, forKey: .avatarSeed)
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
