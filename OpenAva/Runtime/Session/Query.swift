import ChatClient
import ChatUI
import Foundation
import OSLog

private let logger = Logger(subsystem: "com.day1-labs.openava", category: "chat.stop.query")

private enum QueryTurnOutput {
    case finished(finishReason: FinishReason)
    case requiresToolCalls(assistantMessage: ConversationMessage, pendingToolCalls: [ToolRequest])
}

private struct QueryLoopState {
    var totalTurns = 0
    var totalToolCalls = 0
    var didCompact = false
}

private struct InterruptedToolCall {
    let request: ToolRequest
    let toolCallPartIndex: Int
}

private struct ToolCallResponse {
    let text: String
    let state: ToolCallState
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

    var hasText: Bool { text != nil }
    var hasReasoning: Bool { reasoning != nil }
    var hasToolCalls: Bool { !pendingToolCalls.isEmpty }
    var isEmpty: Bool { !hasText && !hasReasoning && !hasToolCalls }
    var finishReason: FinishReason { hasToolCalls ? .toolCalls : .stop }

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

struct QueryEventSink {
    let loading: (String?) -> Void
    let refresh: (Bool) -> Void
}

private func normalizedToolCallName(_ name: String) -> String {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "tool" : trimmed
}

private func deniedToolCallResponse(for decision: ToolPermissionDecision) -> ToolCallResponse {
    let customMessage = decision.message?.trimmingCharacters(in: .whitespacesAndNewlines)
    switch decision.behavior {
    case .allow:
        return ToolCallResponse(
            text: String.localized("Tool execution was denied."),
            state: .failed
        )
    case .deny:
        return ToolCallResponse(
            text: (customMessage?.isEmpty == false) ? customMessage! : String.localized("Tool execution was denied."),
            state: .failed
        )
    case .ask:
        return ToolCallResponse(
            text: (customMessage?.isEmpty == false) ? customMessage! : String.localized("Tool execution requires approval."),
            state: .failed
        )
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
    eventSink: QueryEventSink
) async throws -> QueryResult {
    logger.notice(
        "query entered session=\(session.id, privacy: .public) maxTurns=\(maxTurns) toolsEnabled=\(String(tools != nil), privacy: .public)"
    )
    var state = QueryLoopState()
    while state.totalTurns < maxTurns {
        let nextTurn = state.totalTurns + 1
        logger.debug(
            "query loop tick session=\(session.id, privacy: .public) turn=\(nextTurn) cancelled=\(String(Task.isCancelled), privacy: .public)"
        )
        try Task.checkCancellation()

        try await prepareQueryTurn(
            session: session,
            model: model,
            &requestMessages,
            tools: tools,
            eventSink: eventSink,
            state: &state
        )
        state.totalTurns += 1

        let turn = try await executeQueryTurn(
            session: session,
            model: model,
            requestMessages: &requestMessages,
            tools: tools,
            eventSink: eventSink
        )

        if let result = finishQueryIfNeeded(turn: turn, session: session, state: state) {
            return result
        }

        guard case let .requiresToolCalls(assistantMessage, pendingToolCalls) = turn else {
            throw InferenceError.noResponseFromModel
        }

        state.totalToolCalls += pendingToolCalls.count
        logger.notice(
            "query loop executing tools session=\(session.id, privacy: .public) count=\(pendingToolCalls.count) totalToolCalls=\(state.totalToolCalls)"
        )
        try await executeToolCalls(
            pendingToolCalls,
            assistantMessage: assistantMessage,
            requestMessages: &requestMessages,
            toolUseContext: toolUseContext,
            eventSink: eventSink
        )
    }

    return finishQueryAtMaxTurns(session: session, eventSink: eventSink, state: state)
}

@MainActor
private func prepareQueryTurn(
    session: ConversationSession,
    model: ConversationSession.Model,
    _ requestMessages: inout [ChatRequestBody.Message],
    tools: [ChatRequestBody.Tool]?,
    eventSink: QueryEventSink,
    state: inout QueryLoopState
) async throws {
    if model.autoCompactEnabled {
        let didCompactThisTurn = await session.compactIfNeeded(
            requestMessages: &requestMessages,
            tools: tools,
            model: model,
            capabilities: model.capabilities
        )
        if didCompactThisTurn {
            state.didCompact = true
            eventSink.refresh(false)
            session.persistMessages()
        }
    }

    eventSink.loading(String.localized("Calculating context window..."))
    await session.trimToContextLength(
        &requestMessages,
        tools: tools,
        maxTokens: model.contextLength
    )
    eventSink.refresh(true)
}

@MainActor
private func finishQueryIfNeeded(
    turn: QueryTurnOutput,
    session: ConversationSession,
    state: QueryLoopState
) -> QueryResult? {
    guard case let .finished(finishReason) = turn else { return nil }

    logger.notice(
        "query loop completed without tools session=\(session.id, privacy: .public) finishReason=\(String(describing: finishReason), privacy: .public)"
    )
    return makeQueryResult(
        finishReason: finishReason,
        session: session,
        state: state
    )
}

@MainActor
private func finishQueryAtMaxTurns(
    session: ConversationSession,
    eventSink: QueryEventSink,
    state: QueryLoopState
) -> QueryResult {
    let message = session.appendNewMessage(role: .assistant) { msg in
        msg.textContent = String.localized("Reached maximum number of turns.")
        msg.finishReason = .length
    }
    session.recordMessageInTranscript(message)
    eventSink.refresh(true)
    return makeQueryResult(
        finishReason: .length,
        session: session,
        state: state
    )
}

@MainActor
private func makeQueryResult(
    finishReason: FinishReason,
    session: ConversationSession,
    state: QueryLoopState
) -> QueryResult {
    let result = QueryResult(
        finishReason: finishReason,
        totalTurns: state.totalTurns,
        totalToolCalls: state.totalToolCalls,
        didCompact: state.didCompact
    )
    let interruptReason = result.interruptReason ?? "nil"
    logger.notice(
        "query exited session=\(session.id, privacy: .public) finishReason=\(String(describing: result.finishReason), privacy: .public) interruptReason=\(interruptReason, privacy: .public) totalTurns=\(result.totalTurns) totalToolCalls=\(result.totalToolCalls)"
    )
    return result
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
    session: ConversationSession,
    refreshIfExisting: Bool,
    eventSink: QueryEventSink
) -> Int {
    let displayToolName = normalizedToolCallName(request.name)
    if let existingPartIndex = assistantMessage.parts.firstIndex(where: { part in
        guard case let .toolCall(toolCallPart) = part else { return false }
        return toolCallPart.id == request.id
    }) {
        if refreshIfExisting {
            updateToolCallPart(
                at: existingPartIndex,
                in: assistantMessage,
                toolName: displayToolName,
                state: .running
            )
            eventSink.refresh(true)
        }
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
    eventSink.refresh(true)
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
    _ interruptedToolCalls: [InterruptedToolCall],
    to assistantMessage: ConversationMessage,
    requestMessages: inout [ChatRequestBody.Message],
    toolUseContext: ToolExecutionContext,
    eventSink: QueryEventSink
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
    eventSink.refresh(true)
}

private func resolveToolCallResponse(
    request: ToolRequest,
    tool: any ToolExecutor,
    toolProvider: any ToolProvider,
    toolUseContext: ToolExecutionContext,
    partIndex: Int,
    assistantMessage: ConversationMessage,
    eventSink: QueryEventSink
) async throws -> ToolCallResponse {
    let permissionDecision = await toolUseContext.canUseTool(request, tool, toolUseContext)
    if !permissionDecision.allowsExecution {
        updateToolCallPart(
            at: partIndex,
            in: assistantMessage,
            toolName: tool.displayName,
            state: .failed
        )
        return deniedToolCallResponse(for: permissionDecision)
    }

    updateToolCallPart(
        at: partIndex,
        in: assistantMessage,
        toolName: tool.displayName,
        state: .running
    )
    eventSink.refresh(true)
    try Task.checkCancellation()
    logger.notice(
        "tool execution begin session=\(toolUseContext.session.id, privacy: .public) tool=\(request.name, privacy: .public) id=\(request.id, privacy: .public)"
    )
    return try await executeSingleToolCall(
        request,
        tool: tool,
        toolProvider: toolProvider,
        toolUseContext: toolUseContext
    )
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
    return InferenceError.noResponseFromModel
}

@MainActor
private func discardEmptyFollowUpMessage(
    _ message: ConversationMessage,
    from session: ConversationSession,
    eventSink: QueryEventSink
) -> QueryTurnOutput {
    session.messages.removeAll { $0.id == message.id }
    eventSink.refresh(true)
    return .finished(finishReason: .stop)
}

@MainActor
private func commitQueryTurn(
    _ snapshot: QueryTurnSnapshot,
    message: ConversationMessage,
    requestMessages: inout [ChatRequestBody.Message],
    session: ConversationSession,
    eventSink: QueryEventSink
) -> QueryTurnOutput {
    requestMessages.append(snapshot.assistantRequestMessage)

    let finishReason = snapshot.finishReason
    message.finishReason = finishReason
    session.recordMessageInTranscript(message)
    eventSink.refresh(true)

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
    eventSink: QueryEventSink,
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
        return discardEmptyFollowUpMessage(message, from: session, eventSink: eventSink)
    }

    if snapshot.isEmpty {
        message.finishReason = .error
        throw makeNoResponseError(from: client)
    }

    return commitQueryTurn(
        snapshot,
        message: message,
        requestMessages: &requestMessages,
        session: session,
        eventSink: eventSink
    )
}

@MainActor
private func executeQueryTurn(
    session: ConversationSession,
    model: ConversationSession.Model,
    requestMessages: inout [ChatRequestBody.Message],
    tools: [ChatRequestBody.Tool]?,
    eventSink: QueryEventSink
) async throws -> QueryTurnOutput {
    try Task.checkCancellation()
    logger.debug("execute query turn session=\(session.id, privacy: .public) starting")
    eventSink.loading(nil)

    let message = session.appendNewMessage(role: .assistant)
    eventSink.refresh(true)

    let collapseAfterReasoningComplete = session.collapseReasoningWhenComplete
    let client = model.client
    await client.setCollectedErrors(nil)
    let stream = try await client.streamingChat(
        body: .init(
            messages: requestMessages,
            stream: true,
            tools: tools
        )
    )
    defer { session.stopThinking(for: message.id) }

    // Claude Code-style persistence strategy:
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
        eventSink.refresh(true)
    }
    let textEmitter = BalancedEmitter(duration: 0.5, frequency: 20) { chunk in
        message.textContent += chunk
        updateStreamingVisibility(
            for: message,
            session: session,
            collapseReasoningWhenComplete: collapseAfterReasoningComplete
        )
        eventSink.refresh(true)
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
                session: session,
                refreshIfExisting: false,
                eventSink: eventSink
            )

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
        eventSink: eventSink,
        collapseReasoningWhenComplete: collapseAfterReasoningComplete
    )
}

@MainActor
private func executeToolCalls(
    _ pendingToolCalls: [ToolRequest],
    assistantMessage: ConversationMessage,
    requestMessages: inout [ChatRequestBody.Message],
    toolUseContext: ToolExecutionContext,
    eventSink: QueryEventSink
) async throws {
    guard !pendingToolCalls.isEmpty else { return }
    guard let toolProvider = toolUseContext.toolProvider else {
        throw InferenceError.toolProviderUnavailable
    }

    logger.notice(
        "executeToolCalls entered session=\(toolUseContext.session.id, privacy: .public) count=\(pendingToolCalls.count)"
    )

    var interruptedToolCalls: [InterruptedToolCall] = []

    defer {
        if Task.isCancelled {
            logger.notice(
                "executeToolCalls detected cancellation session=\(toolUseContext.session.id, privacy: .public) synthesizedResults=\(interruptedToolCalls.count)"
            )
            appendInterruptedToolResults(
                interruptedToolCalls,
                to: assistantMessage,
                requestMessages: &requestMessages,
                toolUseContext: toolUseContext,
                eventSink: eventSink
            )
        }
    }

    for request in pendingToolCalls {
        try Task.checkCancellation()
        let partIndex = ensureRunningToolCallPart(
            for: request,
            in: assistantMessage,
            session: toolUseContext.session,
            refreshIfExisting: true,
            eventSink: eventSink
        )

        logger.notice(
            "tool lookup session=\(toolUseContext.session.id, privacy: .public) tool=\(request.name, privacy: .public) id=\(request.id, privacy: .public)"
        )
        guard let tool = await toolProvider.findTool(for: request) else {
            updateToolCallPart(at: partIndex, in: assistantMessage, state: .failed)
            eventSink.refresh(true)
            throw InferenceError.toolNotFound(name: request.name)
        }

        interruptedToolCalls.append(
            InterruptedToolCall(request: request, toolCallPartIndex: partIndex)
        )

        let response = try await resolveToolCallResponse(
            request: request,
            tool: tool,
            toolProvider: toolProvider,
            toolUseContext: toolUseContext,
            partIndex: partIndex,
            assistantMessage: assistantMessage,
            eventSink: eventSink
        )

        logger.notice(
            "tool execution end session=\(toolUseContext.session.id, privacy: .public) tool=\(request.name, privacy: .public) id=\(request.id, privacy: .public) state=\(String(describing: response.state), privacy: .public)"
        )

        updateToolCallPart(at: partIndex, in: assistantMessage, state: response.state)
        appendToolResult(
            for: request,
            text: response.text,
            assistantMessage: assistantMessage,
            requestMessages: &requestMessages
        )
        eventSink.refresh(true)
    }
}

@MainActor
private func executeSingleToolCall(
    _ request: ToolRequest,
    tool: any ToolExecutor,
    toolProvider: any ToolProvider,
    toolUseContext: ToolExecutionContext
) async throws -> ToolCallResponse {
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
        return ToolCallResponse(
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
        return ToolCallResponse(
            text: String.localized("Tool execution failed: \(error.localizedDescription)"),
            state: .failed
        )
    }
}
