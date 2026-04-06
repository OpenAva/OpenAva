import Foundation

enum TeamTopologyKind: String, Codable, CaseIterable {
    case automatic
    case flat
    case tree
    case custom
}

struct TeamProfile: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var description: String?
    var agentPoolIDs: [UUID]
    var leadAgentID: UUID?
    var defaultTopology: TeamTopologyKind
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        description: String? = nil,
        agentPoolIDs: [UUID],
        leadAgentID: UUID? = nil,
        defaultTopology: TeamTopologyKind = .automatic,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.description = description?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.agentPoolIDs = agentPoolIDs
        self.leadAgentID = leadAgentID
        self.defaultTopology = defaultTopology
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
