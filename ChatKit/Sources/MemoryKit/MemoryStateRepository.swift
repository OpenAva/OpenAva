//
//  MemoryStateRepository.swift
//  MemoryKit
//
//  Persists session memory offsets with lightweight LRU cleanup.
//

import Foundation

public actor MemoryStateRepository {
    private struct PersistedState: Codable {
        var state: SessionMemoryState
        var updatedAt: TimeInterval
    }

    private let maxEntries: Int
    private let stateFile: URL
    private var cache: [String: PersistedState] = [:]
    private var loaded = false

    public init(runtimeRoot: URL, maxEntries: Int = 200) {
        self.maxEntries = max(1, maxEntries)
        let normalizedRuntimeRoot = runtimeRoot.standardizedFileURL
        // Persist session state under the caller-provided runtime root.
        try? FileManager.default.createDirectory(at: normalizedRuntimeRoot, withIntermediateDirectories: true)
        stateFile = normalizedRuntimeRoot.appendingPathComponent("session_memory_states.json")
    }

    public func loadState(for conversationID: String) -> SessionMemoryState {
        loadIfNeeded()
        guard var entry = cache[conversationID] else {
            return .init()
        }
        // Refresh access time so active sessions survive cleanup.
        entry.updatedAt = Date().timeIntervalSince1970
        cache[conversationID] = entry
        return entry.state
    }

    public func saveState(_ state: SessionMemoryState, for conversationID: String) {
        loadIfNeeded()
        cache[conversationID] = PersistedState(
            state: state,
            updatedAt: Date().timeIntervalSince1970
        )
        cleanupIfNeeded()
        persist()
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: stateFile) else { return }
        let decoder = JSONDecoder()
        if let decoded = try? decoder.decode([String: PersistedState].self, from: data) {
            cache = decoded
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: stateFile, options: .atomic)
    }

    private func cleanupIfNeeded() {
        guard cache.count > maxEntries else { return }
        let removeCount = cache.count - maxEntries
        let keysToRemove = cache
            .sorted { lhs, rhs in
                if lhs.value.updatedAt != rhs.value.updatedAt {
                    return lhs.value.updatedAt < rhs.value.updatedAt
                }
                if lhs.value.state.lastConsolidated != rhs.value.state.lastConsolidated {
                    return lhs.value.state.lastConsolidated < rhs.value.state.lastConsolidated
                }
                return lhs.key < rhs.key
            }
            .prefix(removeCount)
            .map(\.key)
        for key in keysToRemove {
            cache.removeValue(forKey: key)
        }
    }
}
