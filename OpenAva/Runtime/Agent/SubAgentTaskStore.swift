import ChatClient
import Foundation

actor SubAgentTaskStore {
    enum Status: String, Codable {
        case running
        case waiting
        case completed
        case failed
        case cancelled
    }

    struct ProgressSnapshot: Codable, Equatable {
        var summary: String?
        var recentActivities: [String]
        var totalTurns: Int
        var totalToolCalls: Int
        var durationMs: Int
    }

    struct TaskRecord: Codable, Equatable {
        let id: String
        let agentType: String
        let description: String
        let prompt: String
        let parentSessionID: String?
        let createdAt: Date
        var updatedAt: Date
        var status: Status
        var result: String?
        var errorDescription: String?
        var messageID: String?
        var conversation: [PersistedConversationMessage]
        var pendingPrompts: [String]
        var totalTurns: Int
        var totalToolCalls: Int
        var durationMs: Int
    }

    struct PersistedConversationMessage: Codable, Equatable {
        enum Role: String, Codable {
            case system
            case user
            case assistant
            case tool
        }

        struct ToolCall: Codable, Equatable {
            let id: String
            let name: String
            let arguments: String?
        }

        let role: Role
        let text: String?
        let toolCalls: [ToolCall]?
        let reasoning: String?
        let toolCallID: String?
    }

    struct TaskSnapshot: Equatable {
        let record: TaskRecord
        let progress: ProgressSnapshot?
    }

    static let shared = SubAgentTaskStore()

    private var records: [String: TaskRecord] = [:]
    private var progressSnapshots: [String: ProgressSnapshot] = [:]
    private var runningTasks: [String: Task<Void, Never>] = [:]

    @discardableResult
    func create(
        agentType: String,
        description: String,
        prompt: String,
        parentSessionID: String?
    ) -> TaskRecord {
        let now = Date()
        let record = TaskRecord(
            id: UUID().uuidString,
            agentType: agentType,
            description: description,
            prompt: prompt,
            parentSessionID: parentSessionID,
            createdAt: now,
            updatedAt: now,
            status: .running,
            result: nil,
            errorDescription: nil,
            messageID: nil,
            conversation: [],
            pendingPrompts: [],
            totalTurns: 0,
            totalToolCalls: 0,
            durationMs: 0
        )
        records[record.id] = record
        progressSnapshots[record.id] = ProgressSnapshot(
            summary: "Starting sub agent…",
            recentActivities: [],
            totalTurns: 0,
            totalToolCalls: 0,
            durationMs: 0
        )
        return record
    }

    func attach(task: Task<Void, Never>, for taskID: String) {
        runningTasks[taskID] = task
    }

    func detach(taskID: String) {
        runningTasks.removeValue(forKey: taskID)
    }

    func hasAttachedTask(taskID: String) -> Bool {
        runningTasks[taskID] != nil
    }

    func bindMessage(taskID: String, messageID: String) {
        guard var record = records[taskID] else { return }
        record.messageID = messageID
        record.updatedAt = Date()
        records[taskID] = record
    }

    func updateProgress(taskID: String, snapshot: ProgressSnapshot) {
        guard var record = records[taskID] else { return }
        record.updatedAt = Date()
        record.totalTurns = snapshot.totalTurns
        record.totalToolCalls = snapshot.totalToolCalls
        record.durationMs = snapshot.durationMs
        records[taskID] = record
        let mergedActivities = mergedRecentActivities(
            existing: progressSnapshots[taskID]?.recentActivities ?? [],
            incoming: snapshot.recentActivities
        )
        progressSnapshots[taskID] = ProgressSnapshot(
            summary: snapshot.summary,
            recentActivities: mergedActivities,
            totalTurns: snapshot.totalTurns,
            totalToolCalls: snapshot.totalToolCalls,
            durationMs: snapshot.durationMs
        )
    }

    func markCompleted(
        taskID: String,
        result: String,
        conversation: [PersistedConversationMessage]? = nil,
        summary: String? = nil,
        totalTurns: Int? = nil,
        totalToolCalls: Int? = nil,
        durationMs: Int? = nil
    ) {
        guard var record = records[taskID] else { return }
        record.status = .completed
        record.updatedAt = Date()
        record.result = result
        record.errorDescription = nil
        if let conversation {
            record.conversation = conversation
        }
        if let totalTurns { record.totalTurns = totalTurns }
        if let totalToolCalls { record.totalToolCalls = totalToolCalls }
        if let durationMs { record.durationMs = durationMs }
        records[taskID] = record
        if var progress = progressSnapshots[taskID] {
            progress.summary = summary ?? progress.summary ?? "Completed"
            if let totalTurns { progress.totalTurns = totalTurns }
            if let totalToolCalls { progress.totalToolCalls = totalToolCalls }
            if let durationMs { progress.durationMs = durationMs }
            progressSnapshots[taskID] = progress
        }
        runningTasks.removeValue(forKey: taskID)
    }

    func markWaiting(
        taskID: String,
        result: String,
        conversation: [PersistedConversationMessage],
        summary: String? = nil,
        totalTurns: Int? = nil,
        totalToolCalls: Int? = nil,
        durationMs: Int? = nil
    ) {
        guard var record = records[taskID] else { return }
        record.status = .waiting
        record.updatedAt = Date()
        record.result = result
        record.errorDescription = nil
        record.conversation = conversation
        if let totalTurns { record.totalTurns = totalTurns }
        if let totalToolCalls { record.totalToolCalls = totalToolCalls }
        if let durationMs { record.durationMs = durationMs }
        records[taskID] = record
        if var progress = progressSnapshots[taskID] {
            progress.summary = summary ?? progress.summary ?? "Waiting for follow-up"
            if let totalTurns { progress.totalTurns = totalTurns }
            if let totalToolCalls { progress.totalToolCalls = totalToolCalls }
            if let durationMs { progress.durationMs = durationMs }
            progressSnapshots[taskID] = progress
        }
    }

    func saveCheckpoint(
        taskID: String,
        result: String,
        conversation: [PersistedConversationMessage],
        summary: String? = nil,
        totalTurns: Int? = nil,
        totalToolCalls: Int? = nil,
        durationMs: Int? = nil
    ) {
        guard var record = records[taskID] else { return }
        record.status = .running
        record.updatedAt = Date()
        record.result = result
        record.errorDescription = nil
        record.conversation = conversation
        if let totalTurns { record.totalTurns = totalTurns }
        if let totalToolCalls { record.totalToolCalls = totalToolCalls }
        if let durationMs { record.durationMs = durationMs }
        records[taskID] = record
        if var progress = progressSnapshots[taskID] {
            progress.summary = summary ?? progress.summary ?? "Running"
            if let totalTurns { progress.totalTurns = totalTurns }
            if let totalToolCalls { progress.totalToolCalls = totalToolCalls }
            if let durationMs { progress.durationMs = durationMs }
            progressSnapshots[taskID] = progress
        }
    }

    func markFailed(
        taskID: String,
        errorDescription: String,
        summary: String? = nil,
        totalTurns: Int? = nil,
        totalToolCalls: Int? = nil,
        durationMs: Int? = nil
    ) {
        guard var record = records[taskID] else { return }
        record.status = .failed
        record.updatedAt = Date()
        record.errorDescription = errorDescription
        records[taskID] = record
        if var progress = progressSnapshots[taskID] {
            progress.summary = summary ?? "Failed"
            if let totalTurns { progress.totalTurns = totalTurns }
            if let totalToolCalls { progress.totalToolCalls = totalToolCalls }
            if let durationMs { progress.durationMs = durationMs }
            progressSnapshots[taskID] = progress
        }
        runningTasks.removeValue(forKey: taskID)
    }

    func markCancelled(taskID: String, summary: String? = nil) {
        guard var record = records[taskID] else { return }
        record.status = .cancelled
        record.updatedAt = Date()
        record.errorDescription = nil
        records[taskID] = record
        if var progress = progressSnapshots[taskID] {
            progress.summary = summary ?? "Cancelled"
            progressSnapshots[taskID] = progress
        }
        runningTasks.removeValue(forKey: taskID)
    }

    func record(taskID: String) -> TaskRecord? {
        records[taskID]
    }

    func snapshot(taskID: String) -> TaskSnapshot? {
        guard let record = records[taskID] else { return nil }
        return TaskSnapshot(record: record, progress: progressSnapshots[taskID])
    }

    func enqueuePrompt(taskID: String, prompt: String) -> TaskRecord? {
        guard var record = records[taskID] else { return nil }
        let normalized = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        guard record.status != .completed,
              record.status != .failed,
              record.status != .cancelled
        else {
            return nil
        }
        record.pendingPrompts.append(normalized)
        record.status = .running
        record.updatedAt = Date()
        records[taskID] = record
        if var progress = progressSnapshots[taskID] {
            progress.summary = "Queued follow-up"
            progressSnapshots[taskID] = progress
        }
        return record
    }

    func takeNextPrompt(taskID: String) -> String? {
        guard var record = records[taskID], !record.pendingPrompts.isEmpty else { return nil }
        let next = record.pendingPrompts.removeFirst()
        record.updatedAt = Date()
        record.status = .running
        records[taskID] = record
        return next
    }

    func restoreConversation(taskID: String) -> [ChatRequestBody.Message]? {
        guard let record = records[taskID] else { return nil }
        return materializedMessages(from: record.conversation)
    }

    func cancel(taskID: String) -> Bool {
        if let task = runningTasks.removeValue(forKey: taskID) {
            task.cancel()
            markCancelled(taskID: taskID)
            return true
        }
        guard let record = records[taskID], record.status == .waiting else {
            return false
        }
        markCancelled(taskID: taskID)
        return true
    }

    private func mergedRecentActivities(existing: [String], incoming: [String], limit: Int = 6) -> [String] {
        guard !incoming.isEmpty else { return existing }

        var merged = existing
        for activity in incoming {
            let trimmed = activity.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if merged.last != trimmed {
                merged.append(trimmed)
            }
        }

        if merged.count > limit {
            merged.removeFirst(merged.count - limit)
        }
        return merged
    }

    private func materializedMessages(from messages: [PersistedConversationMessage]) -> [ChatRequestBody.Message] {
        messages.map { message in
            switch message.role {
            case .system:
                return .system(content: .text(message.text ?? ""))
            case .user:
                return .user(content: .text(message.text ?? ""))
            case .assistant:
                let toolCalls = message.toolCalls?.map {
                    ChatRequestBody.Message.ToolCall(
                        id: $0.id,
                        function: .init(name: $0.name, arguments: $0.arguments)
                    )
                }
                return .assistant(
                    content: message.text.map { .text($0) },
                    toolCalls: toolCalls,
                    reasoning: message.reasoning,
                    thinkingBlocks: nil
                )
            case .tool:
                return .tool(content: .text(message.text ?? ""), toolCallID: message.toolCallID ?? "")
            }
        }
    }
}
