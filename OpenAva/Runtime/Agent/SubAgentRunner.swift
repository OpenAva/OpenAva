import ChatClient
import Foundation
import OpenClawKit

struct SubAgentRunOutput {
    let agentType: String
    let totalTurns: Int
    let totalToolCalls: Int
    let durationMs: Int
    let content: String
}

@MainActor
enum SubAgentRunner {
    static func run(
        prompt: String,
        definition: SubAgentDefinition,
        workspaceRootURL: URL?,
        modelConfig: AppConfig.LLMModel,
        executeTool: @escaping @Sendable (BridgeInvokeRequest) async -> BridgeInvokeResponse,
        onProgress: @escaping @Sendable (SubAgentTaskStore.ProgressSnapshot) async -> Void = { _ in }
    ) async throws -> SubAgentRunOutput {
        let start = Date()
        let client = LLMChatClient(modelConfig: modelConfig)
        let systemPrompt = buildSystemPrompt(definition: definition, workspaceRootURL: workspaceRootURL, modelConfig: modelConfig)
        let tools = await filteredTools(for: definition)

        var requestMessages: [ChatRequestBody.Message] = [
            .system(content: .text(systemPrompt)),
            .user(content: .text(prompt)),
        ]

        let maxTurns = definition.maxTurns
        var totalToolCalls = 0
        var turnCount = 0
        var finalText = ""

        await onProgress(
            .init(
                summary: "Starting sub agent…",
                recentActivities: [],
                totalTurns: 0,
                totalToolCalls: 0,
                durationMs: 0
            )
        )

        while turnCount < maxTurns {
            turnCount += 1
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
                    content: content
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
            content: fallback
        )
    }

    private static func buildSystemPrompt(
        definition: SubAgentDefinition,
        workspaceRootURL: URL?,
        modelConfig: AppConfig.LLMModel
    ) -> String {
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
