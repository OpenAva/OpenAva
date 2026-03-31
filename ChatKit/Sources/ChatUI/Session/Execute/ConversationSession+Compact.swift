//
//  ConversationSession+Compact.swift
//  LanguageModelChatUI
//
//  LLM-based context compaction — summarises old messages before the context
//  window fills up, preserving conversation continuity without silent truncation.
//

import ChatClient
import Foundation
import OSLog

private let compactLogger = Logger(subsystem: "LanguageModelChatUI", category: "Compact")

// MARK: - Constants

private let compactThresholdRatio: Double = 0.80
private let compactKeepRecentMessageCount = 4

private let compactPrompt = """
Your task is to create a detailed summary of a conversation. \
This summary will replace the full conversation history to keep the context window manageable.

Please analyze the conversation and create a comprehensive summary that includes:

1. **Primary Request and Intent**: What was the user's main goal or request?
2. **Key Technical Concepts**: Important technical details, frameworks, patterns, or architecture decisions discussed.
3. **Files and Code**: Specific files examined or modified, code patterns used, and important implementation details.
4. **Errors and Solutions**: Problems encountered and how they were resolved.
5. **Decisions Made**: Any choices made between alternatives and the reasons behind them.
6. **Current Status**: What has been completed and what is still in progress.
7. **Open Questions**: Any unresolved issues or questions still pending.
8. **Next Steps**: Planned or suggested actions that should happen after this summary.
9. **Important Context**: Any other context that would be essential for continuing the conversation without the full history.

Write the summary in clear, detailed prose. Be thorough — this summary is the only context \
that will be available going forward.
"""

// MARK: - Extension

extension ConversationSession {
    /// Called from the execute flow. Compacts old messages when token usage exceeds the threshold.
    /// Rebuilds `requestMessages` and re-injects the system prompt after compaction.
    func compactIfNeeded(
        requestMessages: inout [ChatRequestBody.Message],
        tools: [ChatRequestBody.Tool]?,
        model: ConversationSession.Model,
        capabilities: Set<ModelCapability>
    ) async {
        let contextLength = model.contextLength
        guard contextLength > 0 else { return }

        let estimated = await estimateTokenCount(messages: requestMessages, tools: tools)
        let threshold = Int(Double(contextLength) * compactThresholdRatio)
        guard estimated >= threshold else { return }

        compactLogger.info("Token usage \(estimated)/\(contextLength) exceeds threshold \(threshold), starting compaction")

        do {
            try await performCompaction(model: model)
            // Rebuild request messages from the now-compacted history.
            requestMessages = buildRequestMessages(capabilities: capabilities)
            await injectSystemPrompt(&requestMessages, capabilities: capabilities)
            compactLogger.info("Compaction complete, rebuilt request messages")
        } catch {
            compactLogger.error("Compaction failed: \(error.localizedDescription); falling back to trim")
        }
    }

    /// Public API for manually triggering compaction (e.g. from a debug action or future UI button).
    public func compact(model: ConversationSession.Model) async throws {
        try await performCompaction(model: model)
    }

    // MARK: - Core

    private func performCompaction(model: ConversationSession.Model) async throws {
        // Keep the most recent messages verbatim for continuity.
        let keepCount = min(compactKeepRecentMessageCount, messages.count)
        let keepIndex = messages.count - keepCount
        guard keepIndex >= 4 else {
            compactLogger.info("Too few messages to compact (\(self.messages.count)); skipping")
            return
        }

        let messagesToCompact = Array(messages[0 ..< keepIndex])
        let keptMessages = Array(messages[keepIndex...])

        // Build a plain-text transcript for the LLM to summarise.
        let conversationText = messagesToCompact.map { msg in
            let role = msg.role.rawValue.uppercased()
            let text = msg.textContent
            return "[\(role)]: \(text)"
        }.joined(separator: "\n\n")

        let summaryRequestBody = ChatRequestBody(
            messages: [
                .system(content: .text(compactPrompt)),
                .user(content: .text("Please summarise the following conversation:\n\n\(conversationText)")),
            ],
            stream: false
        )

        let response = try await model.client.chat(body: summaryRequestBody)
        let summaryText = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summaryText.isEmpty else {
            throw CompactionError.emptySummary
        }

        // Determine creation timestamp: just before the oldest kept message so it sorts first.
        let anchorDate: Date
        if let first = keptMessages.first {
            anchorDate = first.createdAt.addingTimeInterval(-1)
        } else {
            anchorDate = Date(timeIntervalSince1970: 0)
        }

        // Persist the summary as a system message.
        let summaryMessage = storageProvider.createMessage(in: id, role: .system)
        summaryMessage.textContent = "[Context Summary]\n\n\(summaryText)"
        summaryMessage.createdAt = anchorDate
        summaryMessage.metadata["isCompactionSummary"] = "true"
        storageProvider.save([summaryMessage])

        // Delete compacted messages from storage.
        let idsToDelete = messagesToCompact.map(\.id)
        storageProvider.delete(idsToDelete)

        // Update in-memory message array.
        messages.removeAll { idsToDelete.contains($0.id) }

        // Insert summary at the start of the array (before kept messages).
        if let insertIndex = messages.firstIndex(where: { keptMessages.first?.id == $0.id }) {
            messages.insert(summaryMessage, at: insertIndex)
        } else {
            messages.insert(summaryMessage, at: 0)
        }

        notifyMessagesDidChange(scrolling: false)
    }
}

// MARK: - Error

private enum CompactionError: LocalizedError {
    case emptySummary

    var errorDescription: String? {
        switch self {
        case .emptySummary:
            "Compaction produced an empty summary."
        }
    }
}
