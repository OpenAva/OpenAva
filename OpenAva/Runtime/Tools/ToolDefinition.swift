import Foundation
import OpenClawKit

/// Defines an available tool that can be called by the LLM.
struct ToolDefinition: Equatable, Sendable {
    let functionName: String
    let command: String
    let description: String
    let parametersSchema: AnyCodable
    let isReadOnly: Bool?
    let isDestructive: Bool?
    let isConcurrencySafe: Bool?
    let maxResultSizeChars: Int?

    nonisolated init(
        functionName: String,
        command: String,
        description: String,
        parametersSchema: AnyCodable,
        isReadOnly: Bool? = nil,
        isDestructive: Bool? = nil,
        isConcurrencySafe: Bool? = nil,
        maxResultSizeChars: Int? = nil
    ) {
        self.functionName = functionName
        self.command = command
        self.description = description
        self.parametersSchema = parametersSchema
        self.isReadOnly = isReadOnly
        self.isDestructive = isDestructive
        self.isConcurrencySafe = isConcurrencySafe
        self.maxResultSizeChars = maxResultSizeChars
    }
}

extension ToolDefinition {
    nonisolated var resolvedIsReadOnly: Bool {
        if let isReadOnly {
            return isReadOnly
        }
        return Self.defaultReadOnlyCommands.contains(command)
    }

    nonisolated var resolvedIsDestructive: Bool {
        if let isDestructive {
            return isDestructive
        }
        return Self.defaultDestructiveCommands.contains(command)
    }

    nonisolated var resolvedIsConcurrencySafe: Bool {
        if let isConcurrencySafe {
            return isConcurrencySafe
        }
        guard resolvedIsReadOnly else {
            return false
        }
        return !Self.defaultSerializedReadOnlyCommands.contains(command)
    }
}

private extension ToolDefinition {
    nonisolated static let defaultReadOnlyCommands: Set<String> = [
        "fs.read",
        "fs.list",
        "fs.find",
        "fs.grep",
        "memory.history_search",
        "web.search",
        "web.fetch",
        "image.search",
        "youtube.transcript",
        "weather.get",
        "finance.yahoo",
        "finance.a_share",
        "location.get",
        "device.status",
        "device.info",
        "current.time",
        "photos.latest",
        "camera.list",
        "watch.status",
        "motion.activity",
        "motion.pedometer",
        "speech.transcribe",
        "calendar.events",
        "reminders.list",
    ]

    nonisolated static let defaultDestructiveCommands: Set<String> = [
        "fs.write",
        "fs.replace",
        "fs.append",
        "fs.delete",
        "memory.write_long_term",
        "memory.append_history",
    ]

    nonisolated static let defaultSerializedReadOnlyCommands: Set<String> = [
        "location.get",
        "camera.list",
        "photos.latest",
        "watch.status",
        "motion.activity",
        "motion.pedometer",
        "speech.transcribe",
    ]
}
