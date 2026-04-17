import Foundation

public struct SubAgentTaskMetadata: Codable, Sendable, Equatable {
    public let taskID: String
    public let agentType: String
    public let taskDescription: String
    public let status: String
    public let summary: String?
    public let totalTurns: Int?
    public let totalToolCalls: Int?
    public let durationMs: Int?
    public let resultPreview: String?
    public let errorDescription: String?
    public let recentActivities: [String]?
    public let updatedAt: String?

    public init(
        taskID: String,
        agentType: String,
        taskDescription: String,
        status: String,
        summary: String? = nil,
        totalTurns: Int? = nil,
        totalToolCalls: Int? = nil,
        durationMs: Int? = nil,
        resultPreview: String? = nil,
        errorDescription: String? = nil,
        recentActivities: [String]? = nil,
        updatedAt: String? = nil
    ) {
        self.taskID = taskID
        self.agentType = agentType
        self.taskDescription = taskDescription
        self.status = status
        self.summary = summary
        self.totalTurns = totalTurns
        self.totalToolCalls = totalToolCalls
        self.durationMs = durationMs
        self.resultPreview = resultPreview
        self.errorDescription = errorDescription
        self.recentActivities = recentActivities
        self.updatedAt = updatedAt
    }
}

public extension ConversationMessage {
    var subAgentTaskMetadata: SubAgentTaskMetadata? {
        get {
            guard let raw = metadata["subAgentTaskMetadata"],
                  let data = raw.data(using: .utf8)
            else {
                return nil
            }
            return try? JSONDecoder().decode(SubAgentTaskMetadata.self, from: data)
        }
        set {
            guard let newValue else {
                metadata.removeValue(forKey: "subAgentTaskMetadata")
                return
            }
            guard let data = try? JSONEncoder().encode(newValue),
                  let raw = String(data: data, encoding: .utf8)
            else {
                metadata.removeValue(forKey: "subAgentTaskMetadata")
                return
            }
            metadata["subAgentTaskMetadata"] = raw
        }
    }

    var isSubAgentTask: Bool {
        subtype == "subagent_task"
    }
}
