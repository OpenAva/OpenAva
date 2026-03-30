//
//  MemoryCoordinator.swift
//  MemoryKit
//
//  Session-scoped consolidation scheduler with de-duplication.
//

import Foundation

/// Drives when and how memory consolidation runs for a session.
public actor MemoryCoordinator {
    private let store: MemoryStore
    private let consolidator: any MemoryConsolidator

    public let memoryWindow: Int

    public init(
        store: MemoryStore,
        consolidator: any MemoryConsolidator,
        memoryWindow: Int = 100
    ) {
        self.store = store
        self.consolidator = consolidator
        self.memoryWindow = max(2, memoryWindow)
    }

    /// Reads the long-term memory prompt fragment for system injection.
    public func memoryContext() async -> String {
        await(try? store.memoryContext()) ?? ""
    }

    /// Consolidates a session slice and updates offset state.
    /// Returns true when operation succeeds (including no-op), false on failure.
    @discardableResult
    public func consolidateIfNeeded(
        records: [MemoryRecord],
        state: inout SessionMemoryState,
        archiveAll: Bool = false
    ) async -> Bool {
        let keepCount = max(1, memoryWindow / 2)
        let unconsolidated = max(0, records.count - state.lastConsolidated)
        if !archiveAll, unconsolidated < memoryWindow {
            return true
        }

        let oldRecords: ArraySlice<MemoryRecord>
        if archiveAll {
            oldRecords = records[...]
        } else {
            let boundedOffset = min(max(0, state.lastConsolidated), records.count)
            let tailStart = max(0, records.count - keepCount)
            guard tailStart > boundedOffset else { return true }
            oldRecords = records[boundedOffset ..< tailStart]
        }

        guard !oldRecords.isEmpty else { return true }

        do {
            let currentMemory = try await store.readLongTermMemory()
            let result = try await consolidator.consolidate(
                currentLongTermMemory: currentMemory,
                records: Array(oldRecords),
                archiveAll: archiveAll
            )

            let historyEntry = result.historyEntry.trimmingCharacters(in: .whitespacesAndNewlines)
            if !historyEntry.isEmpty {
                try await store.appendHistory(historyEntry)
            }

            if result.memoryUpdate != currentMemory {
                try await store.writeLongTermMemory(result.memoryUpdate)
            }

            state.lastConsolidated = archiveAll ? 0 : max(0, records.count - keepCount)
            return true
        } catch {
            return false
        }
    }
}
