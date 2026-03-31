import ChatClient
import ChatUI
import Combine
import Foundation

/// Per-model accumulated usage.
public struct ModelUsageRecord: Sendable, Equatable {
    public var model: String
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheReadTokens: Int
    public var cacheWriteTokens: Int
    public var costUSD: Double

    public var totalTokens: Int {
        inputTokens + outputTokens
    }

    public init(
        model: String,
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        cacheReadTokens: Int = 0,
        cacheWriteTokens: Int = 0,
        costUSD: Double = 0
    ) {
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.costUSD = costUSD
    }

    fileprivate mutating func add(_ usage: TokenUsage) {
        inputTokens += usage.inputTokens
        outputTokens += usage.outputTokens
        cacheReadTokens += usage.cacheReadTokens
        cacheWriteTokens += usage.cacheWriteTokens
        if let cost = usage.costUSD {
            costUSD += cost
        }
    }
}

/// Aggregated snapshot of all tracked usage.
public struct UsageSnapshot: Sendable, Equatable {
    public var byModel: [String: ModelUsageRecord]

    public var totalInputTokens: Int {
        byModel.values.reduce(0) { $0 + $1.inputTokens }
    }

    public var totalOutputTokens: Int {
        byModel.values.reduce(0) { $0 + $1.outputTokens }
    }

    public var totalCacheReadTokens: Int {
        byModel.values.reduce(0) { $0 + $1.cacheReadTokens }
    }

    public var totalCacheWriteTokens: Int {
        byModel.values.reduce(0) { $0 + $1.cacheWriteTokens }
    }

    public var totalTokens: Int {
        totalInputTokens + totalOutputTokens
    }

    public var totalCostUSD: Double {
        byModel.values.reduce(0) { $0 + $1.costUSD }
    }

    /// Sorted model records, highest total tokens first.
    public var sortedRecords: [ModelUsageRecord] {
        byModel.values.sorted { $0.totalTokens > $1.totalTokens }
    }

    public init(byModel: [String: ModelUsageRecord] = [:]) {
        self.byModel = byModel
    }
}

// MARK: - Persistence

private extension UsageSnapshot {
    struct Coded: Codable {
        struct Record: Codable {
            var model: String
            var inputTokens: Int
            var outputTokens: Int
            var cacheReadTokens: Int
            var cacheWriteTokens: Int
            var costUSD: Double
        }

        var records: [Record]
    }

    static func load(from url: URL) -> UsageSnapshot {
        guard let data = try? Data(contentsOf: url),
              let coded = try? JSONDecoder().decode(Coded.self, from: data)
        else { return UsageSnapshot() }

        var byModel: [String: ModelUsageRecord] = [:]
        for r in coded.records {
            byModel[r.model] = ModelUsageRecord(
                model: r.model,
                inputTokens: r.inputTokens,
                outputTokens: r.outputTokens,
                cacheReadTokens: r.cacheReadTokens,
                cacheWriteTokens: r.cacheWriteTokens,
                costUSD: r.costUSD
            )
        }
        return UsageSnapshot(byModel: byModel)
    }

    func save(to url: URL) {
        let records = byModel.values.map { r in
            Coded.Record(
                model: r.model,
                inputTokens: r.inputTokens,
                outputTokens: r.outputTokens,
                cacheReadTokens: r.cacheReadTokens,
                cacheWriteTokens: r.cacheWriteTokens,
                costUSD: r.costUSD
            )
        }
        let coded = Coded(records: records)
        guard let data = try? JSONEncoder().encode(coded) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

// MARK: - Tracker

/// Accumulates token usage across all inference sessions.
///
/// Thread-safe via `actor` isolation. Persists cumulative totals to disk so
/// statistics survive app restarts.
public actor LLMUsageTracker {
    public static let shared = LLMUsageTracker()

    private var snapshot: UsageSnapshot
    private let persistURL: URL
    private let subject: PassthroughSubject<UsageSnapshot, Never>

    /// Publisher emitting the latest snapshot after each update.
    public nonisolated let snapshotDidChange: AnyPublisher<UsageSnapshot, Never>

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        persistURL = caches.appendingPathComponent("llm_token_usage.json")
        let initial = UsageSnapshot.load(from: persistURL)
        snapshot = initial
        let sub = PassthroughSubject<UsageSnapshot, Never>()
        subject = sub
        snapshotDidChange = sub.eraseToAnyPublisher()
    }

    // MARK: - Public Interface

    /// Current aggregated usage snapshot.
    public var current: UsageSnapshot {
        snapshot
    }

    /// Record a `TokenUsage` event. The `model` field on the usage is used as
    /// the bucket key; falls back to an explicit parameter.
    public func record(_ usage: TokenUsage, model: String? = nil) {
        let key = usage.model ?? model ?? "unknown"
        var record = snapshot.byModel[key] ?? ModelUsageRecord(model: key)
        record.add(usage)
        snapshot.byModel[key] = record
        snapshot.save(to: persistURL)
        subject.send(snapshot)
    }

    /// Wipe all accumulated data.
    public func reset() {
        snapshot = UsageSnapshot()
        snapshot.save(to: persistURL)
        subject.send(snapshot)
    }
}
