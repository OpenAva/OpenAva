//
//  ConversationSession+Memory.swift
//  LanguageModelChatUI
//
//  MemoryKit integration for hybrid session-level memory.
//

import Foundation
import MemoryKit

extension ConversationSession {
    public func archiveMemoryForNewConversation() async {
        await scheduleMemoryConsolidationIfNeeded(archiveAll: true)
        await waitForMemoryConsolidation(requiredMode: .archiveAll)
    }

    /// Schedules memory archiving without waiting for the LLM consolidation to finish.
    /// Records are captured immediately; the actual consolidation runs in the background.
    /// Use this when the conversation should switch right away.
    public func beginMemoryArchiveForNewConversation() async {
        await scheduleMemoryConsolidationIfNeeded(archiveAll: true)
    }

    func ensureMemoryStateLoaded() async {
        guard !memoryStateLoaded else { return }
        memoryStateLoaded = true
        if let loaded = await sessionDelegate?.loadSessionMemoryState(for: id) {
            memoryState = loaded
        }
    }

    func scheduleMemoryConsolidationIfNeeded(archiveAll: Bool = false) async {
        await ensureMemoryStateLoaded()
        guard let coordinator = await sessionDelegate?.memoryCoordinator(for: id) else {
            return
        }

        let requestedMode = MemoryConsolidationMode(archiveAll: archiveAll)
        pendingMemoryConsolidationMode = pendingMemoryConsolidationMode?
            .merged(with: requestedMode) ?? requestedMode

        await startNextMemoryConsolidationIfPossible(using: coordinator)
    }

    private func startNextMemoryConsolidationIfPossible(using coordinator: MemoryCoordinator) async {
        guard memoryConsolidationTask == nil else {
            return
        }
        guard let mode = pendingMemoryConsolidationMode else {
            return
        }

        pendingMemoryConsolidationMode = nil
        activeMemoryConsolidationMode = mode

        let records = buildMemoryRecords()
        var stateSnapshot = memoryState
        memoryConsolidationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let success = await coordinator.consolidateIfNeeded(
                records: records,
                state: &stateSnapshot,
                archiveAll: mode.shouldArchiveAll
            )

            if success {
                await self.sessionDelegate?.saveSessionMemoryState(stateSnapshot, for: self.id)
                self.memoryState = stateSnapshot
            }

            self.activeMemoryConsolidationMode = nil
            self.memoryConsolidationTask = nil
            await self.startNextMemoryConsolidationIfPossible(using: coordinator)
        }
    }

    private func waitForMemoryConsolidation(requiredMode: MemoryConsolidationMode) async {
        while hasPendingMemoryConsolidation(atLeast: requiredMode) {
            if let task = memoryConsolidationTask {
                await task.value
            } else {
                await Task.yield()
            }
        }
    }

    private func hasPendingMemoryConsolidation(atLeast requiredMode: MemoryConsolidationMode) -> Bool {
        let active = activeMemoryConsolidationMode?.rawValue ?? -1
        let pending = pendingMemoryConsolidationMode?.rawValue ?? -1
        return max(active, pending) >= requiredMode.rawValue
    }

    private func buildMemoryRecords() -> [MemoryRecord] {
        messages.compactMap { message in
            let role = message.role.rawValue
            guard role == "user" || role == "assistant" else {
                return nil
            }

            let text = message.textContent.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                return nil
            }

            let toolsUsed: [String] = message.parts.compactMap { part in
                guard case let .toolCall(toolCall) = part else { return nil }
                return toolCall.apiName.isEmpty ? toolCall.toolName : toolCall.apiName
            }

            return MemoryRecord(
                role: role,
                content: text,
                timestamp: message.createdAt,
                toolsUsed: toolsUsed
            )
        }
    }
}
