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
        case name
        case emoji
        case description
        case agentPoolIDs
        case leadAgentID
        case defaultTopology
        case createdAt
        case updatedAt
    }

    var id: UUID
    var name: String
    var emoji: String
    var description: String?
    var agentPoolIDs: [UUID]
    var leadAgentID: UUID?
    var defaultTopology: TeamTopologyKind
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        emoji: String = "👥",
        description: String? = nil,
        agentPoolIDs: [UUID],
        leadAgentID: UUID? = nil,
        defaultTopology: TeamTopologyKind = .automatic,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedEmoji = emoji.trimmingCharacters(in: .whitespacesAndNewlines)
        self.emoji = trimmedEmoji.isEmpty ? "👥" : trimmedEmoji
        self.description = description?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.agentPoolIDs = agentPoolIDs
        self.leadAgentID = leadAgentID
        self.defaultTopology = defaultTopology
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        emoji = try container.decodeIfPresent(String.self, forKey: .emoji) ?? "👥"
        description = try container.decodeIfPresent(String.self, forKey: .description)
        agentPoolIDs = try container.decode([UUID].self, forKey: .agentPoolIDs)
        leadAgentID = try container.decodeIfPresent(UUID.self, forKey: .leadAgentID)
        defaultTopology = try container.decode(TeamTopologyKind.self, forKey: .defaultTopology)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }
}
