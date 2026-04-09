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
    @discardableResult
    func compactIfNeeded(
        requestMessages: inout [ChatRequestBody.Message],
        tools: [ChatRequestBody.Tool]?,
        model: ConversationSession.Model,
        capabilities: Set<ModelCapability>
    ) async -> Bool {
        let contextLength = model.contextLength
        guard contextLength > 0 else { return false }

        let estimated = await estimateTokenCount(messages: requestMessages, tools: tools)
        let threshold = Int(Double(contextLength) * compactThresholdRatio)
        guard estimated >= threshold else { return false }

        compactLogger.info("Token usage \(estimated)/\(contextLength) exceeds threshold \(threshold), starting compaction")

        do {
            try await performBestAvailableCompaction(
                model: model,
                trigger: "auto",
                preTokens: estimated,
                tools: tools
            )
            // Rebuild request messages from the now-compacted history.
            requestMessages = buildRequestMessages(capabilities: capabilities)
            await injectSystemPrompt(&requestMessages, capabilities: capabilities)
            compactLogger.info("Compaction complete, rebuilt request messages")
            return true
        } catch {
            compactLogger.error("Compaction failed: \(error.localizedDescription); falling back to trim")
            return false
        }
    }

    /// Public API for manually triggering compaction (e.g. from a debug action or future UI button).
    public func compact(model: ConversationSession.Model) async throws {
        let requestMessages = buildRequestMessages(capabilities: model.capabilities)
        var tools: [ChatRequestBody.Tool]?
        if model.capabilities.contains(.tool), let toolProvider {
            await toolProvider.prepareForConversation()
            let enabledTools = await toolProvider.enabledTools()
            if !enabledTools.isEmpty {
                tools = enabledTools
            }
        }
        let preTokens = await estimateTokenCount(messages: requestMessages, tools: tools)
        try await performBestAvailableCompaction(model: model, trigger: "manual", preTokens: preTokens, tools: tools)
    }

    // MARK: - Core

    private func performBestAvailableCompaction(
        model: ConversationSession.Model,
        trigger: String,
        preTokens: Int,
        tools: [ChatRequestBody.Tool]?
    ) async throws {
        let summaryText = try await generateCompactionSummary(model: model)
        try applyCompaction(summaryText: summaryText, trigger: trigger, preTokens: preTokens, tools: tools)
    }

    private func generateCompactionSummary(model: ConversationSession.Model) async throws -> String {
        // Keep the most recent messages verbatim for continuity.
        let keepCount = min(compactKeepRecentMessageCount, messages.count)
        let keepIndex = messages.count - keepCount
        guard keepIndex >= 4 else {
            compactLogger.info("Too few messages to compact (\(self.messages.count)); skipping")
            throw CompactionError.tooFewMessages
        }

        let messagesToCompact = Array(messages[0 ..< keepIndex])

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
        return summaryText
    }

    private func applyCompaction(
        summaryText: String,
        trigger: String,
        preTokens: Int,
        tools: [ChatRequestBody.Tool]?
    ) throws {
        let keepCount = min(compactKeepRecentMessageCount, messages.count)
        let keepIndex = messages.count - keepCount
        guard keepIndex >= 4 else {
            compactLogger.info("Too few messages to compact (\(self.messages.count)); skipping")
            throw CompactionError.tooFewMessages
        }

        let messagesToCompact = Array(messages[0 ..< keepIndex])
        let keptMessages = Array(messages[keepIndex...])

        // Determine creation timestamp: just before the oldest kept message so it sorts first.
        let anchorDate: Date
        if let first = keptMessages.first {
            anchorDate = first.createdAt.addingTimeInterval(-1)
        } else {
            anchorDate = Date(timeIntervalSince1970: 0)
        }

        let boundaryMessage = storageProvider.createMessage(in: id, role: .system)
        boundaryMessage.textContent = "\(ConversationMarkers.compactBoundaryPrefix)\n\nConversation compacted."
        boundaryMessage.createdAt = anchorDate
        boundaryMessage.subtype = "compact_boundary"

        let discoveredToolNames = compactDiscoveredToolNames(from: tools)

        let summaryMessage = storageProvider.createMessage(in: id, role: .user)
        summaryMessage.textContent = "\(ConversationMarkers.contextSummaryPrefix)\n\n\(summaryText)"
        summaryMessage.createdAt = anchorDate.addingTimeInterval(0.001)
        summaryMessage.metadata["isCompactionSummary"] = "true"

        if let firstKept = keptMessages.first,
           let lastKept = keptMessages.last
        {
            boundaryMessage.compactBoundaryMetadata = CompactBoundaryMetadata(
                trigger: trigger,
                preTokens: preTokens,
                userContext: nil,
                messagesSummarized: messagesToCompact.count,
                preCompactDiscoveredTools: discoveredToolNames,
                preservedSegment: .init(
                    headUUID: firstKept.id,
                    anchorUUID: summaryMessage.id,
                    tailUUID: lastKept.id
                )
            )
        } else {
            boundaryMessage.compactBoundaryMetadata = CompactBoundaryMetadata(
                trigger: trigger,
                preTokens: preTokens,
                userContext: nil,
                messagesSummarized: messagesToCompact.count,
                preCompactDiscoveredTools: discoveredToolNames
            )
        }

        // Update in-memory message array.
        let idsToDelete = messagesToCompact.map(\.id)
        messages.removeAll { idsToDelete.contains($0.id) }

        // Insert boundary + summary before kept messages to match post-compact ordering.
        if let insertIndex = messages.firstIndex(where: { keptMessages.first?.id == $0.id }) {
            messages.insert(boundaryMessage, at: insertIndex)
            messages.insert(summaryMessage, at: insertIndex + 1)
        } else {
            messages.insert(boundaryMessage, at: 0)
            messages.insert(summaryMessage, at: 1)
        }

        notifyMessagesDidChange(scrolling: false)
    }

    private func compactDiscoveredToolNames(from tools: [ChatRequestBody.Tool]?) -> [String]? {
        guard let tools else { return nil }
        let names = tools.compactMap { tool -> String? in
            switch tool {
            case let .function(name, _, _, _):
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
        }
        return names.isEmpty ? nil : names
    }
}

// MARK: - Error

private enum CompactionError: LocalizedError {
    case emptySummary
    case tooFewMessages

    var errorDescription: String? {
        switch self {
        case .emptySummary:
            "Compaction produced an empty summary."
        case .tooFewMessages:
            "Not enough messages to compact."
        }
    }
}
