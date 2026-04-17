import ChatClient
import ChatUI
import Foundation
import OSLog

private let compactLogger = Logger(subsystem: "ChatUI", category: "Compact")

// MARK: - Constants

private let compactThresholdRatio: Double = 0.80
private let compactKeepRecentMessageCount = 4
private let compactMinimumSummaryMessageCount = 4
private let partialCompactMinimumSummaryMessageCount = 2
private let compactMaxPTLRetries = 3
private let compactRetryDropRatio = 0.20
private let compactTranscriptPartLimit = 4000

private enum CompactSummaryMode {
    case full
    case partial(direction: PartialCompactDirection)
}

private enum CompactionKeptPlacement {
    case beforeSummary
    case afterSummary
}

private struct CompactionPlan {
    let replacementRange: Range<Int>
    let messagesToSummarize: [ConversationMessage]
    let messagesToKeep: [ConversationMessage]
    let keptPlacement: CompactionKeptPlacement
    let trigger: String
    let preTokens: Int
    let discoveredToolNames: [String]?
    let userContext: String?
    let summaryMode: CompactSummaryMode
}

private struct CompactionResult {
    let replacementRange: Range<Int>
    let boundaryMarker: ConversationMessage
    let summaryMessages: [ConversationMessage]
    let messagesToKeep: [ConversationMessage]
    let attachments: [ConversationMessage]
    let hookResults: [ConversationMessage]
    let keptPlacement: CompactionKeptPlacement
    let preCompactTokenCount: Int?
    let postCompactTokenCount: Int?
}

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
            let result = try await performBestAvailableCompaction(
                model: model,
                trigger: "auto",
                preTokens: estimated,
                tools: tools
            )
            applyCompactionResult(result)
            requestMessages = buildRequestMessages(capabilities: capabilities)
            await injectSystemPrompt(&requestMessages, capabilities: capabilities)
            compactLogger.info("Compaction complete, rebuilt request messages")
            return true
        } catch {
            compactLogger.error("Compaction failed: \(error.localizedDescription); falling back to trim")
            return false
        }
    }

    /// Public API for manually triggering full-history compaction.
    public func compact(model: ConversationSession.Model) async throws {
        let requestMessages = buildRequestMessages(capabilities: model.capabilities)
        let tools = await compactEnabledTools(for: model)
        let preTokens = await estimateTokenCount(messages: requestMessages, tools: tools)
        let result = try await performBestAvailableCompaction(
            model: model,
            trigger: "manual",
            preTokens: preTokens,
            tools: tools
        )
        applyCompactionResult(result)
    }

    /// Public API for compacting around a selected message, keeping either the
    /// prefix or suffix verbatim.
    public func partialCompact(
        around messageID: String,
        direction: PartialCompactDirection = .from,
        feedback: String? = nil,
        model: ConversationSession.Model
    ) async throws {
        let requestMessages = buildRequestMessages(capabilities: model.capabilities)
        let tools = await compactEnabledTools(for: model)
        let preTokens = await estimateTokenCount(messages: requestMessages, tools: tools)
        let plan = try partialCompactionPlan(
            around: messageID,
            direction: direction,
            userContext: feedback,
            trigger: "manual",
            preTokens: preTokens,
            tools: tools
        )
        let result = try await performCompaction(using: plan, model: model)
        applyCompactionResult(result)
    }

    // MARK: - Core

    private func performBestAvailableCompaction(
        model: ConversationSession.Model,
        trigger: String,
        preTokens: Int,
        tools: [ChatRequestBody.Tool]?
    ) async throws -> CompactionResult {
        let plan = try fullCompactionPlan(trigger: trigger, preTokens: preTokens, tools: tools)
        return try await performCompaction(using: plan, model: model)
    }

    private func performCompaction(
        using plan: CompactionPlan,
        model: ConversationSession.Model
    ) async throws -> CompactionResult {
        let summaryText = try await generateCompactionSummary(
            for: plan.messagesToSummarize,
            mode: plan.summaryMode,
            model: model,
            customInstructions: plan.userContext,
            recentMessagesPreserved: !plan.messagesToKeep.isEmpty
        )
        return buildCompactionResult(from: plan, summaryText: summaryText)
    }

    private func fullCompactionPlan(
        trigger: String,
        preTokens: Int,
        tools: [ChatRequestBody.Tool]?
    ) throws -> CompactionPlan {
        let state = currentCompactionState()
        let candidates = state.candidates
        let keepCount = min(compactKeepRecentMessageCount, candidates.count)
        let keepIndex = candidates.count - keepCount
        guard keepIndex >= compactMinimumSummaryMessageCount else {
            compactLogger.info("Too few compaction candidates (\(candidates.count)); skipping")
            throw CompactionError.tooFewMessages
        }

        return CompactionPlan(
            replacementRange: state.replacementStart ..< messages.count,
            messagesToSummarize: Array(candidates[..<keepIndex]),
            messagesToKeep: Array(candidates[keepIndex...]),
            keptPlacement: .afterSummary,
            trigger: trigger,
            preTokens: preTokens,
            discoveredToolNames: compactDiscoveredToolNames(from: tools),
            userContext: nil,
            summaryMode: .full
        )
    }

    private func partialCompactionPlan(
        around messageID: String,
        direction: PartialCompactDirection,
        userContext: String?,
        trigger: String,
        preTokens: Int,
        tools: [ChatRequestBody.Tool]?
    ) throws -> CompactionPlan {
        let state = currentCompactionState()
        let candidates = state.candidates
        guard let pivotIndex = candidates.firstIndex(where: { $0.id == messageID }) else {
            throw CompactionError.messageNotFound
        }

        let messagesToSummarize: [ConversationMessage]
        let messagesToKeep: [ConversationMessage]
        let keptPlacement: CompactionKeptPlacement

        switch direction {
        case .from:
            messagesToSummarize = Array(candidates[pivotIndex...])
            messagesToKeep = Array(candidates[..<pivotIndex])
            keptPlacement = .beforeSummary
        case .upTo:
            messagesToSummarize = Array(candidates[..<pivotIndex])
            messagesToKeep = Array(candidates[pivotIndex...])
            keptPlacement = .afterSummary
        }

        guard messagesToSummarize.count >= partialCompactMinimumSummaryMessageCount else {
            throw CompactionError.tooFewMessages
        }

        return CompactionPlan(
            replacementRange: state.replacementStart ..< messages.count,
            messagesToSummarize: messagesToSummarize,
            messagesToKeep: messagesToKeep,
            keptPlacement: keptPlacement,
            trigger: trigger,
            preTokens: preTokens,
            discoveredToolNames: compactDiscoveredToolNames(from: tools),
            userContext: userContext,
            summaryMode: .partial(direction: direction)
        )
    }

    private func generateCompactionSummary(
        for sourceMessages: [ConversationMessage],
        mode: CompactSummaryMode,
        model: ConversationSession.Model,
        customInstructions: String?,
        recentMessagesPreserved: Bool
    ) async throws -> String {
        var messagesToSummarize = sanitizeMessagesForCompaction(sourceMessages)
        guard !messagesToSummarize.isEmpty else {
            throw CompactionError.tooFewMessages
        }

        let systemPrompt = buildCompactPrompt(
            mode: mode,
            customInstructions: customInstructions,
            recentMessagesPreserved: recentMessagesPreserved
        )

        var attempts = 0
        while true {
            let transcript = buildCompactionTranscript(from: messagesToSummarize)
            guard !transcript.isEmpty else {
                throw CompactionError.emptySummary
            }

            let summaryRequestBody = ChatRequestBody(
                messages: [
                    .system(content: .text(systemPrompt)),
                    .user(content: .text(buildCompactPromptBody(from: transcript))),
                ],
                stream: false,
                tools: nil
            )

            do {
                let response = try await model.client.chat(body: summaryRequestBody)
                let summaryText = formatCompactSummary(response.text)
                guard !summaryText.isEmpty else {
                    throw CompactionError.emptySummary
                }
                return summaryText
            } catch {
                let combinedError = [error.localizedDescription, model.client.collectedErrors]
                    .compactMap { $0 }
                    .joined(separator: "\n")
                let canRetry = attempts < compactMaxPTLRetries && isPromptTooLongError(combinedError)
                if canRetry, let truncated = truncateMessagesForPTLRetry(messagesToSummarize) {
                    attempts += 1
                    compactLogger.warning(
                        "Compaction prompt exceeded context; retrying with fewer messages attempt=\(attempts) remaining=\(truncated.count)"
                    )
                    messagesToSummarize = truncated
                    continue
                }
                throw error
            }
        }
    }

    private func buildCompactionResult(
        from plan: CompactionPlan,
        summaryText: String
    ) -> CompactionResult {
        let boundaryMessage = storageProvider.createMessage(in: id, role: .system)
        boundaryMessage.textContent = "\(ConversationMarkers.compactBoundaryPrefix)\n\nConversation compacted."
        boundaryMessage.subtype = "compact_boundary"

        let summaryMessage = storageProvider.createMessage(in: id, role: .user)
        summaryMessage.textContent = buildContextSummaryMessageText(
            summaryText,
            mode: plan.summaryMode,
            recentMessagesPreserved: !plan.messagesToKeep.isEmpty
        )
        summaryMessage.metadata["isCompactionSummary"] = "true"

        let attachments = buildPostCompactAttachments(
            discoveredToolNames: plan.discoveredToolNames,
            keptPlacement: plan.keptPlacement,
            keptCount: plan.messagesToKeep.count,
            mode: plan.summaryMode
        )

        applyPostCompactOrdering(
            boundary: boundaryMessage,
            summary: summaryMessage,
            keptMessages: plan.messagesToKeep,
            attachments: attachments,
            placement: plan.keptPlacement
        )

        boundaryMessage.compactBoundaryMetadata = compactBoundaryMetadata(
            for: plan,
            boundaryMessage: boundaryMessage,
            summaryMessage: summaryMessage
        )

        return CompactionResult(
            replacementRange: plan.replacementRange,
            boundaryMarker: boundaryMessage,
            summaryMessages: [summaryMessage],
            messagesToKeep: plan.messagesToKeep,
            attachments: attachments,
            hookResults: [],
            keptPlacement: plan.keptPlacement,
            preCompactTokenCount: plan.preTokens,
            postCompactTokenCount: nil
        )
    }

    private func compactBoundaryMetadata(
        for plan: CompactionPlan,
        boundaryMessage: ConversationMessage,
        summaryMessage: ConversationMessage
    ) -> CompactBoundaryMetadata {
        let preservedSegment: CompactBoundaryMetadata.PreservedSegment?
        if let firstKept = plan.messagesToKeep.first,
           let lastKept = plan.messagesToKeep.last
        {
            let anchorUUID: String
            switch plan.keptPlacement {
            case .afterSummary:
                anchorUUID = summaryMessage.id
            case .beforeSummary:
                anchorUUID = boundaryMessage.id
            }
            preservedSegment = .init(
                headUUID: firstKept.id,
                anchorUUID: anchorUUID,
                tailUUID: lastKept.id
            )
        } else {
            preservedSegment = nil
        }

        return CompactBoundaryMetadata(
            trigger: plan.trigger,
            preTokens: plan.preTokens,
            userContext: plan.userContext,
            messagesSummarized: plan.messagesToSummarize.count,
            preCompactDiscoveredTools: plan.discoveredToolNames,
            preservedSegment: preservedSegment
        )
    }

    private func buildPostCompactMessages(_ result: CompactionResult) -> [ConversationMessage] {
        var built: [ConversationMessage] = [result.boundaryMarker]
        switch result.keptPlacement {
        case .afterSummary:
            built.append(contentsOf: result.summaryMessages)
            built.append(contentsOf: result.messagesToKeep)
        case .beforeSummary:
            built.append(contentsOf: result.messagesToKeep)
            built.append(contentsOf: result.summaryMessages)
        }
        built.append(contentsOf: result.attachments)
        built.append(contentsOf: result.hookResults)
        return built
    }

    private func applyCompactionResult(_ result: CompactionResult) {
        let postCompactMessages = buildPostCompactMessages(result)
        messages.replaceSubrange(result.replacementRange, with: postCompactMessages)
        persistMessages()
        notifyMessagesDidChange(scrolling: false)
    }

    private func compactEnabledTools(for model: ConversationSession.Model) async -> [ChatRequestBody.Tool]? {
        guard model.capabilities.contains(.tool), let toolProvider else { return nil }
        let enabledTools = await toolProvider.enabledTools()
        return enabledTools.isEmpty ? nil : enabledTools
    }

    private func currentCompactionState() -> (replacementStart: Int, candidates: [ConversationMessage]) {
        guard !messages.isEmpty else {
            return (0, [])
        }
        let boundaryIndex = messages.lastIndex(where: { $0.isCompactBoundary })
        let replacementStart = boundaryIndex ?? 0
        let candidateStart = boundaryIndex.map { $0 + 1 } ?? 0
        let sourceMessages = candidateStart < messages.count ? Array(messages[candidateStart...]) : []
        let candidates = sourceMessages.filter {
            !$0.isCompactBoundary && !$0.isCompactAttachment
        }
        return (replacementStart, candidates)
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
        return names.isEmpty ? nil : names.sorted()
    }

    private func sanitizeMessagesForCompaction(_ input: [ConversationMessage]) -> [ConversationMessage] {
        input.filter { !$0.isCompactAttachment && !$0.isCompactBoundary }
    }

    private func buildCompactionTranscript(from messages: [ConversationMessage]) -> String {
        messages.compactMap { message -> String? in
            let body = compactTranscriptBody(for: message)
            guard !body.isEmpty else { return nil }
            return "[\(message.role.rawValue.uppercased())]\n\(body)"
        }.joined(separator: "\n\n")
    }

    private func compactTranscriptBody(for message: ConversationMessage) -> String {
        var sections: [String] = []
        for part in message.parts {
            switch part {
            case let .text(textPart):
                let text = textPart.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    sections.append(truncateCompactionText(text))
                }
            case let .image(imagePart):
                sections.append("[Image attachment: \(imagePart.name ?? imagePart.mediaType)]")
            case let .audio(audioPart):
                if let transcription = audioPart.transcription?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !transcription.isEmpty
                {
                    sections.append("[Audio transcription]\n\(truncateCompactionText(transcription))")
                } else {
                    sections.append("[Audio attachment: \(audioPart.name ?? audioPart.mediaType)]")
                }
            case let .file(filePart):
                if let textContent = filePart.textContent?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !textContent.isEmpty
                {
                    sections.append("[File: \(filePart.name ?? "unnamed")]\n\(truncateCompactionText(textContent))")
                } else {
                    sections.append("[File attachment: \(filePart.name ?? filePart.mediaType)]")
                }
            case .reasoning:
                continue
            case let .toolCall(toolCall):
                let toolName = toolCall.apiName.isEmpty ? toolCall.toolName : toolCall.apiName
                let parameters = toolCall.parameters.trimmingCharacters(in: .whitespacesAndNewlines)
                sections.append("[Tool Call: \(toolName)]\nParameters: \(truncateCompactionText(parameters))")
            case let .toolResult(toolResult):
                sections.append("[Tool Result: \(toolResult.toolCallID)]\n\(truncateCompactionText(toolResult.result))")
            }
        }
        return sections.joined(separator: "\n\n")
    }

    private func truncateCompactionText(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > compactTranscriptPartLimit else { return trimmed }
        let endIndex = trimmed.index(trimmed.startIndex, offsetBy: compactTranscriptPartLimit)
        return String(trimmed[..<endIndex]) + "\n[truncated for compaction]"
    }

    private func buildCompactPrompt(
        mode: CompactSummaryMode,
        customInstructions: String?,
        recentMessagesPreserved: Bool
    ) -> String {
        let sharedPreamble = """
        CRITICAL: Respond with TEXT ONLY. Do NOT call any tools.

        - Do NOT use any tools, functions, or external calls.
        - Tool use is disabled for this compaction request.
        - Your response must contain an <analysis> block followed by a <summary> block.
        - The <analysis> block is scratch space and will be discarded.
        - The <summary> block must be precise, implementation-focused, and suitable for continuing the work.
        """

        let instructions: String
        switch mode {
        case .full:
            instructions = """
            Your task is to create a detailed summary of the earlier portion of a conversation so the session can continue after compaction.

            Include:
            1. Primary request and intent
            2. Key technical concepts
            3. Files, code paths, and implementation details
            4. Errors and fixes
            5. Decisions made and rationale
            6. Current status and pending work
            7. Important user feedback
            8. Next logical steps
            """
        case let .partial(direction):
            switch direction {
            case .from:
                instructions = """
                Your task is to summarize the later portion of the conversation that is being compacted away. Earlier preserved messages will remain verbatim before your summary.

                Focus on what happened in the compacted suffix only, especially implementation work, results, and unresolved follow-ups.
                """
            case .upTo:
                instructions = """
                Your task is to summarize the earlier portion of the conversation that will be replaced by this summary. Newer preserved messages will remain verbatim after your summary.

                Focus on the earlier compacted prefix and provide enough context so later preserved turns still make sense.
                """
            }
        }

        let preservedNote = recentMessagesPreserved
            ? "Recent messages are preserved verbatim outside this summary. Prefer preserved turns when they are more specific than the summary."
            : "No recent messages are preserved outside this summary."

        let customBlock = {
            let trimmed = customInstructions?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !trimmed.isEmpty else { return "" }
            return "\n\nAdditional compaction instructions:\n\(trimmed)"
        }()

        return [sharedPreamble, instructions, preservedNote + customBlock].joined(separator: "\n\n")
    }

    private func buildCompactPromptBody(from transcript: String) -> String {
        """
        Create a compaction summary for the conversation content below.

        <conversation>
        \(transcript)
        </conversation>
        """
    }

    private func formatCompactSummary(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        if let extracted = extractTaggedBlock(named: "summary", from: trimmed) {
            return extracted.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var cleaned = trimmed
        if let analysisRange = cleaned.range(of: #"<analysis>[\s\S]*?</analysis>"#, options: .regularExpression) {
            cleaned.removeSubrange(analysisRange)
        }
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func extractTaggedBlock(named tag: String, from text: String) -> String? {
        guard let start = text.range(of: "<\(tag)>", options: .caseInsensitive),
              let end = text.range(of: "</\(tag)>", options: .caseInsensitive)
        else {
            return nil
        }
        return String(text[start.upperBound ..< end.lowerBound])
    }

    private func buildContextSummaryMessageText(
        _ summary: String,
        mode: CompactSummaryMode,
        recentMessagesPreserved: Bool
    ) -> String {
        let prefix: String
        switch mode {
        case .full:
            prefix = "This session is being continued from a previous conversation that ran out of context. The summary below covers the earlier portion of the conversation."
        case let .partial(direction):
            switch direction {
            case .from:
                prefix = "This summary replaces a later portion of the conversation that was compacted to save context. Earlier preserved messages remain verbatim above."
            case .upTo:
                prefix = "This summary replaces an earlier portion of the conversation that was compacted to save context. Newer preserved messages remain verbatim after this summary."
            }
        }

        var result = "\(ConversationMarkers.contextSummaryPrefix)\n\n\(prefix)\n\n\(summary)"
        if recentMessagesPreserved {
            result += "\n\nRecent messages are preserved verbatim."
        }
        return result
    }

    private func buildPostCompactAttachments(
        discoveredToolNames: [String]?,
        keptPlacement: CompactionKeptPlacement,
        keptCount: Int,
        mode: CompactSummaryMode
    ) -> [ConversationMessage] {
        var attachments: [ConversationMessage] = []

        let modeScopeDescription: String
        switch mode {
        case .full:
            modeScopeDescription = "the earlier conversation"
        case .partial(direction: .from):
            modeScopeDescription = "a later compacted suffix"
        case .partial(direction: .upTo):
            modeScopeDescription = "an earlier compacted prefix"
        }

        let continuationAttachment = storageProvider.createMessage(in: id, role: .system)
        continuationAttachment.subtype = "compact_attachment"
        continuationAttachment.metadata["isCompactAttachment"] = "true"
        continuationAttachment.textContent = "\(ConversationMarkers.compactAttachmentPrefix)\n\nCompaction guidance: the summary replaces \(modeScopeDescription). Prefer verbatim preserved turns over compressed summary details when they disagree."
        attachments.append(continuationAttachment)

        if keptCount > 0 {
            let preservedAttachment = storageProvider.createMessage(in: id, role: .system)
            preservedAttachment.subtype = "compact_attachment"
            preservedAttachment.metadata["isCompactAttachment"] = "true"
            let preservedLabel: String
            switch keptPlacement {
            case .afterSummary:
                preservedLabel = "after"
            case .beforeSummary:
                preservedLabel = "before"
            }
            preservedAttachment.textContent = "\(ConversationMarkers.compactAttachmentPrefix)\n\nPreserved verbatim messages: \(keptCount). Their original order and details remain \(preservedLabel) the summary."
            attachments.append(preservedAttachment)
        }

        if let discoveredToolNames, !discoveredToolNames.isEmpty {
            let toolAttachment = storageProvider.createMessage(in: id, role: .system)
            toolAttachment.subtype = "compact_attachment"
            toolAttachment.metadata["isCompactAttachment"] = "true"
            let toolList = discoveredToolNames.map { "- \($0)" }.joined(separator: "\n")
            toolAttachment.textContent = "\(ConversationMarkers.compactAttachmentPrefix)\n\nEnabled tools at compaction time:\n\(toolList)"
            attachments.append(toolAttachment)
        }

        return attachments
    }

    private func applyPostCompactOrdering(
        boundary: ConversationMessage,
        summary: ConversationMessage,
        keptMessages: [ConversationMessage],
        attachments: [ConversationMessage],
        placement: CompactionKeptPlacement
    ) {
        switch placement {
        case .afterSummary:
            let firstKeptDate = keptMessages.first?.createdAt ?? Date()
            let lastKeptDate = keptMessages.last?.createdAt ?? firstKeptDate
            boundary.createdAt = firstKeptDate.addingTimeInterval(-0.003)
            summary.createdAt = firstKeptDate.addingTimeInterval(-0.002)
            for (index, attachment) in attachments.enumerated() {
                attachment.createdAt = lastKeptDate.addingTimeInterval(Double(index + 1) * 0.0001)
            }
        case .beforeSummary:
            let referenceDate = keptMessages.first?.createdAt ?? Date()
            boundary.createdAt = referenceDate.addingTimeInterval(-0.001)
            let summaryReference = (keptMessages.last?.createdAt ?? referenceDate).addingTimeInterval(0.001)
            summary.createdAt = summaryReference
            for (index, attachment) in attachments.enumerated() {
                attachment.createdAt = summaryReference.addingTimeInterval(Double(index + 1) * 0.0001)
            }
        }
    }

    private func isPromptTooLongError(_ text: String) -> Bool {
        let lowercased = text.lowercased()
        return lowercased.contains("prompt too long") ||
            lowercased.contains("context length") ||
            lowercased.contains("maximum context") ||
            lowercased.contains("max context") ||
            lowercased.contains("too many tokens") ||
            lowercased.contains("reduce the length")
    }

    private func truncateMessagesForPTLRetry(_ messages: [ConversationMessage]) -> [ConversationMessage]? {
        guard messages.count > compactMinimumSummaryMessageCount else { return nil }
        let dropCount = max(1, Int(ceil(Double(messages.count) * compactRetryDropRatio)))
        let remaining = Array(messages.dropFirst(dropCount))
        return remaining.count >= partialCompactMinimumSummaryMessageCount ? remaining : nil
    }
}

// MARK: - Error

private enum CompactionError: LocalizedError {
    case emptySummary
    case tooFewMessages
    case messageNotFound

    var errorDescription: String? {
        switch self {
        case .emptySummary:
            "Compaction produced an empty summary."
        case .tooFewMessages:
            "Not enough messages to compact."
        case .messageNotFound:
            "The selected message is no longer available for compaction."
        }
    }
}
