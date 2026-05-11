import Foundation

enum TeamTopologyKind: String, Codable, CaseIterable {
    case automatic
    case flat
    case tree
    case custom
}

struct TeamProfile: Codable, Equatable, Identifiable {
    private enum CodingKeys: String, CodingKey {
        case id
    }

    var id: UUID
    var name: String
    var emoji: String
    var description: String?
    var agentPoolIDs: [UUID]
    var defaultTopology: TeamTopologyKind
    var createdAt: Date
    var updatedAt: Date
    var selectedModelID: UUID?
    var thinkingStrength: ChatThinkingStrength
    var autoCompactEnabled: Bool
    var identityDocument: String?

    init(
        id: UUID = UUID(),
        name: String,
        emoji: String = "👥",
        description: String? = nil,
        agentPoolIDs: [UUID],
        defaultTopology: TeamTopologyKind = .automatic,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        selectedModelID: UUID? = nil,
        thinkingStrength: ChatThinkingStrength = .medium,
        autoCompactEnabled: Bool = true,
        identityDocument: String? = nil
    ) {
        self.id = id
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedEmoji = emoji.trimmingCharacters(in: .whitespacesAndNewlines)
        self.emoji = trimmedEmoji.isEmpty ? "👥" : trimmedEmoji
        self.description = description?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.agentPoolIDs = agentPoolIDs
        self.defaultTopology = defaultTopology
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.selectedModelID = selectedModelID
        self.thinkingStrength = thinkingStrength
        self.autoCompactEnabled = autoCompactEnabled
        self.identityDocument = identityDocument
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = ""
        emoji = "👥"
        description = nil
        agentPoolIDs = []
        defaultTopology = .automatic
        createdAt = Date()
        updatedAt = createdAt
        selectedModelID = nil
        thinkingStrength = .medium
        autoCompactEnabled = true
        identityDocument = nil
    }
}
