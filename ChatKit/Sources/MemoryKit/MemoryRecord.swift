//
//  MemoryRecord.swift
//  MemoryKit
//
//  Shared value types for memory consolidation and retrieval.
//

import Foundation

/// A lightweight turn record used by memory consolidation.
public struct MemoryRecord: Sendable, Codable, Equatable {
    public let role: String
    public let content: String
    public let timestamp: Date
    public let toolsUsed: [String]

    public init(
        role: String,
        content: String,
        timestamp: Date,
        toolsUsed: [String] = []
    ) {
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.toolsUsed = toolsUsed
    }
}

/// Result payload returned by a consolidation engine.
public struct MemoryConsolidationResult: Sendable, Codable, Equatable {
    public let historyEntry: String
    public let memoryUpdate: String

    public init(historyEntry: String, memoryUpdate: String) {
        self.historyEntry = historyEntry
        self.memoryUpdate = memoryUpdate
    }
}

/// Tracks session-level offset of already consolidated messages.
public struct SessionMemoryState: Sendable, Codable, Equatable {
    public var lastConsolidated: Int

    public init(lastConsolidated: Int = 0) {
        self.lastConsolidated = max(0, lastConsolidated)
    }
}
