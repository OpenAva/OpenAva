//
//  MemoryConsolidator.swift
//  MemoryKit
//
//  Abstraction for model-driven memory consolidation.
//

import Foundation

/// Converts old conversation turns into history entry and long-term memory update.
public protocol MemoryConsolidator: Sendable {
    func consolidate(
        currentLongTermMemory: String,
        records: [MemoryRecord],
        archiveAll: Bool
    ) async throws -> MemoryConsolidationResult
}
