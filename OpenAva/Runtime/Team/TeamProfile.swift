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
        case defaultTopology
        case createdAt
        case updatedAt
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
    var createdAtMs: Int64
    var autoCompactEnabled: Bool

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
        createdAtMs: Int64? = nil,
        autoCompactEnabled: Bool = true
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
        self.createdAtMs = createdAtMs ?? Int64(createdAt.timeIntervalSince1970 * 1000)
        self.autoCompactEnabled = autoCompactEnabled
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        emoji = try container.decodeIfPresent(String.self, forKey: .emoji) ?? "👥"
        description = try container.decodeIfPresent(String.self, forKey: .description)
        agentPoolIDs = try container.decode([UUID].self, forKey: .agentPoolIDs)
        defaultTopology = try container.decode(TeamTopologyKind.self, forKey: .defaultTopology)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        selectedModelID = nil
        thinkingStrength = .medium
        createdAtMs = Int64(createdAt.timeIntervalSince1970 * 1000)
        autoCompactEnabled = true
    }
}
