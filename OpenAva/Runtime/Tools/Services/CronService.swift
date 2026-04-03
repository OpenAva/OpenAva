import Foundation
import OpenClawKit
import UserNotifications

// MARK: - Command Types

enum CronCommand: String, Codable {
    case cron
}

enum CronAction: String, Codable {
    case add
    case list
    case remove
}

enum CronNotificationMetadataKey {
    static let marker = "openava.cron.marker"
    static let name = "openava.cron.name"
    static let kind = "openava.cron.kind"
    static let agentID = "openava.cron.agentID"
    static let schedule = "openava.cron.schedule"
    static let at = "openava.cron.at"
    static let everySeconds = "openava.cron.everySeconds"
    static let createdAt = "openava.cron.createdAt"
}

struct CronNotificationMetadata {
    let jobID: String
    let kind: CronJobKind
    let agentID: String?

    init?(request: UNNotificationRequest) {
        let userInfo = request.content.userInfo
        guard let marked = userInfo[CronNotificationMetadataKey.marker] as? Bool, marked else {
            return nil
        }

        jobID = request.identifier
        kind = Self.kind(from: userInfo)
        agentID = Self.agentID(from: userInfo)
    }

    static func kind(from userInfo: [AnyHashable: Any]) -> CronJobKind {
        guard let rawValue = userInfo[CronNotificationMetadataKey.kind] as? String,
              let kind = CronJobKind(rawValue: rawValue)
        else {
            return .notify
        }
        return kind
    }

    static func agentID(from userInfo: [AnyHashable: Any]) -> String? {
        guard let rawValue = userInfo[CronNotificationMetadataKey.agentID] as? String else {
            return nil
        }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// A single cron tool endpoint that branches by action.
struct CronParams: Codable, Equatable {
    var action: CronAction
    var message: String?
    var kind: CronJobKind
    var agentID: String?
    var at: String?
    var everySeconds: Int?
    var id: String?

    enum CodingKeys: String, CodingKey {
        case action
        case message
        case kind
        case agentID
        case agentId
        case agent_id
        case at
        case everySeconds
        case every_seconds
        case id
        case jobId
        case job_id
    }

    init(
        action: CronAction,
        message: String? = nil,
        kind: CronJobKind = .notify,
        agentID: String? = nil,
        at: String? = nil,
        everySeconds: Int? = nil,
        id: String? = nil
    ) {
        self.action = action
        self.message = message
        self.kind = kind
        self.agentID = agentID
        self.at = at
        self.everySeconds = everySeconds
        self.id = id
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        action = try container.decode(CronAction.self, forKey: .action)
        message = try container.decodeIfPresent(String.self, forKey: .message)
        kind = try container.decodeIfPresent(CronJobKind.self, forKey: .kind) ?? .notify
        agentID =
            try container.decodeIfPresent(String.self, forKey: .agentID) ??
            container.decodeIfPresent(String.self, forKey: .agentId) ??
            container.decodeIfPresent(String.self, forKey: .agent_id)
        at = try container.decodeIfPresent(String.self, forKey: .at)
        everySeconds =
            try container.decodeIfPresent(Int.self, forKey: .everySeconds) ??
            container.decodeIfPresent(Int.self, forKey: .every_seconds)
        id =
            try container.decodeIfPresent(String.self, forKey: .id) ??
            container.decodeIfPresent(String.self, forKey: .jobId) ??
            container.decodeIfPresent(String.self, forKey: .job_id)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(action, forKey: .action)
        try container.encodeIfPresent(message, forKey: .message)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(agentID, forKey: .agentID)
        try container.encodeIfPresent(at, forKey: .at)
        try container.encodeIfPresent(everySeconds, forKey: .everySeconds)
        try container.encodeIfPresent(id, forKey: .id)
    }
}

// MARK: - Additional Payload Types

struct CronAddPayload: Codable, Equatable {
    var job: CronJobPayload
}

struct CronRemovePayload: Codable, Equatable {
    var id: String
    var removed: Bool
}

// MARK: - Errors

enum CronServiceError: Error, LocalizedError {
    case invalidRequest(String)
    case schedulingFailed(String)

    var errorDescription: String? {
        switch self {
        case let .invalidRequest(message):
            return "INVALID_REQUEST: \(message)"
        case let .schedulingFailed(message):
            return "CRON_SCHEDULING_FAILED: \(message)"
        }
    }
}

// MARK: - Protocol

protocol CronServicing: Sendable {
    func add(message: String, atISO: String?, everySeconds: Int?, kind: CronJobKind, agentID: String?) async throws -> CronJobPayload
    func list() async throws -> CronListPayload
    func remove(id: String) async throws -> CronRemovePayload
}

extension CronServicing {
    func add(message: String, atISO: String?, everySeconds: Int?) async throws -> CronJobPayload {
        try await add(message: message, atISO: atISO, everySeconds: everySeconds, kind: .notify, agentID: nil)
    }
}

// MARK: - Service Implementation

final class CronService: CronServicing {
    private static let identifierPrefix = "cron."

    /// Keep one shared formatter to avoid repeated allocations in hot paths.
    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let legacyISOFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    func add(
        message: String,
        atISO: String?,
        everySeconds: Int?,
        kind: CronJobKind,
        agentID: String?
    ) async throws -> CronJobPayload {
        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedAgentID = AppConfig.nonEmpty(agentID)
        if kind == .heartbeat, normalizedAgentID == nil {
            throw CronServiceError.invalidRequest("agentID is required for heartbeat cron jobs")
        }

        let text: String
        switch kind {
        case .notify:
            guard !trimmedMessage.isEmpty else {
                throw CronServiceError.invalidRequest("message is required")
            }
            text = trimmedMessage
        case .heartbeat:
            text = trimmedMessage.isEmpty ? "Run heartbeat" : trimmedMessage
        }

        let atValue = atISO?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasAt = (atValue?.isEmpty == false)
        let hasEvery = everySeconds != nil
        guard hasAt != hasEvery else {
            throw CronServiceError.invalidRequest("provide exactly one of 'at' or 'everySeconds'")
        }

        let identifier = Self.identifierPrefix + UUID().uuidString.lowercased()
        let name = String(text.prefix(30))
        let createdAtISO = Self.isoFormatter.string(from: Date())

        let trigger: UNNotificationTrigger
        let schedule: String
        let cronValue: String
        var normalizedAtISO: String?
        var normalizedEverySeconds: Int?

        if hasAt {
            guard let rawAt = atValue, let atDate = Self.parseISODate(rawAt) else {
                throw CronServiceError.invalidRequest("'at' must be an ISO-8601 datetime")
            }
            guard atDate.timeIntervalSinceNow > 1 else {
                throw CronServiceError.invalidRequest("'at' must be in the future")
            }

            let dateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute, .second, .nanosecond],
                from: atDate
            )
            trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: false)
            schedule = "at"
            normalizedAtISO = Self.isoFormatter.string(from: atDate)
            cronValue = normalizedAtISO ?? rawAt
        } else {
            guard let every = everySeconds else {
                throw CronServiceError.invalidRequest("'everySeconds' is required")
            }
            // iOS enforces a minimum of 60s for repeating time-interval notifications.
            guard every >= 60 else {
                throw CronServiceError.invalidRequest("'everySeconds' must be at least 60")
            }

            trigger = UNTimeIntervalNotificationTrigger(timeInterval: TimeInterval(every), repeats: true)
            schedule = "every"
            normalizedEverySeconds = every
            cronValue = "every \(every)s"
        }

        let content = UNMutableNotificationContent()
        content.title = "OpenAva"
        content.body = text
        content.sound = .default
        content.userInfo = [
            CronNotificationMetadataKey.marker: true,
            CronNotificationMetadataKey.name: name,
            CronNotificationMetadataKey.kind: kind.rawValue,
            CronNotificationMetadataKey.agentID: normalizedAgentID ?? "",
            CronNotificationMetadataKey.schedule: schedule,
            CronNotificationMetadataKey.at: normalizedAtISO ?? "",
            CronNotificationMetadataKey.everySeconds: normalizedEverySeconds ?? 0,
            CronNotificationMetadataKey.createdAt: createdAtISO,
        ]

        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        do {
            try await addRequest(request)
        } catch {
            throw CronServiceError.schedulingFailed(error.localizedDescription)
        }

        let payload = CronJobPayload(
            id: identifier,
            name: name,
            message: text,
            kind: kind,
            agentID: normalizedAgentID,
            schedule: schedule,
            cron: cronValue,
            at: normalizedAtISO,
            everySeconds: normalizedEverySeconds,
            nextRunISO: nextTriggerISO(from: trigger),
            createdAtISO: createdAtISO
        )

        // Update Live Activity with new job list
        await updateLiveActivity()

        return payload
    }

    func list() async throws -> CronListPayload {
        let requests = await pendingRequests()
        let jobs: [CronJobPayload] = requests.compactMap { request in
            self.jobPayload(from: request)
        }
        .sorted { lhs, rhs in
            let left = lhs.nextRunISO.flatMap(Self.parseISODate)
            let right = rhs.nextRunISO.flatMap(Self.parseISODate)
            switch (left, right) {
            case let (l?, r?):
                return l < r
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                return lhs.createdAtISO < rhs.createdAtISO
            }
        }
        return CronListPayload(jobs: jobs)
    }

    func remove(id: String) async throws -> CronRemovePayload {
        let normalizedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedID.isEmpty else {
            throw CronServiceError.invalidRequest("id is required")
        }

        let exists = await pendingRequests().contains(where: { $0.identifier == normalizedID })
        if exists {
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [normalizedID])
        }

        // Update Live Activity after removal
        await updateLiveActivity()

        return CronRemovePayload(id: normalizedID, removed: exists)
    }

    // MARK: - Live Activity Integration

    private func updateLiveActivity() async {
        #if !targetEnvironment(macCatalyst)
            if #available(iOS 16.1, *) {
                do {
                    let list = try await list()
                    await CronActivityService.shared.updateActivity(with: list.jobs)
                } catch {
                    // Silently fail - Live Activity is optional
                }
            }
        #endif
    }

    // MARK: - Private Helpers

    private func pendingRequests() async -> [UNNotificationRequest] {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getPendingNotificationRequests { requests in
                continuation.resume(returning: requests)
            }
        }
    }

    private func addRequest(_ request: UNNotificationRequest) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            UNUserNotificationCenter.current().add(request) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    private func jobPayload(from request: UNNotificationRequest) -> CronJobPayload? {
        guard request.identifier.hasPrefix(Self.identifierPrefix) else {
            return nil
        }
        guard let metadata = CronNotificationMetadata(request: request) else {
            return nil
        }

        let userInfo = request.content.userInfo
        let message = request.content.body.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackName = String(message.prefix(30))

        let schedule = (userInfo[CronNotificationMetadataKey.schedule] as? String) ?? "unknown"
        let at = nonEmptyString(userInfo[CronNotificationMetadataKey.at])
        let everySeconds = intValue(userInfo[CronNotificationMetadataKey.everySeconds])
        let createdAtISO =
            nonEmptyString(userInfo[CronNotificationMetadataKey.createdAt]) ??
            Self.isoFormatter.string(from: Date())

        let cronValue: String?
        if let at, schedule == "at" {
            cronValue = at
        } else if let everySeconds, schedule == "every" {
            cronValue = "every \(everySeconds)s"
        } else {
            cronValue = nil
        }

        return CronJobPayload(
            id: request.identifier,
            name: nonEmptyString(userInfo[CronNotificationMetadataKey.name]) ?? fallbackName,
            message: message,
            kind: metadata.kind,
            agentID: metadata.agentID,
            schedule: schedule,
            cron: cronValue,
            at: at,
            everySeconds: everySeconds,
            nextRunISO: nextTriggerISO(from: request.trigger),
            createdAtISO: createdAtISO
        )
    }

    private func nextTriggerISO(from trigger: UNNotificationTrigger?) -> String? {
        let nextDate: Date?
        if let calendarTrigger = trigger as? UNCalendarNotificationTrigger {
            nextDate = calendarTrigger.nextTriggerDate()
        } else if let intervalTrigger = trigger as? UNTimeIntervalNotificationTrigger {
            nextDate = intervalTrigger.nextTriggerDate()
        } else {
            nextDate = nil
        }
        return nextDate.map { Self.isoFormatter.string(from: $0) }
    }

    private func nonEmptyString(_ value: Any?) -> String? {
        guard let raw = value as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func intValue(_ value: Any?) -> Int? {
        if let intValue = value as? Int {
            return intValue
        }
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let string = value as? String {
            return Int(string)
        }
        return nil
    }

    private static func parseISODate(_ value: String) -> Date? {
        if let parsed = isoFormatter.date(from: value) {
            return parsed
        }
        if let parsed = legacyISOFormatter.date(from: value) {
            return parsed
        }
        return parseLocalDateWithoutTimezone(value)
    }

    /// Accept local ISO strings like 2026-02-12T10:30:00 when timezone is omitted.
    private static func parseLocalDateWithoutTimezone(_ value: String) -> Date? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: "T", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }

        let dateParts = parts[0].split(separator: "-")
        let timeParts = parts[1].split(separator: ":")
        guard dateParts.count == 3, timeParts.count >= 2 else { return nil }

        guard let year = Int(dateParts[0]),
              let month = Int(dateParts[1]),
              let day = Int(dateParts[2]),
              let hour = Int(timeParts[0]),
              let minute = Int(timeParts[1])
        else {
            return nil
        }

        var second = 0
        var nanosecond = 0
        if timeParts.count >= 3 {
            let secondText = String(timeParts[2])
            if let secondValue = Int(secondText) {
                second = secondValue
            } else if let secondDouble = Double(secondText) {
                second = Int(secondDouble)
                nanosecond = Int((secondDouble - Double(second)) * 1_000_000_000)
            } else {
                return nil
            }
        }

        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        components.nanosecond = nanosecond
        components.timeZone = .current
        return Calendar.current.date(from: components)
    }
}
