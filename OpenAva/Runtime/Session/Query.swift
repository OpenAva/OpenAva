import ChatClient
import ChatUI
import Foundation
import OSLog

private let logger = Logger(subsystem: "com.day1-labs.openava", category: "chat.stop.query")

private enum QueryTurnOutput {
    case finished(finishReason: FinishReason)
    case requiresToolCalls(assistantMessage: ConversationMessage, pendingToolCalls: [ToolRequest])
}

private struct QueryState {
    var totalTurns = 0
    var totalToolCalls = 0
    var hasAttemptedReactiveCompact = false
}

private struct QueryAutoCompactState {
    var tracking: AutoCompactTrackingState?
}

@MainActor
private func applyAutoCompactResult(
    _ autoCompactResult: AutoCompactResult,
    session: ConversationSession,
    model: ConversationSession.Model,
    requestMessages: inout [ChatRequestBody.Message],
    autoCompactState: inout QueryAutoCompactState,
    resetTrackingOnSuccess: Bool = false
) async {
    if let compactionResult = autoCompactResult.compactionResult {
        session.applyCompactionResult(compactionResult)
        if resetTrackingOnSuccess {
            autoCompactState.tracking = nil
            session.autoCompactTrackingState = AutoCompactTrackingState()
        } else {
            autoCompactState.tracking = AutoCompactTrackingState(
                compacted: true,
                turnCounter: 0,
                turnId: UUID().uuidString,
                consecutiveFailures: 0
            )
            session.autoCompactTrackingState = autoCompactState.tracking ?? AutoCompactTrackingState()
        }
        requestMessages = await session.buildMessages(capabilities: model.capabilities)
    } else if let consecutiveFailures = autoCompactResult.consecutiveFailures {
        var tracking = autoCompactState.tracking ?? AutoCompactTrackingState()
        tracking.consecutiveFailures = consecutiveFailures
        autoCompactState.tracking = tracking
        session.autoCompactTrackingState = tracking
    }
}

private struct QueryTurnSnapshot {
    let text: String?
    let reasoning: String?
    let pendingToolCalls: [ToolRequest]

    init(message: ConversationMessage, pendingToolCalls: [ToolRequest]) {
        let trimmedText = message.textContent.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedReasoning = message.reasoningContent?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        text = trimmedText.isEmpty ? nil : trimmedText
        reasoning = (trimmedReasoning?.isEmpty == false) ? trimmedReasoning : nil
        self.pendingToolCalls = pendingToolCalls
    }

    var hasText: Bool {
        text != nil
    }

    var hasReasoning: Bool {
        reasoning != nil
    }

    var hasToolCalls: Bool {
        !pendingToolCalls.isEmpty
    }

    var isEmpty: Bool {
        !hasText && !hasReasoning && !hasToolCalls
    }

    var finishReason: FinishReason {
        hasToolCalls ? .toolCalls : .stop
    }

    var assistantRequestMessage: ChatRequestBody.Message {
        .assistant(
            content: text.map { .text($0) },
            toolCalls: pendingToolCalls.map {
                .init(id: $0.id, function: .init(name: $0.name, arguments: $0.arguments))
            },
            reasoning: reasoning
        )
    }
}

private func normalizedToolCallName(_ name: String) -> String {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "tool" : trimmed
}

private func deniedToolCallText(for decision: ToolPermissionDecision) -> String {
    let customMessage = decision.message?.trimmingCharacters(in: .whitespacesAndNewlines)
    switch decision.behavior {
    case .allow, .deny:
        return (customMessage?.isEmpty == false) ? customMessage! : String.localized("Tool execution was denied.")
    case .ask:
        return (customMessage?.isEmpty == false) ? customMessage! : String.localized("Tool execution requires approval.")
    }
}

@MainActor
func query(
    session: ConversationSession,
    model: ConversationSession.Model,
    requestMessages: inout [ChatRequestBody.Message],
    tools: [ChatRequestBody.Tool]?,
    toolUseContext: ToolExecutionContext,
    maxTurns: Int,
    querySource: QuerySource
) async throws -> QueryResult {
    logger.notice(
        "query entered session=\(session.id, privacy: .public) maxTurns=\(maxTurns) toolsEnabled=\(String(tools != nil), privacy: .public)"
    )
    var state = QueryState()
    var autoCompactState = QueryAutoCompactState()
    while state.totalTurns < maxTurns {
        let turnNumber = state.totalTurns + 1
        logger.debug(
            "query loop tick session=\(session.id, privacy: .public) turn=\(turnNumber) cancelled=\(String(Task.isCancelled), privacy: .public)"
        )
        try Task.checkCancellation()

        try await advanceQueryState(
            session: session,
            model: model,
            &requestMessages,
            tools: tools,
            autoCompactState: &autoCompactState,
            querySource: querySource
        )
        state.totalTurns += 1

        let turn: QueryTurnOutput
        do {
            turn = try await executeQueryTurn(
                session: session,
                model: model,
                requestMessages: &requestMessages,
                tools: tools
            )
        } catch {
            let recovered = await recoverFromPromptTooLongIfPossible(
                error: error,
                session: session,
                model: model,
                requestMessages: &requestMessages,
                tools: tools,
                state: &state,
                autoCompactState: &autoCompactState,
                querySource: querySource
            )
            if recovered {
                continue
            }
            throw error
        }

        switch turn {
        case let .finished(finishReason):
            markAutoCompactTurnCompletedIfNeeded(&autoCompactState, session: session)
            logger.notice(
                "query loop completed without tools session=\(session.id, privacy: .public) finishReason=\(String(describing: finishReason), privacy: .public)"
            )
            return finalizeQueryResult(
                finishReason: finishReason,
                session: session,
                state: state
            )

        case let .requiresToolCalls(assistantMessage, pendingToolCalls):
            state.totalToolCalls += pendingToolCalls.count
            logger.notice(
                "query loop executing tools session=\(session.id, privacy: .public) count=\(pendingToolCalls.count) totalToolCalls=\(state.totalToolCalls)"
            )
            try await executeToolCalls(
                pendingToolCalls,
                assistantMessage: assistantMessage,
                requestMessages: &requestMessages,
                toolUseContext: toolUseContext
            )
            markAutoCompactTurnCompletedIfNeeded(&autoCompactState, session: session)
        }
    }

    return finalizeMaxTurnsResult(session: session, state: state)
}

@MainActor
private func advanceQueryState(
    session: ConversationSession,
    model: ConversationSession.Model,
    _ requestMessages: inout [ChatRequestBody.Message],
    tools: [ChatRequestBody.Tool]?,
    autoCompactState: inout QueryAutoCompactState,
    querySource: QuerySource
) async throws {
    let autoCompactResult = await session.autoCompactIfNeeded(
        &requestMessages,
        tools: tools,
        model: model,
        tracking: autoCompactState.tracking,
        querySource: querySource
    )

    await applyAutoCompactResult(
        autoCompactResult,
        session: session,
        model: model,
        requestMessages: &requestMessages,
        autoCompactState: &autoCompactState
    )

    session.setLoadingState(String.localized("Calculating context window..."))
    try await session.ensureBelowBlockingLimit(
        requestMessages: requestMessages,
        tools: tools,
        model: model
    )
    session.notifyMessagesDidChange(scrolling: true)
}

@MainActor
private func finalizeMaxTurnsResult(
    session: ConversationSession,
    state: QueryState
) -> QueryResult {
    let message = session.appendNewMessage(role: .assistant) { msg in
        msg.textContent = String.localized("Reached maximum number of turns.")
        msg.finishReason = .length
    }
    session.recordMessageInTranscript(message)
    session.notifyMessagesDidChange(scrolling: true)
    return finalizeQueryResult(
        finishReason: .length,
        session: session,
        state: state
    )
}

@MainActor
private func finalizeQueryResult(
    finishReason: FinishReason,
    session: ConversationSession,
    state: QueryState
) -> QueryResult {
    let result = QueryResult(
        finishReason: finishReason,
        totalTurns: state.totalTurns,
        totalToolCalls: state.totalToolCalls
    )
    logger.notice(
        "query exited session=\(session.id, privacy: .public) finishReason=\(String(describing: result.finishReason), privacy: .public) totalTurns=\(result.totalTurns) totalToolCalls=\(result.totalToolCalls)"
    )
    return result
}

@MainActor
private func recoverFromPromptTooLongIfPossible(
    error: Error,
    session: ConversationSession,
    model: ConversationSession.Model,
    requestMessages: inout [ChatRequestBody.Message],
    tools: [ChatRequestBody.Tool]?,
    state: inout QueryState,
    autoCompactState: inout QueryAutoCompactState,
    querySource: QuerySource
) async -> Bool {
    guard isPromptTooLongError(error) else {
        return false
    }
    guard !state.hasAttemptedReactiveCompact else {
        return false
    }

    logger.warning(
        "query turn hit prompt-too-long session=\(session.id, privacy: .public); attempting reactive compact"
    )

    let autoCompactResult = await session.reactiveCompactIfNeeded(
        &requestMessages,
        tools: tools,
        model: model,
        querySource: querySource
    )

    await applyAutoCompactResult(
        autoCompactResult,
        session: session,
        model: model,
        requestMessages: &requestMessages,
        autoCompactState: &autoCompactState,
        resetTrackingOnSuccess: true
    )

    guard autoCompactResult.wasCompacted else {
        return false
    }

    state.hasAttemptedReactiveCompact = true
    state.totalTurns = max(0, state.totalTurns - 1)
    return true
}

@MainActor
private func markAutoCompactTurnCompletedIfNeeded(
    _ autoCompactState: inout QueryAutoCompactState,
    session: ConversationSession
) {
    guard var tracking = autoCompactState.tracking, tracking.compacted else { return }
    tracking.turnCounter += 1
    autoCompactState.tracking = tracking
    session.autoCompactTrackingState = tracking
}

@MainActor
private func collapseReasoningIfNeeded(
    for message: ConversationMessage,
    enabled: Bool
) {
    guard enabled else { return }
    for (index, part) in message.parts.enumerated() {
        if case var .reasoning(reasoningPart) = part {
            reasoningPart.isCollapsed = true
            message.parts[index] = .reasoning(reasoningPart)
            break
        }
    }
}

@MainActor
private func updateStreamingVisibility(
    for message: ConversationMessage,
    session: ConversationSession,
    collapseReasoningWhenComplete: Bool
) {
    if !message.textContent.isEmpty {
        session.stopThinking(for: message.id)
        collapseReasoningIfNeeded(for: message, enabled: collapseReasoningWhenComplete)
    } else if let reasoning = message.reasoningContent, !reasoning.isEmpty {
        session.startThinking(for: message.id)
    }
}

private func updateTextEmitterRate(
    _ textEmitter: BalancedEmitter,
    streamedCharacterCount: Int
) {
    if streamedCharacterCount >= 5000 {
        textEmitter.update(duration: 1.0, frequency: 3)
    } else if streamedCharacterCount >= 2000 {
        textEmitter.update(duration: 1.0, frequency: 9)
    } else if streamedCharacterCount >= 1000 {
        textEmitter.update(duration: 0.5, frequency: 15)
    }
}

@MainActor
private func ensureRunningToolCallPart(
    for request: ToolRequest,
    in assistantMessage: ConversationMessage,
    session: ConversationSession
) -> Int {
    let displayToolName = normalizedToolCallName(request.name)
    if let existingPartIndex = assistantMessage.parts.firstIndex(where: { part in
        guard case let .toolCall(toolCallPart) = part else { return false }
        return toolCallPart.id == request.id
    }) {
        updateToolCallPart(
            at: existingPartIndex,
            in: assistantMessage,
            toolName: displayToolName,
            state: .running
        )
        return existingPartIndex
    }

    assistantMessage.parts.append(
        .toolCall(
            ToolCallContentPart(
                id: request.id,
                toolName: displayToolName,
                apiName: request.name,
                parameters: request.arguments,
                state: .running
            )
        )
    )
    session.recordMessageInTranscript(assistantMessage)
    return assistantMessage.parts.count - 1
}

@MainActor
private func updateToolCallPart(
    at index: Int,
    in assistantMessage: ConversationMessage,
    toolName: String? = nil,
    state: ToolCallState
) {
    guard index < assistantMessage.parts.count,
          case var .toolCall(part) = assistantMessage.parts[index]
    else { return }
    if let toolName { part.toolName = toolName }
    part.state = state
    assistantMessage.parts[index] = .toolCall(part)
}

@MainActor
private func appendToolResult(
    for request: ToolRequest,
    text: String,
    assistantMessage: ConversationMessage,
    requestMessages: inout [ChatRequestBody.Message]
) {
    assistantMessage.parts.append(
        .toolResult(
            .init(toolCallID: request.id, result: text, isCollapsed: true)
        )
    )
    requestMessages.append(
        .tool(
            content: .text(text),
            toolCallID: request.id
        )
    )
}

@MainActor
private func appendInterruptedToolResults(
    _ interruptedToolCalls: [(request: ToolRequest, toolCallPartIndex: Int)],
    to assistantMessage: ConversationMessage,
    requestMessages: inout [ChatRequestBody.Message],
    toolUseContext: ToolExecutionContext
) {
    let interruptionText = toolUseContext.interruptionText()
    for entry in interruptedToolCalls {
        updateToolCallPart(
            at: entry.toolCallPartIndex,
            in: assistantMessage,
            state: .failed
        )

        let alreadyHasResult = assistantMessage.parts.contains { part in
            guard case let .toolResult(result) = part else { return false }
            return result.toolCallID == entry.request.id
        }
        guard !alreadyHasResult else { continue }

        appendToolResult(
            for: entry.request,
            text: interruptionText,
            assistantMessage: assistantMessage,
            requestMessages: &requestMessages
        )
    }
}

private func shouldDiscardEmptyFollowUpAfterToolResult(
    requestMessages: [ChatRequestBody.Message],
    snapshot: QueryTurnSnapshot
) -> Bool {
    guard snapshot.isEmpty else { return false }
    return requestMessages.last.map {
        if case .tool = $0 { true } else { false }
    } == true
}

@MainActor
private func finalizeTurnPresentation(
    for message: ConversationMessage,
    session: ConversationSession,
    collapseReasoningWhenComplete: Bool
) {
    session.stopThinking(for: message.id)
    collapseReasoningIfNeeded(for: message, enabled: collapseReasoningWhenComplete)
}

private func makeNoResponseError(from client: any ChatClient) -> Error {
    if let collectedError = client.collectedErrors?
        .trimmingCharacters(in: .whitespacesAndNewlines), !collectedError.isEmpty
    {
        return NSError(
            domain: "ChatClient",
            code: 0,
            userInfo: [NSLocalizedDescriptionKey: collectedError]
        )
    }
    return QueryExecutionError.noResponseFromModel
}

@MainActor
private func discardTransientAssistantMessageIfNeeded(
    _ message: ConversationMessage,
    from session: ConversationSession
) {
    let hasReasoning = message.reasoningContent?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .isEmpty == false
    let hasText = !message.textContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    let hasParts = !message.parts.isEmpty
    guard !hasReasoning, !hasText, !hasParts else {
        return
    }
    session.messages.removeAll { $0.id == message.id }
    session.notifyMessagesDidChange(scrolling: true)
}

@MainActor
private func discardEmptyFollowUpMessage(
    _ message: ConversationMessage,
    from session: ConversationSession
) -> QueryTurnOutput {
    session.messages.removeAll { $0.id == message.id }
    session.notifyMessagesDidChange(scrolling: true)
    return .finished(finishReason: .stop)
}

@MainActor
private func commitQueryTurn(
    _ snapshot: QueryTurnSnapshot,
    message: ConversationMessage,
    requestMessages: inout [ChatRequestBody.Message],
    session: ConversationSession
) -> QueryTurnOutput {
    requestMessages.append(snapshot.assistantRequestMessage)

    let finishReason = snapshot.finishReason
    message.finishReason = finishReason
    session.recordMessageInTranscript(message)
    session.notifyMessagesDidChange(scrolling: true)

    if snapshot.pendingToolCalls.isEmpty {
        return .finished(finishReason: finishReason)
    }

    return .requiresToolCalls(
        assistantMessage: message,
        pendingToolCalls: snapshot.pendingToolCalls
    )
}

@MainActor
private func finalizeQueryTurn(
    session: ConversationSession,
    client: any ChatClient,
    message: ConversationMessage,
    requestMessages: inout [ChatRequestBody.Message],
    pendingToolCalls: [ToolRequest],
    collapseReasoningWhenComplete: Bool
) throws -> QueryTurnOutput {
    finalizeTurnPresentation(
        for: message,
        session: session,
        collapseReasoningWhenComplete: collapseReasoningWhenComplete
    )
    let snapshot = QueryTurnSnapshot(message: message, pendingToolCalls: pendingToolCalls)

    if shouldDiscardEmptyFollowUpAfterToolResult(
        requestMessages: requestMessages,
        snapshot: snapshot
    ) {
        return discardEmptyFollowUpMessage(message, from: session)
    }

    if snapshot.isEmpty {
        message.finishReason = .error
        throw makeNoResponseError(from: client)
    }

    return commitQueryTurn(
        snapshot,
        message: message,
        requestMessages: &requestMessages,
        session: session
    )
}

@MainActor
private func executeQueryTurn(
    session: ConversationSession,
    model: ConversationSession.Model,
    requestMessages: inout [ChatRequestBody.Message],
    tools: [ChatRequestBody.Tool]?
) async throws -> QueryTurnOutput {
    try Task.checkCancellation()
    logger.debug("execute query turn session=\(session.id, privacy: .public) starting")
    session.setLoadingState(nil)

    let message = session.appendNewMessage(role: .assistant)
    session.notifyMessagesDidChange(scrolling: true)

    let collapseAfterReasoningComplete = session.collapseReasoningWhenComplete
    let client = model.client
    do {
        await client.setCollectedErrors(nil)
        let stream = try await client.streamingChat(
            body: .init(
                messages: requestMessages,
                maxCompletionTokens: model.maxOutputTokens,
                stream: true,
                tools: tools
            )
        )
        defer { session.stopThinking(for: message.id) }

        // Persistence strategy:
        // - Keep the UI streaming in-memory.
        // - Persist only structural changes (e.g. tool call parts) and the final message.
        // This avoids appending many full-snapshot updates for the same message UUID.

        let reasoningEmitter = BalancedEmitter(duration: 1.0, frequency: 30) { chunk in
            let current = message.reasoningContent ?? ""
            message.reasoningContent = current + chunk
            updateStreamingVisibility(
                for: message,
                session: session,
                collapseReasoningWhenComplete: collapseAfterReasoningComplete
            )
            session.notifyMessagesDidChange(scrolling: true)
        }
        let textEmitter = BalancedEmitter(duration: 0.5, frequency: 20) { chunk in
            message.textContent += chunk
            updateStreamingVisibility(
                for: message,
                session: session,
                collapseReasoningWhenComplete: collapseAfterReasoningComplete
            )
            session.notifyMessagesDidChange(scrolling: true)
        }
        defer {
            reasoningEmitter.cancel()
            textEmitter.cancel()
        }

        var pendingToolCalls: [ToolRequest] = []
        var streamedCharacterCount = 0

        for try await response in stream {
            try Task.checkCancellation()
            switch response {
            case let .reasoning(value):
                await textEmitter.wait()
                reasoningEmitter.add(value)

            case let .text(value):
                await reasoningEmitter.wait()
                updateTextEmitterRate(textEmitter, streamedCharacterCount: streamedCharacterCount)
                textEmitter.add(value)
                streamedCharacterCount += value.count

            case let .tool(call):
                logger.notice(
                    "stream emitted tool call session=\(session.id, privacy: .public) tool=\(call.name, privacy: .public) id=\(call.id, privacy: .public)"
                )
                await reasoningEmitter.wait()
                await textEmitter.wait()
                pendingToolCalls.append(call)
                _ = ensureRunningToolCallPart(
                    for: call,
                    in: message,
                    session: session
                )
                session.notifyMessagesDidChange(scrolling: true)

            case .image:
                await reasoningEmitter.wait()
                await textEmitter.wait()

            case .thinkingBlock, .redactedThinking:
                break

            case let .usage(tokenUsage):
                session.reportUsage(tokenUsage)
            }
        }

        await reasoningEmitter.wait()
        await textEmitter.wait()
        return try finalizeQueryTurn(
            session: session,
            client: client,
            message: message,
            requestMessages: &requestMessages,
            pendingToolCalls: pendingToolCalls,
            collapseReasoningWhenComplete: collapseAfterReasoningComplete
        )
    } catch {
        session.stopThinking(for: message.id)
        discardTransientAssistantMessageIfNeeded(message, from: session)
        throw error
    }
}

@MainActor
private func executeToolCalls(
    _ pendingToolCalls: [ToolRequest],
    assistantMessage: ConversationMessage,
    requestMessages: inout [ChatRequestBody.Message],
    toolUseContext: ToolExecutionContext
) async throws {
    guard !pendingToolCalls.isEmpty else { return }
    guard let toolProvider = toolUseContext.toolProvider else {
        throw QueryExecutionError.toolProviderUnavailable
    }

    logger.notice(
        "executeToolCalls entered session=\(toolUseContext.session.id, privacy: .public) count=\(pendingToolCalls.count)"
    )

    var interruptedToolCalls: [(request: ToolRequest, toolCallPartIndex: Int)] = []

    defer {
        if Task.isCancelled {
            logger.notice(
                "executeToolCalls detected cancellation session=\(toolUseContext.session.id, privacy: .public) synthesizedResults=\(interruptedToolCalls.count)"
            )
            appendInterruptedToolResults(
                interruptedToolCalls,
                to: assistantMessage,
                requestMessages: &requestMessages,
                toolUseContext: toolUseContext
            )
            toolUseContext.session.notifyMessagesDidChange(scrolling: true)
        }
    }

    for request in pendingToolCalls {
        try Task.checkCancellation()
        let partIndex = ensureRunningToolCallPart(
            for: request,
            in: assistantMessage,
            session: toolUseContext.session
        )
        toolUseContext.session.notifyMessagesDidChange(scrolling: true)

        logger.notice(
            "tool lookup session=\(toolUseContext.session.id, privacy: .public) tool=\(request.name, privacy: .public) id=\(request.id, privacy: .public)"
        )
        guard let tool = await toolProvider.findTool(for: request) else {
            updateToolCallPart(at: partIndex, in: assistantMessage, state: .failed)
            toolUseContext.session.notifyMessagesDidChange(scrolling: true)
            throw QueryExecutionError.toolNotFound(name: request.name)
        }

        interruptedToolCalls.append((request: request, toolCallPartIndex: partIndex))

        let permissionDecision = await toolUseContext.canUseTool(request, tool, toolUseContext)
        let responseText: String
        let responseState: ToolCallState
        if !permissionDecision.allowsExecution {
            updateToolCallPart(
                at: partIndex,
                in: assistantMessage,
                toolName: tool.displayName,
                state: .failed
            )
            toolUseContext.session.notifyMessagesDidChange(scrolling: true)
            responseText = deniedToolCallText(for: permissionDecision)
            responseState = .failed
        } else {
            updateToolCallPart(
                at: partIndex,
                in: assistantMessage,
                toolName: tool.displayName,
                state: .running
            )
            toolUseContext.session.notifyMessagesDidChange(scrolling: true)
            try Task.checkCancellation()
            logger.notice(
                "tool execution begin session=\(toolUseContext.session.id, privacy: .public) tool=\(request.name, privacy: .public) id=\(request.id, privacy: .public)"
            )
            (responseText, responseState) = try await executeSingleToolCall(
                request,
                tool: tool,
                toolProvider: toolProvider,
                toolUseContext: toolUseContext
            )
        }

        logger.notice(
            "tool execution end session=\(toolUseContext.session.id, privacy: .public) tool=\(request.name, privacy: .public) id=\(request.id, privacy: .public) state=\(String(describing: responseState), privacy: .public)"
        )

        updateToolCallPart(at: partIndex, in: assistantMessage, state: responseState)
        appendToolResult(
            for: request,
            text: responseText,
            assistantMessage: assistantMessage,
            requestMessages: &requestMessages
        )
        toolUseContext.session.notifyMessagesDidChange(scrolling: true)
    }
}

@MainActor
private func executeSingleToolCall(
    _ request: ToolRequest,
    tool: any ToolExecutor,
    toolProvider: any ToolProvider,
    toolUseContext: ToolExecutionContext
) async throws -> (text: String, state: ToolCallState) {
    if Task.isCancelled {
        logger.notice(
            "tool execution cancelled before start session=\(toolUseContext.session.id, privacy: .public) tool=\(request.name, privacy: .public) id=\(request.id, privacy: .public)"
        )
        throw CancellationError()
    }
    do {
        let result = try await toolProvider.executeTool(
            tool,
            parameters: request.arguments
        )
        if Task.isCancelled {
            logger.notice(
                "tool execution cancelled after provider return session=\(toolUseContext.session.id, privacy: .public) tool=\(request.name, privacy: .public) id=\(request.id, privacy: .public)"
            )
            throw CancellationError()
        }
        let text = ToolInvocationHelpers.truncateText(
            result.output,
            limit: toolUseContext.responseLimit(for: tool),
            suffix: String.localized("Output truncated.")
        )
        logger.notice(
            "tool provider returned session=\(toolUseContext.session.id, privacy: .public) tool=\(request.name, privacy: .public) id=\(request.id, privacy: .public) isError=\(String(result.isError), privacy: .public) outputLength=\(text.count)"
        )
        return (
            text: text.isEmpty ? String.localized("Tool executed successfully with no output") : text,
            state: result.isError ? .failed : .succeeded
        )
    } catch is CancellationError {
        logger.notice(
            "tool execution throwing cancellation session=\(toolUseContext.session.id, privacy: .public) tool=\(request.name, privacy: .public) id=\(request.id, privacy: .public)"
        )
        throw CancellationError()
    } catch {
        logger.error(
            "tool execution failed session=\(toolUseContext.session.id, privacy: .public) tool=\(request.name, privacy: .public) id=\(request.id, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
        )
        return (
            text: String.localized("Tool execution failed: \(error.localizedDescription)"),
            state: .failed
        )
    }
}
