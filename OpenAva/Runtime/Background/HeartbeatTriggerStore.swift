import Foundation

actor HeartbeatTriggerStore {
    struct Trigger: Codable, Equatable {
        let deliveryID: String
        let jobID: String
        let agentID: String
        let deliveredAt: TimeInterval
        let enqueuedAt: TimeInterval
    }

    private struct PersistedState: Codable {
        var pending: [Trigger]
        var recentHandledDeliveryIDs: [String]
    }

    static let shared = HeartbeatTriggerStore()

    private let fileManager: FileManager
    private var state = PersistedState(pending: [], recentHandledDeliveryIDs: [])
    private var hasLoadedState = false

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    @discardableResult
    func enqueue(jobID: String, agentID: String, deliveredAt: Date) -> Bool {
        loadIfNeeded()

        let normalizedJobID = jobID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedAgentID = agentID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedJobID.isEmpty, !normalizedAgentID.isEmpty else {
            return false
        }

        let deliveryID = makeDeliveryID(jobID: normalizedJobID, agentID: normalizedAgentID, deliveredAt: deliveredAt)
        if state.pending.contains(where: { $0.deliveryID == deliveryID }) ||
            state.recentHandledDeliveryIDs.contains(deliveryID)
        {
            return false
        }

        state.pending.removeAll { $0.jobID == normalizedJobID && $0.agentID == normalizedAgentID }
        state.pending.append(
            Trigger(
                deliveryID: deliveryID,
                jobID: normalizedJobID,
                agentID: normalizedAgentID,
                deliveredAt: deliveredAt.timeIntervalSince1970,
                enqueuedAt: Date().timeIntervalSince1970
            )
        )
        state.pending.sort { lhs, rhs in
            if lhs.enqueuedAt == rhs.enqueuedAt {
                return lhs.deliveryID < rhs.deliveryID
            }
            return lhs.enqueuedAt < rhs.enqueuedAt
        }
        persist()
        return true
    }

    func pendingTriggers(for agentID: String?) -> [Trigger] {
        loadIfNeeded()
        guard let normalizedAgentID = AppConfig.nonEmpty(agentID) else {
            return []
        }
        return state.pending.filter { $0.agentID == normalizedAgentID }
    }

    func markHandled(deliveryID: String) {
        loadIfNeeded()

        let normalizedDeliveryID = deliveryID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedDeliveryID.isEmpty else {
            return
        }

        state.pending.removeAll { $0.deliveryID == normalizedDeliveryID }
        state.recentHandledDeliveryIDs.removeAll { $0 == normalizedDeliveryID }
        state.recentHandledDeliveryIDs.append(normalizedDeliveryID)
        if state.recentHandledDeliveryIDs.count > 50 {
            state.recentHandledDeliveryIDs = Array(state.recentHandledDeliveryIDs.suffix(50))
        }
        persist()
    }

    private func loadIfNeeded() {
        guard !hasLoadedState else { return }
        defer { hasLoadedState = true }

        guard let data = try? Data(contentsOf: storeURL) else {
            state = PersistedState(pending: [], recentHandledDeliveryIDs: [])
            return
        }

        do {
            state = try JSONDecoder().decode(PersistedState.self, from: data)
        } catch {
            state = PersistedState(pending: [], recentHandledDeliveryIDs: [])
        }
    }

    private func persist() {
        do {
            try fileManager.createDirectory(at: storeDirectoryURL, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(state)
            try data.write(to: storeURL, options: .atomic)
        } catch {
            // Persistence failures should not prevent heartbeat execution.
        }
    }

    private func makeDeliveryID(jobID: String, agentID: String, deliveredAt: Date) -> String {
        let deliveredAtMs = Int((deliveredAt.timeIntervalSince1970 * 1000).rounded())
        return "\(jobID)::\(agentID)::\(deliveredAtMs)"
    }

    private var storeDirectoryURL: URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return base
            .appendingPathComponent("OpenAva", isDirectory: true)
            .appendingPathComponent("heartbeat", isDirectory: true)
    }

    private var storeURL: URL {
        storeDirectoryURL.appendingPathComponent("cron-triggers.json", isDirectory: false)
    }
}
