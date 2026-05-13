import Foundation

struct TeamExecutionPlan: Codable, Equatable, Identifiable {
    struct Node: Codable, Equatable, Identifiable {
        var id: String {
            agentID
        }

        let agentID: String
        let role: String?

        init(agentID: String, role: String? = nil) {
            self.agentID = agentID
            self.role = role?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    struct Edge: Codable, Equatable, Identifiable {
        let id: String
        let fromAgentID: String
        let toAgentID: String
        let relationship: String

        init(
            id: String = UUID().uuidString,
            fromAgentID: String,
            toAgentID: String,
            relationship: String
        ) {
            self.id = id
            self.fromAgentID = fromAgentID
            self.toAgentID = toAgentID
            self.relationship = relationship.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    let id: String
    let teamID: String
    let topology: TeamTopologyKind
    let nodes: [Node]
    let edges: [Edge]
    let createdAt: Date

    init(
        id: String = UUID().uuidString,
        teamID: String,
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
        let nodes = profile.members.map { TeamExecutionPlan.Node(agentID: $0) }
        let rootAgentID = profile.members.first
        let edges: [TeamExecutionPlan.Edge]

        if profile.defaultTopology == .tree, let rootAgentID {
            edges = profile.members
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
