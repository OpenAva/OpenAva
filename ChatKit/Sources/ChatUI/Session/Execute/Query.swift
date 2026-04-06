import ChatClient
import Foundation

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

private struct ToolCallEntry {
    let request: ToolRequest
    let tool: any ToolExecutor
    let toolCallPartIndex: Int
    let permissionDecision: ToolPermissionDecision
}

private struct ToolCallResponse {
    let text: String
    let state: ToolCallState
    let summaryStatus: String
}

@MainActor
func query(
    session: ConversationSession,
    model: ConversationSession.Model,
    requestMessages: inout [ChatRequestBody.Message],
    tools: [ChatRequestBody.Tool]?,
    toolUseContext: ToolUseContext,
    maxTurns: Int,
    continuation: AsyncThrowingStream<QueryEvent, Error>.Continuation
) async throws -> QueryResult {
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
    return result
}

@MainActor
private func queryLoop(
    session: ConversationSession,
    model: ConversationSession.Model,
    state: inout QueryState,
    tools: [ChatRequestBody.Tool]?,
    toolUseContext: ToolUseContext,
    maxTurns: Int,
    continuation: AsyncThrowingStream<QueryEvent, Error>.Continuation
) async throws -> QueryResult {
    while state.totalTurns < maxTurns {
        try session.checkCancellation()

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

        state.totalTurns += 1

        let turn = try await executeQueryTurn(
            session: session,
            model: model,
            requestMessages: &state.requestMessages,
            tools: tools,
            continuation: continuation
        )

        session.persistMessages()

        guard !turn.pendingToolCalls.isEmpty else {
            return QueryResult(
                finishReason: turn.finishReason,
                totalTurns: state.totalTurns,
                totalToolCalls: state.totalToolCalls,
                didCompact: state.didCompact
            )
        }

        state.totalToolCalls += turn.pendingToolCalls.count
        state.pendingToolUseSummary = try await executeToolCalls(
            turn.pendingToolCalls,
            assistantMessage: turn.assistantMessage,
            requestMessages: &state.requestMessages,
            toolUseContext: toolUseContext,
            continuation: continuation
        )
        session.persistMessages()
    }

    flushPendingToolUseSummary(session: session, state: &state)

    let message = session.appendNewMessage(role: .assistant) { msg in
        msg.textContent = String.localized("Reached maximum number of turns.")
        msg.finishReason = .length
    }
    _ = message
    continuation.yield(.refresh(scrolling: true))
    session.persistMessages()

    return QueryResult(
        finishReason: .length,
        totalTurns: state.totalTurns,
        totalToolCalls: state.totalToolCalls,
        didCompact: state.didCompact
    )
}

@MainActor
private func executeQueryTurn(
    session: ConversationSession,
    model: ConversationSession.Model,
    requestMessages: inout [ChatRequestBody.Message],
    tools: [ChatRequestBody.Tool]?,
    continuation: AsyncThrowingStream<QueryEvent, Error>.Continuation
) async throws -> QueryTurnOutput {
    try session.checkCancellation()
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
        try session.checkCancellation()
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
            await reasoningEmitter.wait()
            await textEmitter.wait()
            pendingToolCalls.append(call)

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

    let isFollowUpAfterToolResult: Bool = {
        guard let lastMessage = requestMessages.last else { return false }
        if case .tool = lastMessage {
            return true
        }
        return false
    }()

    if isFollowUpAfterToolResult,
       pendingToolCalls.isEmpty,
       message.textContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
       (message.reasoningContent ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
        session.removeMessage(with: message.id)
        continuation.yield(.refresh(scrolling: true))
        return QueryTurnOutput(assistantMessage: nil, pendingToolCalls: [], finishReason: .stop)
    }

    requestMessages.append(
        .assistant(
            content: message.textContent.isEmpty ? nil : .text(message.textContent),
            toolCalls: pendingToolCalls.map {
                .init(id: $0.id, function: .init(name: $0.name, arguments: $0.arguments))
            },
            reasoning: {
                let trimmed = (message.reasoningContent ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }()
        )
    )

    let finishReason: FinishReason
    if message.textContent.isEmpty, (message.reasoningContent ?? "").isEmpty, pendingToolCalls.isEmpty {
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
    } else if !pendingToolCalls.isEmpty {
        finishReason = .toolCalls
        message.finishReason = .toolCalls
    } else {
        finishReason = .stop
        message.finishReason = .stop
    }

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
    toolUseContext: ToolUseContext,
    continuation: AsyncThrowingStream<QueryEvent, Error>.Continuation
) async throws -> String? {
    guard let toolProvider = toolUseContext.toolProvider,
          !pendingToolCalls.isEmpty,
          let assistantMessage
    else {
        return nil
    }

    continuation.yield(.loading(String.localized("Utilizing tool call")))

    var toolCallEntries: [ToolCallEntry] = []
    for request in pendingToolCalls {
        try toolUseContext.session.checkCancellation()
        guard let tool = await toolProvider.findTool(for: request) else {
            throw InferenceError.toolNotFound(name: request.name)
        }

        let permissionDecision = await toolUseContext.canUseTool(request, tool, toolUseContext)
        let partIndex = assistantMessage.parts.count
        assistantMessage.parts.append(
            .toolCall(
                ToolCallContentPart(
                    id: request.id,
                    toolName: tool.displayName,
                    apiName: request.name,
                    toolIcon: tool.iconName,
                    parameters: request.arguments,
                    state: permissionDecision.allowsExecution ? .running : .failed
                )
            )
        )
        toolCallEntries.append(
            ToolCallEntry(
                request: request,
                tool: tool,
                toolCallPartIndex: partIndex,
                permissionDecision: permissionDecision
            )
        )
    }
    continuation.yield(.refresh(scrolling: true))

    var orderedToolResponses = [ToolCallResponse?](repeating: nil, count: toolCallEntries.count)

    for (index, entry) in toolCallEntries.enumerated() where !entry.permissionDecision.allowsExecution {
        orderedToolResponses[index] = makePermissionResponse(for: entry.permissionDecision)
    }

    for (index, entry) in toolCallEntries.enumerated() where entry.permissionDecision.allowsExecution {
        try toolUseContext.session.checkCancellation()
        orderedToolResponses[index] = await executeSingleToolCall(
            entry,
            toolProvider: toolProvider,
            toolUseContext: toolUseContext
        )
    }

    for (index, entry) in toolCallEntries.enumerated() {
        guard let response = orderedToolResponses[index] else { continue }

        if entry.toolCallPartIndex < assistantMessage.parts.count,
           case var .toolCall(toolCallPart) = assistantMessage.parts[entry.toolCallPartIndex]
        {
            toolCallPart.state = response.state
            assistantMessage.parts[entry.toolCallPartIndex] = .toolCall(toolCallPart)
        }

        assistantMessage.parts.append(
            .toolResult(
                .init(toolCallID: entry.request.id, result: response.text, isCollapsed: true)
            )
        )
        requestMessages.append(
            .tool(
                content: .text(response.text),
                toolCallID: entry.request.id
            )
        )
        continuation.yield(.refresh(scrolling: true))
    }

    return makeToolUseSummary(
        toolCallEntries: toolCallEntries,
        orderedToolResponses: orderedToolResponses
    )
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

    let summaryMessage = session.appendNewMessage(role: .system) { message in
        message.textContent = summary
        if let latestAssistant = session.messages.last(where: { $0.role == .assistant }) {
            message.createdAt = latestAssistant.createdAt.addingTimeInterval(0.001)
        }
    }
    _ = summaryMessage
    session.persistMessages()
    state.pendingToolUseSummary = nil
}

private func makeToolUseSummary(
    toolCallEntries: [ToolCallEntry],
    orderedToolResponses: [ToolCallResponse?]
) -> String? {
    guard !toolCallEntries.isEmpty else { return nil }

    var lines = [ConversationMarkers.toolUseSummaryPrefix, ""]
    for (index, entry) in toolCallEntries.enumerated() {
        guard let response = orderedToolResponses[index] else { continue }
        let parameterSummary = summarizeToolText(entry.request.arguments, limit: 160)
        let outputSummary = summarizeToolText(response.text, limit: 240)
        let status = response.summaryStatus
        lines.append("- \(entry.request.name) [\(status)]")
        if !parameterSummary.isEmpty {
            lines.append("  input: \(parameterSummary)")
        }
        if !outputSummary.isEmpty {
            lines.append("  output: \(outputSummary)")
        }
    }

    guard lines.count > 2 else { return nil }
    return lines.joined(separator: "\n")
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
    _ entry: ToolCallEntry,
    toolProvider: any ToolProvider,
    toolUseContext: ToolUseContext
) async -> ToolCallResponse {
    do {
        let result = try await toolProvider.executeTool(
            entry.tool,
            parameters: entry.request.arguments,
            anchor: toolUseContext.messageListView
        )
        let text = truncateToolOutput(
            result.output,
            limit: toolUseContext.responseLimit(for: entry.tool)
        )
        return ToolCallResponse(
            text: text.isEmpty ? String.localized("Tool executed successfully with no output") : text,
            state: result.isError ? .failed : .succeeded,
            summaryStatus: result.isError ? "error" : "ok"
        )
    } catch {
        return ToolCallResponse(
            text: String.localized("Tool execution failed: \(error.localizedDescription)"),
            state: .failed,
            summaryStatus: "error"
        )
    }
}

private func makePermissionResponse(for decision: ToolPermissionDecision) -> ToolCallResponse {
    switch decision.behavior {
    case .allow:
        return ToolCallResponse(
            text: String.localized("Tool execution was denied."),
            state: .failed,
            summaryStatus: "error"
        )
    case .deny:
        return ToolCallResponse(
            text: permissionMessage(for: decision, fallback: String.localized("Tool execution was denied.")),
            state: .failed,
            summaryStatus: "denied"
        )
    case .ask:
        return ToolCallResponse(
            text: permissionMessage(for: decision, fallback: String.localized("Tool execution requires approval.")),
            state: .failed,
            summaryStatus: "approval_required"
        )
    }
}

private func permissionMessage(for decision: ToolPermissionDecision, fallback: String) -> String {
    let trimmedMessage = decision.message?.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let trimmedMessage, !trimmedMessage.isEmpty else {
        return fallback
    }
    return trimmedMessage
}

private func truncateToolOutput(_ text: String, limit: Int) -> String {
    guard text.count > limit else { return text }
    return "\(String(text.prefix(limit)))...\n\(String.localized("Output truncated."))"
}
