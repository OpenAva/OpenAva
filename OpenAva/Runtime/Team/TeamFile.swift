import Foundation

enum TeamBackendType: String, Codable {
    case inProcess = "in-process"
}

struct TeamAllowedPath: Codable, Equatable {
    let path: String
    let toolName: String
    let addedBy: String
    let addedAt: Date
}

struct TeamFileMember: Codable, Equatable {
    let agentId: String
    let name: String
    let agentType: String?
    let model: String?
    let prompt: String?
    let color: String?
    let planModeRequired: Bool?
    let joinedAt: Date
    let sessionId: String?
    let subscriptions: [String]
    let backendType: TeamBackendType?
    let isActive: Bool?
    let mode: String?
    let queuedMessageCount: Int?
    let lastStatus: String?
    let pendingPlanRequestID: String?

    enum CodingKeys: String, CodingKey {
        case agentId
        case name
        case agentType
        case model
        case prompt
        case color
        case planModeRequired
        case joinedAt
        case sessionId
        case subscriptions
        case backendType
        case isActive
        case mode
        case queuedMessageCount
        case lastStatus
        case pendingPlanRequestID = "pendingPlanRequestId"
    }
}

struct TeamFile: Codable, Equatable {
    let name: String
    let description: String?
    let createdAt: Date
    let updatedAt: Date
    let leadAgentId: String
    let leadSessionId: String?
    let hiddenPaneIds: [String]
    let teamAllowedPaths: [TeamAllowedPath]
    let nextTaskID: Int
    let tasks: [TeamSwarmCoordinator.TeamTask]
    let members: [TeamFileMember]

    enum CodingKeys: String, CodingKey {
        case name
        case description
        case createdAt
        case updatedAt
        case leadAgentId
        case leadSessionId
        case hiddenPaneIds
        case teamAllowedPaths
        case nextTaskID
        case tasks
        case members
    }
}
