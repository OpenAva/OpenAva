import Foundation

struct TeamExecutionPlan: Codable, Equatable, Identifiable {
    struct Node: Codable, Equatable, Identifiable {
        var id: UUID {
            agentID
        }

        let agentID: UUID
        let role: String?

        init(agentID: UUID, role: String? = nil) {
            self.agentID = agentID
            self.role = role?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    struct Edge: Codable, Equatable, Identifiable {
        let id: UUID
        let fromAgentID: UUID
        let toAgentID: UUID
        let relationship: String

        init(
            id: UUID = UUID(),
            fromAgentID: UUID,
            toAgentID: UUID,
            relationship: String
        ) {
            self.id = id
            self.fromAgentID = fromAgentID
            self.toAgentID = toAgentID
            self.relationship = relationship.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    let id: UUID
    let teamID: UUID
    let topology: TeamTopologyKind
    let nodes: [Node]
    let edges: [Edge]
    let createdAt: Date

    init(
        id: UUID = UUID(),
        teamID: UUID,
        topology: TeamTopologyKind,
        nodes: [Node],
        edges: [Edge],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.teamID = teamID
        self.topology = topology
        self.nodes = nodes
        self.edges = edges
        self.createdAt = createdAt
    }
}

enum TeamTopologyPlanner {
    static func defaultPlan(for profile: TeamProfile) -> TeamExecutionPlan {
        let nodes = profile.agentPoolIDs.map { TeamExecutionPlan.Node(agentID: $0) }
        let rootAgentID = profile.agentPoolIDs.first
        let edges: [TeamExecutionPlan.Edge]

        if profile.defaultTopology == .tree, let rootAgentID {
            edges = profile.agentPoolIDs
                .filter { $0 != rootAgentID }
                .map {
                    TeamExecutionPlan.Edge(
                        fromAgentID: rootAgentID,
                        toAgentID: $0,
                        relationship: "delegates"
                    )
                }
        } else {
            edges = []
        }

        return TeamExecutionPlan(
            teamID: profile.id,
            topology: profile.defaultTopology,
            nodes: nodes,
            edges: edges
        )
    }
}
