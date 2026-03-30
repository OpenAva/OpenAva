//
//  MemoryStore.swift
//  MemoryKit
//
//  File-backed two-layer memory store.
//

import Foundation

/// Persists memory as `MEMORY.md` and `HISTORY.md` under a workspace.
public actor MemoryStore {
    public let memoryFile: URL
    public let historyFile: URL

    public init(workspaceDirectory: URL, fileManager: FileManager = .default) throws {
        memoryFile = workspaceDirectory.appendingPathComponent("MEMORY.md")
        historyFile = workspaceDirectory.appendingPathComponent("HISTORY.md")

        // Create empty files early so host code can safely read paths.
        if !fileManager.fileExists(atPath: memoryFile.path) {
            try "".write(to: memoryFile, atomically: true, encoding: .utf8)
        }
        if !fileManager.fileExists(atPath: historyFile.path) {
            try "".write(to: historyFile, atomically: true, encoding: .utf8)
        }
    }

    public func readLongTermMemory() throws -> String {
        try String(contentsOf: memoryFile, encoding: .utf8)
    }

    public func writeLongTermMemory(_ content: String) throws {
        try content.write(to: memoryFile, atomically: true, encoding: .utf8)
    }

    public func appendHistory(_ entry: String) throws {
        let payload = entry.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n"
        if let handle = try? FileHandle(forWritingTo: historyFile) {
            try handle.seekToEnd()
            if let data = payload.data(using: .utf8) {
                try handle.write(contentsOf: data)
            }
            try handle.close()
            return
        }
        try payload.write(to: historyFile, atomically: true, encoding: .utf8)
    }

    /// Returns HISTORY.md entries dated today or yesterday as a string.
    public func recentHistoryContext(now: Date = Date(), calendar: Calendar = .current) throws -> String {
        let raw = try String(contentsOf: historyFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return "" }

        let startOfToday = calendar.startOfDay(for: now)
        guard let startOfYesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday) else { return "" }

        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let todayString = dateFormatter.string(from: startOfToday)
        let yesterdayString = dateFormatter.string(from: startOfYesterday)

        // Entries are separated by double newlines; each starts with [yyyy-MM-dd HH:mm]
        let entries = raw.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { entry in
                guard !entry.isEmpty, entry.hasPrefix("[") else { return false }
                let datePrefix = String(entry.dropFirst().prefix(10))
                return datePrefix == todayString || datePrefix == yesterdayString
            }

        guard !entries.isEmpty else { return "" }
        return entries.joined(separator: "\n\n")
    }

    /// Returns a combined memory context string for system prompt injection.
    /// Includes long-term memory and recent history (today + yesterday).
    public func memoryContext(now: Date = Date(), calendar: Calendar = .current) throws -> String {
        let longTerm = try readLongTermMemory().trimmingCharacters(in: .whitespacesAndNewlines)
        let recentHistory = try recentHistoryContext(now: now, calendar: calendar)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var parts: [String] = []
        if !longTerm.isEmpty {
            parts.append("## Long-term Memory\n\(longTerm)")
        }
        if !recentHistory.isEmpty {
            parts.append("## Recent History\n\(recentHistory)")
        }
        return parts.joined(separator: "\n\n")
    }
}
