import Foundation

actor SubAgentTaskStore {
    enum Status: String, Codable, Sendable {
        case running
        case completed
        case failed
        case cancelled
    }

    struct TaskRecord: Codable, Sendable, Equatable {
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
    }

    static let shared = SubAgentTaskStore()

    private var records: [String: TaskRecord] = [:]
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
            errorDescription: nil
        )
        records[record.id] = record
        return record
    }

    func attach(task: Task<Void, Never>, for taskID: String) {
        runningTasks[taskID] = task
    }

    func markCompleted(taskID: String, result: String) {
        guard var record = records[taskID] else { return }
        record.status = .completed
        record.updatedAt = Date()
        record.result = result
        record.errorDescription = nil
        records[taskID] = record
        runningTasks.removeValue(forKey: taskID)
    }

    func markFailed(taskID: String, errorDescription: String) {
        guard var record = records[taskID] else { return }
        record.status = .failed
        record.updatedAt = Date()
        record.errorDescription = errorDescription
        records[taskID] = record
        runningTasks.removeValue(forKey: taskID)
    }

    func markCancelled(taskID: String) {
        guard var record = records[taskID] else { return }
        record.status = .cancelled
        record.updatedAt = Date()
        record.errorDescription = nil
        records[taskID] = record
        runningTasks.removeValue(forKey: taskID)
    }

    func record(taskID: String) -> TaskRecord? {
        records[taskID]
    }

    func cancel(taskID: String) -> Bool {
        guard let task = runningTasks.removeValue(forKey: taskID) else {
            return false
        }
        task.cancel()
        markCancelled(taskID: taskID)
        return true
    }
}
