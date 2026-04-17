import Foundation

actor SubAgentTaskStore {
    enum Status: String, Codable {
        case running
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
            messageID: nil
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

    func bindMessage(taskID: String, messageID: String) {
        guard var record = records[taskID] else { return }
        record.messageID = messageID
        record.updatedAt = Date()
        records[taskID] = record
    }

    func updateProgress(taskID: String, snapshot: ProgressSnapshot) {
        guard var record = records[taskID] else { return }
        record.updatedAt = Date()
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

    func cancel(taskID: String) -> Bool {
        guard let task = runningTasks.removeValue(forKey: taskID) else {
            return false
        }
        task.cancel()
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
}
