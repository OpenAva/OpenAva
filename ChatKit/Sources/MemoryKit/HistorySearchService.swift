//
//  HistorySearchService.swift
//  MemoryKit
//
//  Plain-text search over HISTORY.md.
//

import Foundation

/// A simple grep-like search result for history log lines.
public struct HistorySearchHit: Sendable, Equatable {
    public let lineNumber: Int
    public let line: String

    public init(lineNumber: Int, line: String) {
        self.lineNumber = lineNumber
        self.line = line
    }
}

/// Provides keyword and regex search on `HISTORY.md`.
public actor HistorySearchService {
    private let historyFile: URL

    public init(historyFile: URL) {
        self.historyFile = historyFile
    }

    public func search(keyword: String, caseInsensitive: Bool = true, limit: Int = 20) throws -> [HistorySearchHit] {
        guard !keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let content = try String(contentsOf: historyFile, encoding: .utf8)
        let lines = content.components(separatedBy: .newlines)
        let opts: String.CompareOptions = caseInsensitive ? [.caseInsensitive] : []

        var hits: [HistorySearchHit] = []
        hits.reserveCapacity(min(limit, 20))
        for (idx, line) in lines.enumerated() {
            if line.range(of: keyword, options: opts) != nil {
                hits.append(.init(lineNumber: idx + 1, line: line))
                if hits.count >= max(1, limit) {
                    break
                }
            }
        }
        return hits
    }

    public func search(regex pattern: String, limit: Int = 20) throws -> [HistorySearchHit] {
        guard !pattern.isEmpty else { return [] }
        let content = try String(contentsOf: historyFile, encoding: .utf8)
        let lines = content.components(separatedBy: .newlines)
        let regex = try NSRegularExpression(pattern: pattern)

        var hits: [HistorySearchHit] = []
        hits.reserveCapacity(min(limit, 20))
        for (idx, line) in lines.enumerated() {
            let range = NSRange(location: 0, length: line.utf16.count)
            if regex.firstMatch(in: line, options: [], range: range) != nil {
                hits.append(.init(lineNumber: idx + 1, line: line))
                if hits.count >= max(1, limit) {
                    break
                }
            }
        }
        return hits
    }
}
