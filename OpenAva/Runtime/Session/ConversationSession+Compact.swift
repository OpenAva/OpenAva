import ChatClient
import ChatUI
import Foundation
import OSLog

private let compactLogger = Logger(subsystem: "ChatUI", category: "Compact")

// MARK: - Constants

private let compactMinimumSummaryMessageCount = 4
private let partialCompactMinimumSummaryMessageCount = 2
private let compactTranscriptPartLimit = 4000
private let compactPTLRetryLimit = 3
private let compactPTLRetryMarker = "[earlier conversation truncated for compaction retry]"
private let compactNoToolsPreamble = """
CRITICAL: Respond with TEXT ONLY. Do NOT call any tools.

- Do NOT use Read, Bash, Grep, Glob, Edit, Write, or ANY other tool.
- You already have all the context you need in the conversation above.
- Tool calls will be REJECTED and will waste your only turn — you will fail the task.
- Your entire response must be plain text: an <analysis> block followed by a <summary> block.
"""
private let compactDetailedAnalysisInstructionBase = """
Before providing your final summary, wrap your analysis in <analysis> tags to organize your thoughts and ensure you've covered all necessary points. In your analysis process:

1. Chronologically analyze each message and section of the conversation. For each section thoroughly identify:
   - The user's explicit requests and intents
   - Your approach to addressing the user's requests
   - Key decisions, technical concepts and code patterns
   - Specific details like:
     - file names
     - full code snippets
     - function signatures
     - file edits
   - Errors that you ran into and how you fixed them
   - Pay special attention to specific user feedback that you received, especially if the user told you to do something differently.
2. Double-check for technical accuracy and completeness, addressing each required element thoroughly.
"""
private let compactDetailedAnalysisInstructionPartial = """
Before providing your final summary, wrap your analysis in <analysis> tags to organize your thoughts and ensure you've covered all necessary points. In your analysis process:

1. Analyze the recent messages chronologically. For each section thoroughly identify:
   - The user's explicit requests and intents
   - Your approach to addressing the user's requests
   - Key decisions, technical concepts and code patterns
   - Specific details like:
     - file names
     - full code snippets
     - function signatures
     - file edits
   - Errors that you ran into and how you fixed them
   - Pay special attention to specific user feedback that you received, especially if the user told you to do something differently.
2. Double-check for technical accuracy and completeness, addressing each required element thoroughly.
"""
private let compactBasePrompt = """
Your task is to create a detailed summary of the conversation so far, paying close attention to the user's explicit requests and your previous actions.
This summary should be thorough in capturing technical details, code patterns, and architectural decisions that would be essential for continuing development work without losing context.

\(compactDetailedAnalysisInstructionBase)

Your summary should include the following sections:

1. Primary Request and Intent: Capture all of the user's explicit requests and intents in detail
2. Key Technical Concepts: List all important technical concepts, technologies, and frameworks discussed.
3. Files and Code Sections: Enumerate specific files and code sections examined, modified, or created. Pay special attention to the most recent messages and include full code snippets where applicable and include a summary of why this file read or edit is important.
4. Errors and fixes: List all errors that you ran into, and how you fixed them. Pay special attention to specific user feedback that you received, especially if the user told you to do something differently.
5. Problem Solving: Document problems solved and any ongoing troubleshooting efforts.
6. All user messages: List ALL user messages that are not tool results. These are critical for understanding the users' feedback and changing intent.
7. Pending Tasks: Outline any pending tasks that you have explicitly been asked to work on.
8. Current Work: Describe in detail precisely what was being worked on immediately before this summary request, paying special attention to the most recent messages from both user and assistant. Include file names and code snippets where applicable.
9. Optional Next Step: List the next step that you will take that is related to the most recent work you were doing. IMPORTANT: ensure that this step is DIRECTLY in line with the user's most recent explicit requests, and the task you were working on immediately before this summary request. If your last task was concluded, then only list next steps if they are explicitly in line with the users request. Do not start on tangential requests or really old requests that were already completed without confirming with the user first.
                       If there is a next step, include direct quotes from the most recent conversation showing exactly what task you were working on and where you left off. This should be verbatim to ensure there's no drift in task interpretation.

Here's an example of how your output should be structured:

<example>
<analysis>
[Your thought process, ensuring all points are covered thoroughly and accurately]
</analysis>

<summary>
1. Primary Request and Intent:
   [Detailed description]

2. Key Technical Concepts:
   - [Concept 1]
   - [Concept 2]
   - [...]

3. Files and Code Sections:
   - [File Name 1]
      - [Summary of why this file is important]
      - [Summary of the changes made to this file, if any]
      - [Important Code Snippet]
   - [File Name 2]
      - [Important Code Snippet]
   - [...]

4. Errors and fixes:
    - [Detailed description of error 1]:
      - [How you fixed the error]
      - [User feedback on the error if any]
    - [...]

5. Problem Solving:
   [Description of solved problems and ongoing troubleshooting]

6. All user messages:
    - [Detailed non tool use user message]
    - [...]

7. Pending Tasks:
   - [Task 1]
   - [Task 2]
   - [...]

8. Current Work:
   [Precise description of current work]

9. Optional Next Step:
   [Optional Next step to take]

</summary>
</example>

Please provide your summary based on the conversation so far, following this structure and ensuring precision and thoroughness in your response.

There may be additional summarization instructions provided in the included context. If so, remember to follow these instructions when creating the above summary. Examples of instructions include:
<example>
## Compact Instructions
When summarizing the conversation focus on typescript code changes and also remember the mistakes you made and how you fixed them.
</example>

<example>
# Summary instructions
When you are using compact - please focus on test output and code changes. Include file reads verbatim.
</example>
"""
private let partialCompactPrompt = """
Your task is to create a detailed summary of the RECENT portion of the conversation — the messages that follow earlier retained context. The earlier messages are being kept intact and do NOT need to be summarized. Focus your summary on what was discussed, learned, and accomplished in the recent messages only.

\(compactDetailedAnalysisInstructionPartial)

Your summary should include the following sections:

1. Primary Request and Intent: Capture the user's explicit requests and intents from the recent messages
2. Key Technical Concepts: List important technical concepts, technologies, and frameworks discussed recently.
3. Files and Code Sections: Enumerate specific files and code sections examined, modified, or created. Include full code snippets where applicable and include a summary of why this file read or edit is important.
4. Errors and fixes: List errors encountered and how they were fixed.
5. Problem Solving: Document problems solved and any ongoing troubleshooting efforts.
6. All user messages: List ALL user messages from the recent portion that are not tool results.
7. Pending Tasks: Outline any pending tasks from the recent messages.
8. Current Work: Describe precisely what was being worked on immediately before this summary request.
9. Optional Next Step: List the next step related to the most recent work. Include direct quotes from the most recent conversation.

Here's an example of how your output should be structured:

<example>
<analysis>
[Your thought process, ensuring all points are covered thoroughly and accurately]
</analysis>

<summary>
1. Primary Request and Intent:
   [Detailed description]

2. Key Technical Concepts:
   - [Concept 1]
   - [Concept 2]

3. Files and Code Sections:
   - [File Name 1]
      - [Summary of why this file is important]
      - [Important Code Snippet]

4. Errors and fixes:
    - [Error description]:
      - [How you fixed it]

5. Problem Solving:
   [Description]

6. All user messages:
    - [Detailed non tool use user message]

7. Pending Tasks:
   - [Task 1]

8. Current Work:
   [Precise description of current work]

9. Optional Next Step:
   [Optional Next step to take]

</summary>
</example>

Please provide your summary based on the RECENT messages only (after the retained earlier context), following this structure and ensuring precision and thoroughness in your response.
"""
private let partialCompactUpToPrompt = """
Your task is to create a detailed summary of this conversation. This summary will be placed at the start of a continuing session; newer messages that build on this context will follow after your summary (you do not see them here). Summarize thoroughly so that someone reading only your summary and then the newer messages can fully understand what happened and continue the work.

\(compactDetailedAnalysisInstructionBase)

Your summary should include the following sections:

1. Primary Request and Intent: Capture the user's explicit requests and intents in detail
2. Key Technical Concepts: List important technical concepts, technologies, and frameworks discussed.
3. Files and Code Sections: Enumerate specific files and code sections examined, modified, or created. Include full code snippets where applicable and include a summary of why this file read or edit is important.
4. Errors and fixes: List errors encountered and how they were fixed.
5. Problem Solving: Document problems solved and any ongoing troubleshooting efforts.
6. All user messages: List ALL user messages that are not tool results.
7. Pending Tasks: Outline any pending tasks.
8. Work Completed: Describe what was accomplished by the end of this portion.
9. Context for Continuing Work: Summarize any context, decisions, or state that would be needed to understand and continue the work in subsequent messages.

Here's an example of how your output should be structured:

<example>
<analysis>
[Your thought process, ensuring all points are covered thoroughly and accurately]
</analysis>

<summary>
1. Primary Request and Intent:
   [Detailed description]

2. Key Technical Concepts:
   - [Concept 1]
   - [Concept 2]

3. Files and Code Sections:
   - [File Name 1]
      - [Summary of why this file is important]
      - [Important Code Snippet]

4. Errors and fixes:
    - [Error description]:
      - [How you fixed it]

5. Problem Solving:
   [Description]

6. All user messages:
    - [Detailed non tool use user message]

7. Pending Tasks:
   - [Task 1]

8. Work Completed:
   [Description of what was accomplished]

9. Context for Continuing Work:
   [Key context, decisions, or state needed to continue the work]

</summary>
</example>

Please provide your summary following this structure, ensuring precision and thoroughness in your response.
"""
private let compactNoToolsTrailer = """

REMINDER: Do NOT call any tools. Respond with plain text only — an <analysis> block followed by a <summary> block. Tool calls will be rejected and you will fail the task.
"""

private enum CompactSummaryMode {
    case full
    case partial(direction: PartialCompactDirection)
}

struct RecompactionInfo {
    let isRecompactionInChain: Bool
    let turnsSincePreviousCompact: Int
    let previousCompactTurnId: String?
    let autoCompactThreshold: Int
    let querySource: QuerySource?
}

private struct CompactionPlan {
    let replacementRange: Range<Int>
    let messagesToSummarize: [ConversationMessage]
    let messagesToKeep: [ConversationMessage]
    let trigger: String
    let preTokens: Int
    let discoveredToolNames: [String]?
    let userContext: String?
    let summaryMode: CompactSummaryMode
    let suppressFollowUpQuestions: Bool
    let isAutoCompact: Bool
    let recompactionInfo: RecompactionInfo?
}

struct CompactionResult {
    let replacementRange: Range<Int>
    let boundaryMarker: ConversationMessage
    let summaryMessages: [ConversationMessage]
    let messagesToKeep: [ConversationMessage]
}

// MARK: - Extension

extension ConversationSession {
    /// Public API for manually triggering full-history compaction.
    public func compactConversation(model: ConversationSession.Model) async throws {
        let requestMessages = await buildMessages(capabilities: model.capabilities)
        let tools = await enabledRequestTools(for: model.capabilities)
        let preTokens = await estimateTokenCount(messages: requestMessages, tools: tools)
        let result = try await compactConversation(
            model: model,
            trigger: "manual",
            preTokens: preTokens
        )
        applyCompactionResult(result)
        resetAutoCompactTracking()
    }

    /// Public API for compacting around a selected message, keeping either the
    /// prefix or suffix verbatim.
    public func partialCompactConversation(
        around messageID: String,
        direction: PartialCompactDirection = .from,
        feedback: String? = nil,
        model: ConversationSession.Model
    ) async throws {
        let requestMessages = await buildMessages(capabilities: model.capabilities)
        let tools = await enabledRequestTools(for: model.capabilities)
        let preTokens = await estimateTokenCount(messages: requestMessages, tools: tools)
        let plan = try partialCompactionPlan(
            around: messageID,
            direction: direction,
            userContext: feedback,
            trigger: "manual",
            preTokens: preTokens
        )
        let result = try await performCompaction(using: plan, model: model)
        applyCompactionResult(result)
        resetAutoCompactTracking()
    }

    // MARK: - Core

    func compactConversation(
        model: ConversationSession.Model,
        trigger: String,
        preTokens: Int,
        suppressFollowUpQuestions: Bool = false,
        isAutoCompact: Bool = false,
        recompactionInfo: RecompactionInfo? = nil
    ) async throws -> CompactionResult {
        let plan = try fullCompactionPlan(
            trigger: trigger,
            preTokens: preTokens,
            suppressFollowUpQuestions: suppressFollowUpQuestions,
            isAutoCompact: isAutoCompact,
            recompactionInfo: recompactionInfo
        )
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
        suppressFollowUpQuestions: Bool,
        isAutoCompact: Bool,
        recompactionInfo: RecompactionInfo?
    ) throws -> CompactionPlan {
        let state = currentCompactionState()
        let candidates = state.candidates
        guard candidates.count >= compactMinimumSummaryMessageCount else {
            compactLogger.info("Too few compaction candidates (\(candidates.count)); skipping")
            throw CompactionError.tooFewMessages
        }

        return CompactionPlan(
            replacementRange: state.replacementStart ..< messages.count,
            messagesToSummarize: candidates,
            messagesToKeep: [],
            trigger: trigger,
            preTokens: preTokens,
            discoveredToolNames: extractDiscoveredToolNames(from: candidates),
            userContext: nil,
            summaryMode: .full,
            suppressFollowUpQuestions: suppressFollowUpQuestions,
            isAutoCompact: isAutoCompact,
            recompactionInfo: recompactionInfo
        )
    }

    private func partialCompactionPlan(
        around messageID: String,
        direction: PartialCompactDirection,
        userContext: String?,
        trigger: String,
        preTokens: Int,
        suppressFollowUpQuestions: Bool = false,
        isAutoCompact: Bool = false,
        recompactionInfo: RecompactionInfo? = nil
    ) throws -> CompactionPlan {
        let state = currentCompactionState()
        let candidates = state.candidates
        guard let pivotIndex = candidates.firstIndex(where: { $0.id == messageID }) else {
            throw CompactionError.messageNotFound
        }

        let messagesToSummarize: [ConversationMessage]
        let messagesToKeep: [ConversationMessage]

        switch direction {
        case .from:
            messagesToSummarize = Array(candidates[pivotIndex...])
            messagesToKeep = Array(candidates[..<pivotIndex])
        case .upTo:
            messagesToSummarize = Array(candidates[..<pivotIndex])
            messagesToKeep = Array(candidates[pivotIndex...]).filter { !$0.isCompactSummary }
        }

        guard messagesToSummarize.count >= partialCompactMinimumSummaryMessageCount else {
            throw CompactionError.tooFewMessages
        }

        return CompactionPlan(
            replacementRange: state.replacementStart ..< messages.count,
            messagesToSummarize: messagesToSummarize,
            messagesToKeep: messagesToKeep,
            trigger: trigger,
            preTokens: preTokens,
            discoveredToolNames: extractDiscoveredToolNames(from: candidates),
            userContext: userContext,
            summaryMode: .partial(direction: direction),
            suppressFollowUpQuestions: suppressFollowUpQuestions,
            isAutoCompact: isAutoCompact,
            recompactionInfo: recompactionInfo
        )
    }

    private func generateCompactionSummary(
        for sourceMessages: [ConversationMessage],
        mode: CompactSummaryMode,
        model: ConversationSession.Model,
        customInstructions: String?,
        recentMessagesPreserved _: Bool
    ) async throws -> String {
        var messagesToSummarize = sanitizeMessagesForCompaction(sourceMessages)
        guard !messagesToSummarize.isEmpty else {
            throw CompactionError.tooFewMessages
        }

        let systemPrompt: String
        switch mode {
        case .full:
            systemPrompt = getCompactPrompt(
                customInstructions: customInstructions
            )
        case let .partial(direction):
            systemPrompt = getPartialCompactPrompt(
                customInstructions: customInstructions,
                direction: direction
            )
        }

        var ptlAttempts = 0
        var prependPTLRetryMarker = false

        while true {
            let transcript = buildCompactionTranscript(
                from: messagesToSummarize,
                prependPTLRetryMarker: prependPTLRetryMarker
            )
            guard !transcript.isEmpty else {
                throw CompactionError.emptySummary
            }

            let summaryRequestBody = ChatRequestBody(
                messages: [
                    .system(content: .text(systemPrompt)),
                    .user(content: .text(buildCompactPromptBody(from: transcript))),
                ],
                maxCompletionTokens: getReservedTokensForSummary(for: model),
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
                guard isPromptTooLongError(error) else {
                    throw error
                }

                ptlAttempts += 1
                guard ptlAttempts <= compactPTLRetryLimit,
                      let truncatedMessages = truncateHeadForPTLRetry(
                          messagesToSummarize,
                          error: error
                      )
                else {
                    throw CompactionError.promptTooLong
                }

                compactLogger.warning(
                    "Compact prompt-too-long retry \(ptlAttempts, privacy: .public); dropped \(messagesToSummarize.count - truncatedMessages.count, privacy: .public) messages."
                )
                messagesToSummarize = truncatedMessages
                prependPTLRetryMarker = true
            }
        }
    }

    private func buildCompactionResult(
        from plan: CompactionPlan,
        summaryText: String
    ) -> CompactionResult {
        let boundaryMessage = storageProvider.createMessage(in: id, role: .system)
        boundaryMessage.textContent = "Conversation compacted."
        boundaryMessage.subtype = "compact_boundary"

        let summaryMessage = storageProvider.createMessage(in: id, role: .user)
        summaryMessage.textContent = getCompactUserSummaryMessage(
            summaryText,
            suppressFollowUpQuestions: plan.suppressFollowUpQuestions,
            recentMessagesPreserved: !plan.messagesToKeep.isEmpty
        )
        summaryMessage.metadata["isCompactSummary"] = "true"

        applyPostCompactTimestamps(
            boundary: boundaryMessage,
            summary: summaryMessage,
            keptMessages: plan.messagesToKeep
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
            messagesToKeep: plan.messagesToKeep
        )
    }

    private func compactBoundaryMetadata(
        for plan: CompactionPlan,
        boundaryMessage: ConversationMessage,
        summaryMessage: ConversationMessage
    ) -> CompactBoundaryMetadata {
        let baseMetadata = CompactBoundaryMetadata(
            trigger: plan.trigger,
            preTokens: plan.preTokens,
            userContext: plan.userContext,
            messagesSummarized: plan.messagesToSummarize.count,
            preCompactDiscoveredTools: plan.discoveredToolNames,
            autoCompactThreshold: plan.recompactionInfo?.autoCompactThreshold,
            querySource: plan.recompactionInfo?.querySource?.rawValue,
            isRecompactionInChain: plan.recompactionInfo?.isRecompactionInChain,
            turnsSincePreviousCompact: plan.recompactionInfo?.turnsSincePreviousCompact,
            previousCompactTurnId: plan.recompactionInfo?.previousCompactTurnId
        )

        let anchorId: String = switch plan.summaryMode {
        case .partial(.from):
            boundaryMessage.id
        case .full, .partial(.upTo):
            summaryMessage.id
        }

        return annotateBoundaryWithPreservedSegment(
            baseMetadata,
            anchorId: anchorId,
            messagesToKeep: plan.messagesToKeep
        )
    }

    private func annotateBoundaryWithPreservedSegment(
        _ metadata: CompactBoundaryMetadata,
        anchorId: String,
        messagesToKeep: [ConversationMessage]
    ) -> CompactBoundaryMetadata {
        guard let firstKept = messagesToKeep.first,
              let lastKept = messagesToKeep.last
        else {
            return metadata
        }

        return CompactBoundaryMetadata(
            trigger: metadata.trigger,
            preTokens: metadata.preTokens,
            userContext: metadata.userContext,
            messagesSummarized: metadata.messagesSummarized,
            preCompactDiscoveredTools: metadata.preCompactDiscoveredTools,
            autoCompactThreshold: metadata.autoCompactThreshold,
            querySource: metadata.querySource,
            isRecompactionInChain: metadata.isRecompactionInChain,
            turnsSincePreviousCompact: metadata.turnsSincePreviousCompact,
            previousCompactTurnId: metadata.previousCompactTurnId,
            preservedSegment: .init(
                headUuid: firstKept.id,
                anchorUuid: anchorId,
                tailUuid: lastKept.id
            )
        )
    }

    func buildPostCompactMessages(_ result: CompactionResult) -> [ConversationMessage] {
        [result.boundaryMarker] + result.summaryMessages + result.messagesToKeep
    }

    func applyCompactionResult(_ result: CompactionResult) {
        let postCompactMessages = buildPostCompactMessages(result)
        messages.replaceSubrange(result.replacementRange, with: postCompactMessages)
        persistMessages()
        runPostCompactCleanup()
        notifyMessagesDidChange(scrolling: false)
    }

    private func runPostCompactCleanup() {
        setLoadingState(nil)
    }

    private func currentCompactionState() -> (replacementStart: Int, candidates: [ConversationMessage]) {
        guard !messages.isEmpty else {
            return (0, [])
        }
        let boundaryIndex = messages.findLastCompactBoundaryIndex()
        let replacementStart = boundaryIndex ?? 0
        let candidates = messages.getMessagesAfterCompactBoundary(includingBoundary: false)
        return (replacementStart, candidates)
    }

    private func extractDiscoveredToolNames(from messages: [ConversationMessage]) -> [String]? {
        let names = Set(messages.flatMap { message in
            message.parts.compactMap { part -> String? in
                guard case let .toolCall(toolCall) = part else { return nil }
                let name = toolCall.apiName.isEmpty ? toolCall.toolName : toolCall.apiName
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
        })
        guard !names.isEmpty else {
            return nil
        }
        return names.sorted()
    }

    private func sanitizeMessagesForCompaction(_ input: [ConversationMessage]) -> [ConversationMessage] {
        input.filter { !$0.isCompactBoundary }
    }

    private func buildCompactionTranscript(
        from messages: [ConversationMessage],
        prependPTLRetryMarker: Bool = false
    ) -> String {
        var transcriptSections: [String] = []
        if prependPTLRetryMarker {
            transcriptSections.append("[USER]\n\(compactPTLRetryMarker)")
        }

        transcriptSections.append(contentsOf: messages.compactMap { message -> String? in
            let body = compactTranscriptBody(for: message)
            guard !body.isEmpty else { return nil }
            return "[\(message.role.rawValue.uppercased())]\n\(body)"
        })

        return transcriptSections.joined(separator: "\n\n")
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

    private func truncateHeadForPTLRetry(
        _ messages: [ConversationMessage],
        error: Error
    ) -> [ConversationMessage]? {
        let groups = groupMessagesByCompactionRound(messages)
        guard groups.count >= 2 else { return nil }

        let tokenGap = getPromptTooLongTokenGap(from: error)
        let dropCount: Int
        if let tokenGap {
            var accumulatedTokens = 0
            var countedGroups = 0
            for group in groups {
                accumulatedTokens += roughCompactionTokenCount(for: group)
                countedGroups += 1
                if accumulatedTokens >= tokenGap {
                    break
                }
            }
            dropCount = countedGroups
        } else {
            dropCount = max(1, Int((Double(groups.count) * 0.2).rounded(.down)))
        }

        let boundedDropCount = min(dropCount, groups.count - 1)
        guard boundedDropCount > 0 else { return nil }
        return Array(groups.dropFirst(boundedDropCount).flatMap { $0 })
    }

    private func roughCompactionTokenCount(for message: ConversationMessage) -> Int {
        let body = compactTranscriptBody(for: message)
        guard !body.isEmpty else { return 1 }
        return max(1, (body.count + 3) / 4)
    }

    private func roughCompactionTokenCount(for messages: [ConversationMessage]) -> Int {
        max(messages.reduce(0) { $0 + roughCompactionTokenCount(for: $1) }, 1)
    }

    private func groupMessagesByCompactionRound(_ messages: [ConversationMessage]) -> [[ConversationMessage]] {
        var groups: [[ConversationMessage]] = []
        var currentGroup: [ConversationMessage] = []

        for message in messages {
            if message.role == .assistant, !currentGroup.isEmpty {
                groups.append(currentGroup)
                currentGroup = [message]
            } else if message.role == .tool {
                currentGroup.append(message)
            } else {
                currentGroup.append(message)
            }
        }

        if !currentGroup.isEmpty {
            groups.append(currentGroup)
        }
        return groups
    }

    private func getCompactPrompt(
        customInstructions: String?
    ) -> String {
        var prompt = compactNoToolsPreamble + compactBasePrompt
        if let customInstructions,
           !customInstructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            prompt += "\n\nAdditional Instructions:\n\(customInstructions)"
        }
        prompt += compactNoToolsTrailer
        return prompt
    }

    private func getPartialCompactPrompt(
        customInstructions: String?,
        direction: PartialCompactDirection
    ) -> String {
        let template = direction == .upTo ? partialCompactUpToPrompt : partialCompactPrompt
        var prompt = compactNoToolsPreamble + template
        if let customInstructions,
           !customInstructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            prompt += "\n\nAdditional Instructions:\n\(customInstructions)"
        }
        prompt += compactNoToolsTrailer
        return prompt
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
        var formattedSummary = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !formattedSummary.isEmpty else { return "" }

        // Strip analysis section — it's only drafting scratchpad.
        formattedSummary = formattedSummary.replacingOccurrences(
            of: #"<analysis>[\s\S]*?</analysis>"#,
            with: "",
            options: .regularExpression
        )

        if let extracted = extractTaggedBlock(named: "summary", from: formattedSummary),
           let summaryRange = formattedSummary.range(
               of: #"<summary>[\s\S]*?</summary>"#,
               options: [.regularExpression, .caseInsensitive]
           )
        {
            let content = extracted.trimmingCharacters(in: .whitespacesAndNewlines)
            formattedSummary.replaceSubrange(summaryRange, with: "Summary:\n\(content)")
        }

        formattedSummary = formattedSummary.replacingOccurrences(
            of: #"\n\n+"#,
            with: "\n\n",
            options: .regularExpression
        )

        return formattedSummary.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func extractTaggedBlock(named tag: String, from text: String) -> String? {
        guard let start = text.range(of: "<\(tag)>", options: .caseInsensitive),
              let end = text.range(of: "</\(tag)>", options: .caseInsensitive)
        else {
            return nil
        }
        return String(text[start.upperBound ..< end.lowerBound])
    }

    private func getCompactUserSummaryMessage(
        _ summary: String,
        suppressFollowUpQuestions: Bool = false,
        recentMessagesPreserved: Bool
    ) -> String {
        let formattedSummary = formatCompactSummary(summary)
        var result = "This session is being continued from a previous conversation that ran out of context. The summary below covers the earlier portion of the conversation.\n\n\(formattedSummary)"
        if recentMessagesPreserved {
            result += "\n\nRecent messages are preserved verbatim."
        }
        if suppressFollowUpQuestions {
            result += "\n\nContinue the conversation from where it left off without asking the user any further questions. Resume directly — do not acknowledge the summary, do not recap what was happening, and do not preface with \"I’ll continue\" or similar. Pick up the last task as if the break never happened."
        }
        return result
    }

    private func applyPostCompactTimestamps(
        boundary: ConversationMessage,
        summary: ConversationMessage,
        keptMessages: [ConversationMessage]
    ) {
        let firstKeptDate = keptMessages.first?.createdAt ?? Date()
        boundary.createdAt = firstKeptDate.addingTimeInterval(-0.003)
        summary.createdAt = firstKeptDate.addingTimeInterval(-0.002)
    }
}

// MARK: - Error

private enum CompactionError: LocalizedError {
    case emptySummary
    case tooFewMessages
    case messageNotFound
    case promptTooLong

    var errorDescription: String? {
        switch self {
        case .emptySummary:
            "Compaction produced an empty summary."
        case .tooFewMessages:
            "Not enough messages to compact."
        case .messageNotFound:
            "The selected message is no longer available for compaction."
        case .promptTooLong:
            "Conversation too long to compact. Try compacting a smaller range."
        }
    }
}
