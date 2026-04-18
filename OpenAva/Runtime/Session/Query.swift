import ChatClient
import ChatUI
import Foundation
import OSLog

private let logger = Logger(subsystem: "com.day1-labs.openava", category: "chat.stop.query")

func shouldReserveFinalResponseTurn(completedTurns: Int, maxTurns: Int) -> Bool {
    guard maxTurns > 0 else { return false }
    return completedTurns + 1 >= maxTurns
}

func finalTurnResponseReminderText() -> String {
    """
    This is the final allowed model turn for this task.
    Provide the best possible final answer using the conversation and any tool results already available.
    Do not call tools or ask for more investigation.
    If anything remains uncertain, clearly separate confirmed findings from remaining unknowns.
    """
}

private func appendFinalTurnResponseReminder(to requestMessages: inout [ChatRequestBody.Message]) {
    requestMessages.append(
        .user(
            content: .text(
                """
                <system-reminder>
                \(finalTurnResponseReminderText())
                </system-reminder>
                """
            )
        )
    )
}

private func normalizedToolName(_ name: String) -> String {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "tool" : trimmed
}

private func updateToolCallPart(
    in message: ConversationMessage,
    at index: Int,
    toolName: String? = nil,
    state: ToolCallState
) {
    guard index < message.parts.count,
          case var .toolCall(part) = message.parts[index]
    else { return }
    if let toolName { part.toolName = toolName }
    part.state = state
    message.parts[index] = .toolCall(part)
}

private struct QueryState {
    var requestMessages: [ChatRequestBody.Message]
    var totalTurns: Int = 0
    var totalToolCalls: Int = 0
    var didCompact = false
    var pendingToolUseSummary: String?
}

private struct QueryTurnOutput {
    let assistantMessage: ConversationMessage?
    let pendingToolCalls: [ToolRequest]
    let finishReason: FinishReason
}

private struct InterruptedToolCall {
    let request: ToolRequest
    let toolCallPartIndex: Int
}

private struct ToolCallResponse {
    let text: String
    let state: ToolCallState
    let summaryStatus: String
}

private struct ToolUseSummaryBuilder {
    private var lines = [ConversationMarkers.toolUseSummaryPrefix, ""]

    mutating func append(request: ToolRequest, response: ToolCallResponse) {
        let parameterSummary = summarizeToolText(request.arguments, limit: 160)
        let outputSummary = summarizeToolText(response.text, limit: 240)

        lines.append("- \(request.name) [\(response.summaryStatus)]")
        if !parameterSummary.isEmpty {
            lines.append("  input: \(parameterSummary)")
        }
        if !outputSummary.isEmpty {
            lines.append("  output: \(outputSummary)")
        }
    }

    func build() -> String? {
        guard lines.count > 2 else { return nil }
        return lines.joined(separator: "\n")
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
    continuation: AsyncThrowingStream<QueryEvent, Error>.Continuation
) async throws -> QueryResult {
    logger.notice(
        "query entered session=\(session.id, privacy: .public) maxTurns=\(maxTurns) toolsEnabled=\(String(tools != nil), privacy: .public)"
    )
    var state = QueryState(requestMessages: requestMessages)
    let result = try await queryLoop(
        session: session,
        model: model,
        state: &state,
        tools: tools,
        toolUseContext: toolUseContext,
        maxTurns: maxTurns,
        continuation: continuation
    )
    requestMessages = state.requestMessages
    logger.notice(
        "query exited session=\(session.id, privacy: .public) finishReason=\(String(describing: result.finishReason), privacy: .public) interruptReason=\(result.interruptReason ?? "nil", privacy: .public) totalTurns=\(result.totalTurns) totalToolCalls=\(result.totalToolCalls)"
    )
    return result
}

@MainActor
private func queryLoop(
    session: ConversationSession,
    model: ConversationSession.Model,
    state: inout QueryState,
    tools: [ChatRequestBody.Tool]?,
    toolUseContext: ToolExecutionContext,
    maxTurns: Int,
    continuation: AsyncThrowingStream<QueryEvent, Error>.Continuation
) async throws -> QueryResult {
    while state.totalTurns < maxTurns {
        let nextTurn = state.totalTurns + 1
        let shouldReserveFinalTurn = shouldReserveFinalResponseTurn(
            completedTurns: state.totalTurns,
            maxTurns: maxTurns
        )
        logger.debug(
            "query loop tick session=\(session.id, privacy: .public) turn=\(nextTurn) cancelled=\(String(Task.isCancelled), privacy: .public)"
        )
        try Task.checkCancellation()

        flushPendingToolUseSummary(session: session, state: &state)
        let compacted = await compactAndTrimRequestMessages(
            session: session,
            model: model,
            requestMessages: &state.requestMessages,
            tools: tools,
            continuation: continuation
        )
        if compacted {
            state.didCompact = true
        }

        if shouldReserveFinalTurn {
            logger.notice(
                "query loop reserving final response turn session=\(session.id, privacy: .public) turn=\(nextTurn)"
            )
            appendFinalTurnResponseReminder(to: &state.requestMessages)
        }

        state.totalTurns += 1

        let turn = try await executeQueryTurn(
            session: session,
            model: model,
            requestMessages: &state.requestMessages,
            tools: shouldReserveFinalTurn ? nil : tools,
            continuation: continuation
        )

        guard !turn.pendingToolCalls.isEmpty else {
            logger.notice(
                "query loop completed without tools session=\(session.id, privacy: .public) finishReason=\(String(describing: turn.finishReason), privacy: .public)"
            )
            return QueryResult(
                finishReason: turn.finishReason,
                totalTurns: state.totalTurns,
                totalToolCalls: state.totalToolCalls,
                didCompact: state.didCompact
            )
        }

        state.totalToolCalls += turn.pendingToolCalls.count
        let totalToolCalls = state.totalToolCalls
        logger.notice(
            "query loop executing tools session=\(session.id, privacy: .public) count=\(turn.pendingToolCalls.count) totalToolCalls=\(totalToolCalls)"
        )
        state.pendingToolUseSummary = try await executeToolCalls(
            turn.pendingToolCalls,
            assistantMessage: turn.assistantMessage,
            requestMessages: &state.requestMessages,
            toolUseContext: toolUseContext,
            continuation: continuation
        )
    }

    flushPendingToolUseSummary(session: session, state: &state)

    let message = session.appendNewMessage(role: .assistant) { msg in
        msg.textContent = String.localized("Reached maximum number of turns.")
        msg.finishReason = .length
    }
    session.recordMessageInTranscript(message)
    continuation.yield(.refresh(scrolling: true))

    return QueryResult(
        finishReason: FinishReason.length,
        totalTurns: state.totalTurns,
        totalToolCalls: state.totalToolCalls,
        didCompact: state.didCompact
    )
}

@MainActor
private func synthesizeInterruptedToolResults(
    _ entries: [InterruptedToolCall],
    assistantMessage: ConversationMessage,
    requestMessages: inout [ChatRequestBody.Message],
    toolUseContext: ToolExecutionContext,
    continuation: AsyncThrowingStream<QueryEvent, Error>.Continuation
) {
    guard !entries.isEmpty else { return }
    let interruptionText = toolUseContext.interruptionText()
    for entry in entries {
        updateToolCallPart(in: assistantMessage, at: entry.toolCallPartIndex, state: .failed)

        let alreadyHasResult = assistantMessage.parts.contains { part in
            guard case let .toolResult(result) = part else { return false }
            return result.toolCallID == entry.request.id
        }
        guard !alreadyHasResult else { continue }

        assistantMessage.parts.append(
            .toolResult(
                .init(toolCallID: entry.request.id, result: interruptionText, isCollapsed: true)
            )
        )
        requestMessages.append(
            .tool(content: .text(interruptionText), toolCallID: entry.request.id)
        )
    }
    continuation.yield(.refresh(scrolling: true))
}

@MainActor
private func executeQueryTurn(
    session: ConversationSession,
    model: ConversationSession.Model,
    requestMessages: inout [ChatRequestBody.Message],
    tools: [ChatRequestBody.Tool]?,
    continuation: AsyncThrowingStream<QueryEvent, Error>.Continuation
) async throws -> QueryTurnOutput {
    try Task.checkCancellation()
    logger.debug("execute query turn session=\(session.id, privacy: .public) starting")
    continuation.yield(.loading(nil))

    let message = session.appendNewMessage(role: .assistant)
    continuation.yield(.refresh(scrolling: true))

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

    func collapseReasoning() {
        guard collapseAfterReasoningComplete else { return }
        for (index, part) in message.parts.enumerated() {
            if case var .reasoning(reasoningPart) = part {
                reasoningPart.isCollapsed = true
                message.parts[index] = .reasoning(reasoningPart)
                break
            }
        }
    }

    func updateVisibleState() {
        if !message.textContent.isEmpty {
            session.stopThinking(for: message.id)
            collapseReasoning()
        } else if let reasoning = message.reasoningContent, !reasoning.isEmpty {
            session.startThinking(for: message.id)
        }
    }

    // Claude Code-style persistence strategy:
    // - Keep the UI streaming in-memory.
    // - Persist only structural changes (e.g. tool call parts) and the final message.
    // This avoids appending many full-snapshot updates for the same message UUID.

    let reasoningEmitter = BalancedEmitter(duration: 1.0, frequency: 30) { chunk in
        let current = message.reasoningContent ?? ""
        message.reasoningContent = current + chunk
        updateVisibleState()
        continuation.yield(.refresh(scrolling: true))
    }
    let textEmitter = BalancedEmitter(duration: 0.5, frequency: 20) { chunk in
        message.textContent += chunk
        updateVisibleState()
        continuation.yield(.refresh(scrolling: true))
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
            if streamedCharacterCount >= 5000 {
                textEmitter.update(duration: 1.0, frequency: 3)
            } else if streamedCharacterCount >= 2000 {
                textEmitter.update(duration: 1.0, frequency: 9)
            } else if streamedCharacterCount >= 1000 {
                textEmitter.update(duration: 0.5, frequency: 15)
            }
            textEmitter.add(value)
            streamedCharacterCount += value.count

        case let .tool(call):
            logger.notice(
                "stream emitted tool call session=\(session.id, privacy: .public) tool=\(call.name, privacy: .public) id=\(call.id, privacy: .public)"
            )
            await reasoningEmitter.wait()
            await textEmitter.wait()
            pendingToolCalls.append(call)

            let alreadyHasToolCallPart = message.parts.contains { part in
                guard case let .toolCall(toolCallPart) = part else { return false }
                return toolCallPart.id == call.id
            }
            if !alreadyHasToolCallPart {
                message.parts.append(
                    .toolCall(
                        ToolCallContentPart(
                            id: call.id,
                            toolName: normalizedToolName(call.name),
                            apiName: call.name,
                            parameters: call.arguments,
                            state: .running
                        )
                    )
                )
                continuation.yield(.refresh(scrolling: true))
                session.recordMessageInTranscript(message)
            }

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

    session.stopThinking(for: message.id)
    continuation.yield(.refresh(scrolling: true))

    collapseReasoning()
    if collapseAfterReasoningComplete {
        continuation.yield(.refresh(scrolling: true))
    }

    let hasText = !message.textContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    let hasReasoning = !(message.reasoningContent ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    let hasToolCalls = !pendingToolCalls.isEmpty

    // Empty follow-up after tool result: discard the message.
    if !hasText, !hasReasoning, !hasToolCalls,
       requestMessages.last.map({ if case .tool = $0 { true } else { false } }) == true
    {
        session.removeMessage(with: message.id)
        continuation.yield(.refresh(scrolling: true))
        return QueryTurnOutput(assistantMessage: nil, pendingToolCalls: [], finishReason: .stop)
    }

    requestMessages.append(
        .assistant(
            content: hasText ? .text(message.textContent) : nil,
            toolCalls: pendingToolCalls.map {
                .init(id: $0.id, function: .init(name: $0.name, arguments: $0.arguments))
            },
            reasoning: hasReasoning ? message.reasoningContent!.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        )
    )

    // No content at all means the model failed to produce a response.
    if !hasText, !hasReasoning, !hasToolCalls {
        message.finishReason = .error
        if let collectedError = client.collectedErrors?
            .trimmingCharacters(in: .whitespacesAndNewlines), !collectedError.isEmpty
        {
            throw NSError(
                domain: "ChatClient",
                code: 0,
                userInfo: [NSLocalizedDescriptionKey: collectedError]
            )
        }
        throw InferenceError.noResponseFromModel
    }

    let finishReason: FinishReason = hasToolCalls ? .toolCalls : .stop
    message.finishReason = finishReason

    session.recordMessageInTranscript(message)

    continuation.yield(.refresh(scrolling: true))
    return QueryTurnOutput(
        assistantMessage: message,
        pendingToolCalls: pendingToolCalls,
        finishReason: finishReason
    )
}

@MainActor
private func executeToolCalls(
    _ pendingToolCalls: [ToolRequest],
    assistantMessage: ConversationMessage?,
    requestMessages: inout [ChatRequestBody.Message],
    toolUseContext: ToolExecutionContext,
    continuation: AsyncThrowingStream<QueryEvent, Error>.Continuation
) async throws -> String? {
    guard let toolProvider = toolUseContext.toolProvider,
          !pendingToolCalls.isEmpty,
          let assistantMessage
    else {
        return nil
    }

    logger.notice(
        "executeToolCalls entered session=\(toolUseContext.session.id, privacy: .public) count=\(pendingToolCalls.count)"
    )

    var interruptedToolCalls: [InterruptedToolCall] = []
    var summaryBuilder = ToolUseSummaryBuilder()

    defer {
        if Task.isCancelled {
            logger.notice(
                "executeToolCalls detected cancellation session=\(toolUseContext.session.id, privacy: .public) synthesizedResults=\(interruptedToolCalls.count)"
            )
            synthesizeInterruptedToolResults(
                interruptedToolCalls,
                assistantMessage: assistantMessage,
                requestMessages: &requestMessages,
                toolUseContext: toolUseContext,
                continuation: continuation
            )
        }
    }

    for (index, request) in pendingToolCalls.enumerated() {
        try Task.checkCancellation()

        let existingPartIndex = assistantMessage.parts.firstIndex { part in
            guard case let .toolCall(toolCallPart) = part else { return false }
            return toolCallPart.id == request.id
        }
        let partIndex = existingPartIndex ?? assistantMessage.parts.count
        if existingPartIndex != nil {
            updateToolCallPart(in: assistantMessage, at: partIndex,
                               toolName: normalizedToolName(request.name), state: .running)
        } else {
            assistantMessage.parts.append(
                .toolCall(
                    ToolCallContentPart(
                        id: request.id,
                        toolName: normalizedToolName(request.name),
                        apiName: request.name,
                        parameters: request.arguments,
                        state: .running
                    )
                )
            )
            toolUseContext.session.recordMessageInTranscript(assistantMessage)
        }
        continuation.yield(.refresh(scrolling: true))

        logger.notice(
            "tool lookup session=\(toolUseContext.session.id, privacy: .public) tool=\(request.name, privacy: .public) id=\(request.id, privacy: .public)"
        )
        guard let tool = await toolProvider.findTool(for: request) else {
            updateToolCallPart(in: assistantMessage, at: partIndex, state: .failed)
            continuation.yield(.refresh(scrolling: true))
            throw InferenceError.toolNotFound(name: request.name)
        }

        interruptedToolCalls.append(
            InterruptedToolCall(request: request, toolCallPartIndex: partIndex)
        )

        let permissionDecision = await toolUseContext.canUseTool(request, tool, toolUseContext)
        let response: ToolCallResponse
        if !permissionDecision.allowsExecution {
            updateToolCallPart(in: assistantMessage, at: partIndex,
                               toolName: tool.displayName, state: .failed)
            response = makePermissionResponse(for: permissionDecision)
        } else {
            updateToolCallPart(in: assistantMessage, at: partIndex,
                               toolName: tool.displayName, state: .running)
            continuation.yield(.refresh(scrolling: true))
            try Task.checkCancellation()
            logger.notice(
                "tool execution begin session=\(toolUseContext.session.id, privacy: .public) tool=\(request.name, privacy: .public) id=\(request.id, privacy: .public) index=\(index)"
            )
            response = try await executeSingleToolCall(
                request,
                tool: tool,
                toolProvider: toolProvider,
                toolUseContext: toolUseContext
            )
        }

        logger.notice(
            "tool execution end session=\(toolUseContext.session.id, privacy: .public) tool=\(request.name, privacy: .public) id=\(request.id, privacy: .public) state=\(String(describing: response.state), privacy: .public)"
        )

        updateToolCallPart(in: assistantMessage, at: partIndex, state: response.state)

        assistantMessage.parts.append(
            .toolResult(
                .init(toolCallID: request.id, result: response.text, isCollapsed: true)
            )
        )
        requestMessages.append(
            .tool(
                content: .text(response.text),
                toolCallID: request.id
            )
        )
        summaryBuilder.append(request: request, response: response)
        continuation.yield(.refresh(scrolling: true))
    }

    return summaryBuilder.build()
}

@MainActor
private func compactAndTrimRequestMessages(
    session: ConversationSession,
    model: ConversationSession.Model,
    requestMessages: inout [ChatRequestBody.Message],
    tools: [ChatRequestBody.Tool]?,
    continuation: AsyncThrowingStream<QueryEvent, Error>.Continuation
) async -> Bool {
    let capabilities = model.capabilities
    var didCompact = false

    if model.autoCompactEnabled {
        didCompact = await session.compactIfNeeded(
            requestMessages: &requestMessages,
            tools: tools,
            model: model,
            capabilities: capabilities
        )
        if didCompact {
            continuation.yield(.refresh(scrolling: false))
            session.persistMessages()
        }
    }

    continuation.yield(.loading(String.localized("Calculating context window...")))
    await session.trimToContextLength(
        &requestMessages,
        tools: tools,
        maxTokens: model.contextLength
    )
    continuation.yield(.refresh(scrolling: true))
    return didCompact
}

@MainActor
private func flushPendingToolUseSummary(session: ConversationSession, state: inout QueryState) {
    guard let summary = state.pendingToolUseSummary?.trimmingCharacters(in: .whitespacesAndNewlines),
          !summary.isEmpty
    else {
        state.pendingToolUseSummary = nil
        return
    }

    session.appendNewMessage(role: .system) { message in
        message.textContent = summary
        if let latestAssistant = session.messages.last(where: { $0.role == .assistant }) {
            message.createdAt = latestAssistant.createdAt.addingTimeInterval(0.001)
        }
    }
    if let appended = session.messages.last {
        session.recordMessageInTranscript(appended)
    }
    state.pendingToolUseSummary = nil
}

private func summarizeToolText(_ text: String, limit: Int) -> String {
    let singleLine = text
        .replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\n", with: " ")
        .replacingOccurrences(of: "\t", with: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !singleLine.isEmpty else { return "" }
    guard singleLine.count > limit else { return singleLine }
    return "\(String(singleLine.prefix(limit)))..."
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
        let text = truncateToolOutput(
            result.output,
            limit: toolUseContext.responseLimit(for: tool)
        )
        logger.notice(
            "tool provider returned session=\(toolUseContext.session.id, privacy: .public) tool=\(request.name, privacy: .public) id=\(request.id, privacy: .public) isError=\(String(result.isError), privacy: .public) outputLength=\(text.count)"
        )
        return ToolCallResponse(
            text: text.isEmpty ? String.localized("Tool executed successfully with no output") : text,
            state: result.isError ? .failed : .succeeded,
            summaryStatus: result.isError ? "error" : "ok"
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
            state: .failed,
            summaryStatus: "error"
        )
    }
}

private func makePermissionResponse(for decision: ToolPermissionDecision) -> ToolCallResponse {
    let customMessage = decision.message?.trimmingCharacters(in: .whitespacesAndNewlines)
    let hasCustomMessage = customMessage != nil && !customMessage!.isEmpty

    switch decision.behavior {
    case .allow:
        return ToolCallResponse(
            text: String.localized("Tool execution was denied."),
            state: .failed,
            summaryStatus: "error"
        )
    case .deny:
        return ToolCallResponse(
            text: hasCustomMessage ? customMessage! : String.localized("Tool execution was denied."),
            state: .failed,
            summaryStatus: "denied"
        )
    case .ask:
        return ToolCallResponse(
            text: hasCustomMessage ? customMessage! : String.localized("Tool execution requires approval."),
            state: .failed,
            summaryStatus: "approval_required"
        )
    }
}

private func truncateToolOutput(_ text: String, limit: Int) -> String {
    ToolInvocationHelpers.truncateText(
        text,
        limit: limit,
        suffix: String.localized("Output truncated.")
    )
}
