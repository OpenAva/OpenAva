import BackgroundTasks
import Foundation

final class BackgroundExecutionCoordinator {
    static let shared = BackgroundExecutionCoordinator()
    static let refreshTaskIdentifier = "com.day1-labs.openava.chat.resume"

    private struct ExecutionSnapshot: Codable {
        var conversationID: String
        var state: String
        var startedAt: Date
        var updatedAt: Date
        var errorDescription: String?
        var interruptionReason: String?
        var resumeAttempts: Int
    }

    private let queue = DispatchQueue(label: "com.day1-labs.openava.background.execution")
    private var snapshots: [String: ExecutionSnapshot] = [:]
    private var loaded = false

    private var storeURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let appDir = base.appendingPathComponent("OpenAva", isDirectory: true)
        return appDir.appendingPathComponent("background-executions.json", isDirectory: false)
    }

    private init() {}

    private var supportsBackgroundRefresh: Bool {
        #if targetEnvironment(macCatalyst)
            false
        #else
            true
        #endif
    }

    func markExecutionStarted(conversationID: String) {
        queue.async {
            self.loadIfNeededLocked()
            self.snapshots[conversationID] = ExecutionSnapshot(
                conversationID: conversationID,
                state: "running",
                startedAt: Date(),
                updatedAt: Date(),
                errorDescription: nil,
                interruptionReason: nil,
                resumeAttempts: self.snapshots[conversationID]?.resumeAttempts ?? 0
            )
            self.persistLocked()
        }
    }

    func markExecutionFinished(conversationID: String, success: Bool, errorDescription: String?) {
        queue.async {
            self.loadIfNeededLocked()
            if success {
                self.snapshots.removeValue(forKey: conversationID)
            } else {
                var snapshot = self.snapshots[conversationID] ?? ExecutionSnapshot(
                    conversationID: conversationID,
                    state: "failed",
                    startedAt: Date(),
                    updatedAt: Date(),
                    errorDescription: nil,
                    interruptionReason: nil,
                    resumeAttempts: 0
                )
                snapshot.state = "failed"
                snapshot.updatedAt = Date()
                snapshot.errorDescription = errorDescription
                self.snapshots[conversationID] = snapshot
            }
            self.persistLocked()
        }
    }

    func markExecutionInterrupted(conversationID: String, reason: String) {
        queue.async {
            self.loadIfNeededLocked()
            var snapshot = self.snapshots[conversationID] ?? ExecutionSnapshot(
                conversationID: conversationID,
                state: "interrupted",
                startedAt: Date(),
                updatedAt: Date(),
                errorDescription: nil,
                interruptionReason: nil,
                resumeAttempts: 0
            )
            snapshot.state = "interrupted"
            snapshot.interruptionReason = reason
            snapshot.updatedAt = Date()
            self.snapshots[conversationID] = snapshot
            self.persistLocked()
        }
        scheduleRefreshTaskIfNeeded()
    }

    func markResumeAttempted(conversationIDs: [String]) {
        queue.async {
            self.loadIfNeededLocked()
            for conversationID in conversationIDs {
                guard var snapshot = self.snapshots[conversationID] else { continue }
                snapshot.resumeAttempts += 1
                snapshot.updatedAt = Date()
                self.snapshots[conversationID] = snapshot
            }
            self.persistLocked()
        }
    }

    func pendingConversationIDs(limit: Int = 3) -> [String] {
        queue.sync {
            loadIfNeededLocked()
            return snapshots.values
                .filter { $0.state == "interrupted" || $0.state == "failed" }
                .sorted { $0.updatedAt > $1.updatedAt }
                .prefix(limit)
                .map(\.conversationID)
        }
    }

    func registerBackgroundTask() {
        guard supportsBackgroundRefresh else { return }
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.refreshTaskIdentifier,
            using: nil
        ) { task in
            guard let task = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            self.handleAppRefreshTask(task)
        }
    }

    func scheduleRefreshTaskIfNeeded() {
        guard supportsBackgroundRefresh else { return }
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshTaskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // Ignore schedule failures; foreground activation still triggers resume.
        }
    }

    func notifyIfResumableWorkExists() {
        let ids = pendingConversationIDs(limit: 5)
        guard !ids.isEmpty else { return }
        markResumeAttempted(conversationIDs: ids)
        NotificationCenter.default.post(
            name: .OpenAvaBackgroundResumeRequested,
            object: nil,
            userInfo: ["conversationIDs": ids]
        )
    }

    private func handleAppRefreshTask(_ task: BGAppRefreshTask) {
        let worker = Task {
            notifyIfResumableWorkExists()
            scheduleRefreshTaskIfNeeded()
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = {
            worker.cancel()
            task.setTaskCompleted(success: false)
        }
    }

    private func loadIfNeededLocked() {
        guard !loaded else { return }
        defer { loaded = true }

        guard let data = try? Data(contentsOf: storeURL) else {
            snapshots = [:]
            return
        }

        do {
            snapshots = try JSONDecoder().decode([String: ExecutionSnapshot].self, from: data)
        } catch {
            snapshots = [:]
        }
    }

    private func persistLocked() {
        do {
            let dir = storeURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(snapshots)
            try data.write(to: storeURL, options: .atomic)
        } catch {
            // Persistence failures should not break conversation execution.
        }
    }
}

extension Notification.Name {
    static let OpenAvaBackgroundResumeRequested = Notification.Name("OpenAvaBackgroundResumeRequested")
}
