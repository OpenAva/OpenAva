import Foundation

// MARK: - Cron Job Payload

public enum CronJobKind: String, Codable, Sendable, Equatable {
    case notify
    case heartbeat
}

/// Payload representing a scheduled cron job
public struct CronJobPayload: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var message: String
    public var kind: CronJobKind
    public var agentID: String?
    public var schedule: String
    public var cron: String?
    public var at: String?
    public var everySeconds: Int?
    public var nextRunISO: String?
    public var createdAtISO: String

    public init(
        id: String,
        name: String,
        message: String,
        kind: CronJobKind = .notify,
        agentID: String? = nil,
        schedule: String,
        cron: String? = nil,
        at: String? = nil,
        everySeconds: Int? = nil,
        nextRunISO: String? = nil,
        createdAtISO: String
    ) {
        self.id = id
        self.name = name
        self.message = message
        self.kind = kind
        self.agentID = agentID
        self.schedule = schedule
        self.cron = cron
        self.at = at
        self.everySeconds = everySeconds
        self.nextRunISO = nextRunISO
        self.createdAtISO = createdAtISO
    }
}

// MARK: - Cron List Payload

public struct CronListPayload: Codable, Sendable, Equatable {
    public var jobs: [CronJobPayload]

    public init(jobs: [CronJobPayload]) {
        self.jobs = jobs
    }
}
