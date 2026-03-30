//
//  MemoryService.swift
//  MemoryKit
//
//  Tool-oriented memory operations on workspace files.
//

import Foundation

/// Provides high-level memory operations for tool/runtime integration.
public actor MemoryService {
    public enum HistorySearchMode: String {
        case keyword
        case regex
    }

    public enum LongTermMemoryWriteMode: String {
        case replace
        case append
    }

    public struct HistorySearchResult {
        public let fileURL: URL
        public let mode: HistorySearchMode
        public let query: String
        public let hits: [HistorySearchHit]

        public init(fileURL: URL, mode: HistorySearchMode, query: String, hits: [HistorySearchHit]) {
            self.fileURL = fileURL
            self.mode = mode
            self.query = query
            self.hits = hits
        }
    }

    public struct LongTermMemoryWriteResult {
        public let fileURL: URL
        public let mode: LongTermMemoryWriteMode
        public let changed: Bool
        public let duplicateSkipped: Bool
        public let size: Int

        public init(
            fileURL: URL,
            mode: LongTermMemoryWriteMode,
            changed: Bool,
            duplicateSkipped: Bool,
            size: Int
        ) {
            self.fileURL = fileURL
            self.mode = mode
            self.changed = changed
            self.duplicateSkipped = duplicateSkipped
            self.size = size
        }
    }

    public struct HistoryAppendResult {
        public let fileURL: URL
        public let entry: String
        public let appendedSize: Int

        public init(fileURL: URL, entry: String, appendedSize: Int) {
            self.fileURL = fileURL
            self.entry = entry
            self.appendedSize = appendedSize
        }
    }

    private let workspaceDirectory: URL
    private let store: MemoryStore
    private let historySearchService: HistorySearchService

    public init(workspaceDirectory: URL) throws {
        self.workspaceDirectory = workspaceDirectory
        store = try MemoryStore(workspaceDirectory: workspaceDirectory)
        historySearchService = HistorySearchService(
            historyFile: workspaceDirectory.appendingPathComponent("HISTORY.md", isDirectory: false)
        )
    }

    public func searchHistory(
        query: String,
        mode: HistorySearchMode,
        caseInsensitive: Bool = true,
        limit: Int = 20
    ) async throws -> HistorySearchResult {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else {
            throw MemoryServiceError.emptyContent(field: "query")
        }

        let normalizedLimit = min(200, max(1, limit))
        let hits: [HistorySearchHit]
        switch mode {
        case .keyword:
            hits = try await historySearchService.search(
                keyword: normalizedQuery,
                caseInsensitive: caseInsensitive,
                limit: normalizedLimit
            )
        case .regex:
            hits = try await historySearchService.search(regex: normalizedQuery, limit: normalizedLimit)
        }

        return HistorySearchResult(
            fileURL: workspaceDirectory.appendingPathComponent("HISTORY.md", isDirectory: false),
            mode: mode,
            query: normalizedQuery,
            hits: hits
        )
    }

    public func writeLongTermMemory(
        content: String,
        mode: LongTermMemoryWriteMode
    ) async throws -> LongTermMemoryWriteResult {
        let memoryFile = workspaceDirectory.appendingPathComponent("MEMORY.md", isDirectory: false)
        let current = try await store.readLongTermMemory()

        switch mode {
        case .replace:
            let changed = current != content
            if changed {
                try await store.writeLongTermMemory(content)
            }
            return LongTermMemoryWriteResult(
                fileURL: memoryFile,
                mode: mode,
                changed: changed,
                duplicateSkipped: false,
                size: content.lengthOfBytes(using: .utf8)
            )

        case .append:
            let fragment = content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !fragment.isEmpty else {
                throw MemoryServiceError.emptyContent(field: "content")
            }

            if current.localizedCaseInsensitiveContains(fragment) {
                return LongTermMemoryWriteResult(
                    fileURL: memoryFile,
                    mode: mode,
                    changed: false,
                    duplicateSkipped: true,
                    size: current.lengthOfBytes(using: .utf8)
                )
            }

            let updated: String
            if current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                updated = fragment
            } else if current.hasSuffix("\n") {
                updated = current + fragment
            } else {
                updated = current + "\n" + fragment
            }

            try await store.writeLongTermMemory(updated)
            return LongTermMemoryWriteResult(
                fileURL: memoryFile,
                mode: mode,
                changed: true,
                duplicateSkipped: false,
                size: updated.lengthOfBytes(using: .utf8)
            )
        }
    }

    public func appendHistory(entry: String, now: Date = Date()) async throws -> HistoryAppendResult {
        let normalizedEntry = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedEntry.isEmpty else {
            throw MemoryServiceError.emptyContent(field: "entry")
        }

        // Runtime provides raw summary text, while service enforces stable timestamp prefix.
        let stampedEntry = "[\(Self.historyTimestampFormatter.string(from: now))] \(normalizedEntry)"
        try await store.appendHistory(stampedEntry)
        return HistoryAppendResult(
            fileURL: workspaceDirectory.appendingPathComponent("HISTORY.md", isDirectory: false),
            entry: stampedEntry,
            appendedSize: stampedEntry.lengthOfBytes(using: .utf8)
        )
    }

    private static let historyTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()
}

public enum MemoryServiceError: LocalizedError {
    case emptyContent(field: String)

    public var errorDescription: String? {
        switch self {
        case let .emptyContent(field):
            return "INVALID_REQUEST: \(field) is required"
        }
    }
}
