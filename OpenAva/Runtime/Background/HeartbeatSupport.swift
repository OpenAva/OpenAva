import ChatUI
import Foundation

enum HeartbeatSupport {
    enum ResultClassification: Equatable {
        case ackOnly
        case actionRequired(String)
        case empty
    }

    struct ParsedDocument: Equatable {
        var instructions: String
        var configuration: Configuration
    }

    struct Configuration: Equatable {
        enum NotificationMode: String, Equatable {
            case silent
            case always
        }

        var interval: TimeInterval
        var activeHours: [ActiveHourRange]
        var notify: NotificationMode

        static let `default` = Configuration(
            interval: HeartbeatSupport.defaultInterval,
            activeHours: [],
            notify: .always
        )

        func isActive(at date: Date, calendar: Calendar = .current) -> Bool {
            guard !activeHours.isEmpty else { return true }
            return activeHours.contains { $0.contains(date: date, calendar: calendar) }
        }

        func delayUntilActive(from date: Date, calendar: Calendar = .current) -> TimeInterval? {
            guard !activeHours.isEmpty else { return nil }
            if isActive(at: date, calendar: calendar) {
                return 0
            }

            let delays = activeHours.compactMap { $0.delayUntilActive(from: date, calendar: calendar) }
            return delays.min()
        }
    }

    struct ActiveHourRange: Equatable {
        let startMinuteOfDay: Int
        let endMinuteOfDay: Int

        func contains(date: Date, calendar: Calendar = .current) -> Bool {
            let minute = minuteOfDay(for: date, calendar: calendar)
            if startMinuteOfDay == endMinuteOfDay {
                return true
            }
            if startMinuteOfDay < endMinuteOfDay {
                return minute >= startMinuteOfDay && minute < endMinuteOfDay
            }
            return minute >= startMinuteOfDay || minute < endMinuteOfDay
        }

        func delayUntilActive(from date: Date, calendar: Calendar = .current) -> TimeInterval? {
            if contains(date: date, calendar: calendar) {
                return 0
            }

            let minute = minuteOfDay(for: date, calendar: calendar)
            let minutesUntilStart: Int
            if startMinuteOfDay < endMinuteOfDay {
                minutesUntilStart = minute < startMinuteOfDay
                    ? startMinuteOfDay - minute
                    : (24 * 60 - minute) + startMinuteOfDay
            } else {
                minutesUntilStart = startMinuteOfDay - minute
            }

            let seconds = TimeInterval(max(0, minutesUntilStart) * 60)
            let secondsIntoCurrentMinute = TimeInterval(calendar.component(.second, from: date))
            return max(0, seconds - secondsIntoCurrentMinute)
        }

        private func minuteOfDay(for date: Date, calendar: Calendar) -> Int {
            let components = calendar.dateComponents([.hour, .minute], from: date)
            return (components.hour ?? 0) * 60 + (components.minute ?? 0)
        }
    }

    static let heartbeatFileName = "HEARTBEAT.md"
    static let ackToken = "HEARTBEAT_OK"
    static let ackMaxChars = 300
    static let retainMessageLimit = 20
    static let defaultInterval: TimeInterval = 30 * 60
    static let queryTextPrefix = "[Heartbeat] Scheduled check"
    static let metadataSourceKey = ConversationSession.PromptInput.sourceMetadataKey
    static let metadataSourceValue = "heartbeat"
    static let metadataModeKey = "heartbeatMode"
    static let metadataModeScheduledValue = "scheduled"
    static let metadataAckStateKey = "heartbeatAckState"
    static let metadataAckOnlyValue = "ackOnly"
    static let metadataActionRequiredValue = "actionRequired"

    private static let promptTimestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let yamlDelimiter = "---"

    static func mainSessionID(_ sessionID: String?) -> String {
        AppConfig.nonEmpty(sessionID) ?? "main"
    }

    static func buildPrompt(heartbeatMarkdown: String, now: Date = Date()) -> String {
        let normalizedMarkdown = heartbeatMarkdown.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayText = buildDisplayText(now: now)

        return """
        \(displayText)

        You are running a scheduled heartbeat turn inside OpenAva.
        Follow the instructions in HEARTBEAT.md below.
        Use tools when needed.
        If nothing needs attention, reply with exactly \(ackToken).

        <HEARTBEAT_MD>
        \(normalizedMarkdown)
        </HEARTBEAT_MD>
        """
    }

    static func buildDisplayText(now: Date = Date()) -> String {
        let timestamp = promptTimestampFormatter.string(from: now)
        return """
        \(queryTextPrefix)

        Current time: \(timestamp)
        """
    }

    static func makePromptInput(
        heartbeatMarkdown: String,
        now: Date = Date()
    ) -> ConversationSession.PromptInput {
        .init(
            text: buildPrompt(heartbeatMarkdown: heartbeatMarkdown, now: now),
            source: .heartbeat,
            metadata: [
                metadataModeKey: metadataModeScheduledValue,
            ]
        )
    }

    static func parseDocument(_ rawMarkdown: String) -> ParsedDocument {
        let normalizedInput = rawMarkdown.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedInput.hasPrefix(yamlDelimiter) else {
            return ParsedDocument(instructions: normalizedInput, configuration: .default)
        }

        let lines = normalizedInput.components(separatedBy: .newlines)
        guard lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == yamlDelimiter,
              let closingIndex = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == yamlDelimiter })
        else {
            return ParsedDocument(instructions: normalizedInput, configuration: .default)
        }

        let frontMatterLines = Array(lines[1 ..< closingIndex])
        let bodyLines = Array(lines[(closingIndex + 1)...])
        let frontMatter = parseFrontMatter(frontMatterLines)
        let configuration = makeConfiguration(from: frontMatter)
        let body = bodyLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return ParsedDocument(instructions: body.isEmpty ? normalizedInput : body, configuration: configuration)
    }

    static func normalizedAckRemainder(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed == ackToken {
            return ""
        }

        if trimmed.hasPrefix(ackToken) {
            return String(trimmed.dropFirst(ackToken.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if trimmed.hasSuffix(ackToken) {
            return String(trimmed.dropLast(ackToken.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return nil
    }

    static func shouldSuppressAssistantMessage(_ text: String) -> Bool {
        guard let remainder = normalizedAckRemainder(from: text) else {
            return false
        }
        return remainder.count <= ackMaxChars
    }

    static func classifyAssistantMessage(_ text: String) -> ResultClassification {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .empty
        }

        if shouldSuppressAssistantMessage(trimmed) {
            return .ackOnly
        }

        return .actionRequired(trimmed)
    }

    static func previewText(for message: ConversationMessage) -> String? {
        guard message.metadata[metadataSourceKey] == metadataSourceValue else {
            return nil
        }

        switch message.role {
        case .user:
            return queryTextPrefix
        case .assistant:
            let ackState = message.metadata[metadataAckStateKey]
            if ackState == metadataAckOnlyValue {
                return "Heartbeat：无异常"
            }
            let trimmed = message.textContent.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return "Heartbeat：处理中" }
            return "Heartbeat：\(String(trimmed.prefix(96)))"
        default:
            return nil
        }
    }

    static func trimToRecent<T>(_ items: [T], limit: Int) -> [T] {
        guard limit > 0, items.count > limit else {
            return items
        }
        return Array(items.suffix(limit))
    }

    private static func parseFrontMatter(_ lines: [String]) -> [String: String] {
        var result: [String: String] = [:]
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"),
                  let separatorIndex = trimmed.firstIndex(of: ":")
            else {
                continue
            }

            let rawKey = String(trimmed[..<separatorIndex])
            let rawValue = String(trimmed[trimmed.index(after: separatorIndex)...])
            let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = rawValue
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            result[key] = value
        }
        return result
    }

    private static func makeConfiguration(from frontMatter: [String: String]) -> Configuration {
        var configuration = Configuration.default

        if let every = frontMatter["every"] ?? frontMatter["heartbeat_every"],
           let interval = parseInterval(every)
        {
            configuration.interval = interval
        } else if let everyMinutes = frontMatter["every_minutes"] ?? frontMatter["heartbeat_every_minutes"],
                  let minutes = Double(everyMinutes), minutes > 0
        {
            configuration.interval = minutes * 60
        } else if let everySeconds = frontMatter["every_seconds"] ?? frontMatter["heartbeat_every_seconds"],
                  let seconds = Double(everySeconds), seconds > 0
        {
            configuration.interval = seconds
        }

        if let activeHoursValue = frontMatter["active_hours"] ?? frontMatter["heartbeat_active_hours"] {
            configuration.activeHours = parseActiveHours(activeHoursValue)
        }

        if let notifyValue = frontMatter["notify"] ?? frontMatter["heartbeat_notify"],
           let notifyMode = parseNotificationMode(notifyValue)
        {
            configuration.notify = notifyMode
        }

        return configuration
    }

    private static func parseNotificationMode(_ rawValue: String) -> Configuration.NotificationMode? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch value {
        case Configuration.NotificationMode.silent.rawValue:
            return .silent
        case Configuration.NotificationMode.always.rawValue:
            return .always
        default:
            return nil
        }
    }

    private static func parseInterval(_ rawValue: String) -> TimeInterval? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty else { return nil }

        if let minutes = Double(value), minutes > 0 {
            return minutes * 60
        }

        let units: [(suffix: String, multiplier: Double)] = [
            ("ms", 0.001),
            ("s", 1),
            ("m", 60),
            ("h", 3600),
        ]

        for unit in units {
            if value.hasSuffix(unit.suffix) {
                let numberPart = String(value.dropLast(unit.suffix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                if let amount = Double(numberPart), amount > 0 {
                    return amount * unit.multiplier
                }
            }
        }

        return nil
    }

    private static func parseActiveHours(_ rawValue: String) -> [ActiveHourRange] {
        rawValue
            .split(separator: ",")
            .compactMap { parseActiveHourRange(String($0)) }
    }

    private static func parseActiveHourRange(_ rawRange: String) -> ActiveHourRange? {
        let parts = rawRange.split(separator: "-", maxSplits: 1).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard parts.count == 2,
              let start = parseClock(parts[0]),
              let end = parseClock(parts[1])
        else {
            return nil
        }
        return ActiveHourRange(startMinuteOfDay: start, endMinuteOfDay: end)
    }

    private static func parseClock(_ rawClock: String) -> Int? {
        let parts = rawClock.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2,
              let hour = Int(parts[0]),
              let minute = Int(parts[1]),
              (0 ..< 24).contains(hour),
              (0 ..< 60).contains(minute)
        else {
            return nil
        }
        return hour * 60 + minute
    }
}
