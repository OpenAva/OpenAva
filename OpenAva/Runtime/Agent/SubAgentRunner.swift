import ChatClient
import Foundation
import OpenClawKit

struct SubAgentRunOutput {
    let agentType: String
    let totalTurns: Int
    let totalToolCalls: Int
    let durationMs: Int
    let content: String
    let requestMessages: [ChatRequestBody.Message]
    let persistedConversation: [SubAgentTaskStore.PersistedConversationMessage]
}

@MainActor
enum SubAgentRunner {
    static func run(
        prompt: String,
        definition: SubAgentDefinition,
        workspaceRootURL: URL?,
        supportRootURL: URL?,
        modelConfig: AppConfig.LLMModel,
        existingMessages: [ChatRequestBody.Message]? = nil,
        existingConversation: [SubAgentTaskStore.PersistedConversationMessage]? = nil,
        startingTurnCount: Int = 0,
        startingToolCallCount: Int = 0,
        startedAt: Date? = nil,
        executeTool: @escaping @Sendable (BridgeInvokeRequest) async -> BridgeInvokeResponse,
        onProgress: @escaping @Sendable (SubAgentTaskStore.ProgressSnapshot) async -> Void = { _ in }
    ) async throws -> SubAgentRunOutput {
        let start = startedAt ?? Date()
        let client = LLMChatClient(modelConfig: modelConfig)
        let systemPrompt = await buildSystemPrompt(
            definition: definition,
            workspaceRootURL: workspaceRootURL,
            supportRootURL: supportRootURL,
            modelConfig: modelConfig
        )
        let tools = await filteredTools(for: definition)

        var requestMessages = existingMessages ?? [.system(content: .text(systemPrompt))]
        var persistedConversation = existingConversation ?? [
            .init(role: .system, text: systemPrompt, toolCalls: nil, reasoning: nil, toolCallID: nil),
        ]
        if let dynamicMemorySection = await buildDynamicMemorySection(
            query: prompt,
            persistedConversation: persistedConversation,
            supportRootURL: supportRootURL,
            modelConfig: modelConfig
        ) {
            requestMessages.append(.system(content: .text(dynamicMemorySection)))
            persistedConversation.append(
                .init(role: .system, text: dynamicMemorySection, toolCalls: nil, reasoning: nil, toolCallID: nil)
            )
        }
        requestMessages.append(.user(content: .text(prompt)))
        persistedConversation.append(.init(role: .user, text: prompt, toolCalls: nil, reasoning: nil, toolCallID: nil))

        let maxTurns = definition.maxTurns
        var totalToolCalls = startingToolCallCount
        var turnCount = startingTurnCount
        var finalText = ""

        await onProgress(
            .init(
                summary: "Starting sub agent…",
                recentActivities: [],
                totalTurns: turnCount,
                totalToolCalls: totalToolCalls,
                durationMs: Int(Date().timeIntervalSince(start) * 1000)
            )
        )

        var turnsThisRun = 0

        while turnsThisRun < maxTurns {
            turnCount += 1
            turnsThisRun += 1
            await onProgress(
                progressSnapshot(
                    summary: "Thinking on turn \(turnCount)…",
                    recentActivities: nil,
                    totalTurns: turnCount,
                    totalToolCalls: totalToolCalls,
                    startedAt: start
                )
            )

            let response = try await client.chat(
                body: ChatRequestBody(
                    messages: requestMessages,
                    tools: tools.isEmpty ? nil : tools
                )
            )

            finalText = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let assistantMessage: ChatRequestBody.Message = .assistant(
                content: finalText.isEmpty ? nil : .text(finalText),
                toolCalls: response.tools.map {
                    .init(id: $0.id, function: .init(name: $0.name, arguments: $0.arguments))
                },
                reasoning: response.reasoning.isEmpty ? nil : response.reasoning,
                thinkingBlocks: response.thinkingBlocks
            )
            requestMessages.append(assistantMessage)
            persistedConversation.append(
                .init(
                    role: .assistant,
                    text: finalText.isEmpty ? nil : finalText,
                    toolCalls: response.tools.map {
                        .init(id: $0.id, name: $0.name, arguments: $0.arguments)
                    },
                    reasoning: response.reasoning.isEmpty ? nil : response.reasoning,
                    toolCallID: nil
                )
            )

            guard !response.tools.isEmpty else {
                let content = AppConfig.nonEmpty(finalText) ?? "Sub agent finished without a text result."
                await onProgress(
                    progressSnapshot(
                        summary: finalSummary(from: content),
                        recentActivities: nil,
                        totalTurns: turnCount,
                        totalToolCalls: totalToolCalls,
                        startedAt: start
                    )
                )
                return SubAgentRunOutput(
                    agentType: definition.agentType,
                    totalTurns: turnCount,
                    totalToolCalls: totalToolCalls,
                    durationMs: Int(Date().timeIntervalSince(start) * 1000),
                    content: content,
                    requestMessages: requestMessages,
                    persistedConversation: persistedConversation
                )
            }

            let pendingToolCalls = response.tools
            totalToolCalls += pendingToolCalls.count

            for toolRequest in pendingToolCalls {
                let activity = activityDescription(for: toolRequest.name)
                await onProgress(
                    progressSnapshot(
                        summary: activity,
                        recentActivities: [activity],
                        totalTurns: turnCount,
                        totalToolCalls: totalToolCalls,
                        startedAt: start
                    )
                )
                let toolResponse = await executeToolCall(toolRequest, executeTool: executeTool)
                requestMessages.append(
                    .tool(
                        content: .text(toolResponse.text),
                        toolCallID: toolRequest.id
                    )
                )
                persistedConversation.append(
                    .init(
                        role: .tool,
                        text: toolResponse.text,
                        toolCalls: nil,
                        reasoning: nil,
                        toolCallID: toolRequest.id
                    )
                )
                let followUpSummary = toolResponse.isError
                    ? "Tool failed: \(toolRequest.name)"
                    : activity
                await onProgress(
                    progressSnapshot(
                        summary: followUpSummary,
                        recentActivities: [activity],
                        totalTurns: turnCount,
                        totalToolCalls: totalToolCalls,
                        startedAt: start
                    )
                )
            }
        }

        let fallback = AppConfig.nonEmpty(finalText) ?? "Reached maximum number of turns."
        await onProgress(
            progressSnapshot(
                summary: finalSummary(from: fallback),
                recentActivities: nil,
                totalTurns: turnCount,
                totalToolCalls: totalToolCalls,
                startedAt: start
            )
        )
        return SubAgentRunOutput(
            agentType: definition.agentType,
            totalTurns: turnCount,
            totalToolCalls: totalToolCalls,
            durationMs: Int(Date().timeIntervalSince(start) * 1000),
            content: fallback,
            requestMessages: requestMessages,
            persistedConversation: persistedConversation
        )
    }

    private static func buildSystemPrompt(
        definition: SubAgentDefinition,
        workspaceRootURL: URL?,
        supportRootURL _: URL?,
        modelConfig: AppConfig.LLMModel
    ) async -> String {
        let baseParts = [
            AppConfig.nonEmpty(modelConfig.systemPrompt),
            AppConfig.nonEmpty(definition.systemPrompt),
        ].compactMap { $0 }
        let basePrompt = baseParts.joined(separator: "\n\n")
        return AgentContextLoader.composeSystemPrompt(
            baseSystemPrompt: basePrompt,
            workspaceRootURL: workspaceRootURL
        ) ?? basePrompt
    }

    private static func buildDynamicMemorySection(
        query: String,
        persistedConversation: [SubAgentTaskStore.PersistedConversationMessage],
        supportRootURL: URL?,
        modelConfig: AppConfig.LLMModel
    ) async -> String? {
        guard let supportRootURL else {
            return nil
        }

        let builder = AgentMemoryContextBuilder(
            supportRootURL: supportRootURL,
            modelConfig: modelConfig
        )
        return await builder.contextSection(
            query: query,
            recentTools: recentToolNames(from: persistedConversation),
            alreadySurfacedSlugs: AgentMemorySurfacingSupport.surfacedSlugs(from: persistedConversation)
        )
    }

    private static func recentToolNames(from persistedConversation: [SubAgentTaskStore.PersistedConversationMessage], limit: Int = 8) -> [String] {
        var seen = Set<String>()
        var collected: [String] = []

        for message in persistedConversation.reversed() where message.role == .assistant {
            for toolCall in (message.toolCalls ?? []).reversed() {
                let name = toolCall.name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, seen.insert(name).inserted else { continue }
                collected.append(name)
                if collected.count >= limit {
                    return collected
                }
            }
        }

        return collected
    }

    private static func filteredTools(for definition: SubAgentDefinition) async -> [ChatRequestBody.Tool] {
        await ToolRegistry.shared.allDefinitions()
            .filter { definition.allowsTool(functionName: $0.functionName) }
            .map(\.chatRequestTool)
    }

    private static func executeToolCall(
        _ toolRequest: ToolRequest,
        executeTool: @escaping @Sendable (BridgeInvokeRequest) async -> BridgeInvokeResponse
    ) async -> (text: String, isError: Bool) {
        guard let request = await ToolRegistry.shared.request(
            id: toolRequest.id,
            forFunctionName: toolRequest.name,
            argumentsJSON: toolRequest.arguments
        ) else {
            return ("TOOL_NOT_FOUND: \(toolRequest.name)", true)
        }

        let response = await executeTool(request)

        if response.ok {
            let payload = AppConfig.nonEmpty(response.payload) ?? "Tool executed successfully with no output."
            return (trimmedToolResponse(payload), false)
        }

        let message = response.error?.message ?? "Tool execution failed."
        return (trimmedToolResponse(message), true)
    }

    private static func trimmedToolResponse(_ text: String, limit: Int = 64 * 1024) -> String {
        ToolInvocationHelpers.truncateText(text, limit: limit)
    }

    private static func progressSnapshot(
        summary: String?,
        recentActivities: [String]?,
        totalTurns: Int,
        totalToolCalls: Int,
        startedAt: Date
    ) -> SubAgentTaskStore.ProgressSnapshot {
        .init(
            summary: summary,
            recentActivities: recentActivities ?? [],
            totalTurns: totalTurns,
            totalToolCalls: totalToolCalls,
            durationMs: Int(Date().timeIntervalSince(startedAt) * 1000)
        )
    }

    private static func activityDescription(for toolName: String) -> String {
        let normalized = toolName.lowercased()
        if normalized.contains("grep") || normalized.contains("search") {
            return "Searching workspace"
        }
        if normalized.contains("read") || normalized.contains("fetch") || normalized.contains("view") {
            return "Reading context"
        }
        if normalized.contains("task") || normalized.contains("plan") {
            return "Delegating work"
        }
        if normalized.contains("bash") || normalized.contains("run") {
            return "Running commands"
        }
        if normalized.contains("write") || normalized.contains("patch") || normalized.contains("edit") {
            return "Updating files"
        }
        return "Using \(toolName)"
    }

    private static func finalSummary(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Completed" }
        let singleLine = trimmed
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard singleLine.count > 140 else { return singleLine }
        return String(singleLine.prefix(140)) + "…"
    }
}
