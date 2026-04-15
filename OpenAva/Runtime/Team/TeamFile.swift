import Foundation

struct TeamAllowedPath: Codable, Equatable {
    let path: String
    let toolName: String
    let addedBy: String
    let addedAt: Date
}

struct TeamFileMember: Codable, Equatable {
    let agentId: String
    let agentType: String
    let prompt: String?
    let planModeRequired: Bool
    let sessionId: String
    let mode: String?
    let lastStatus: String
    let pendingPlanRequestID: String?
}

struct TeamFile: Codable, Equatable {
    let name: String
    let description: String?
    let createdAt: Date
    let updatedAt: Date
    let coordinatorId: String
    let coordinatorSessionId: String?
    let hiddenPaneIds: [String]
    let teamAllowedPaths: [TeamAllowedPath]
    let nextTaskID: Int
    let tasks: [TeamSwarmCoordinator.TeamTask]
    let members: [TeamFileMember]
}
