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
        executeTool: @escaping @Sendable (BridgeInvokeRequest) async -> BridgeInvokeResponse
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

        while turnCount < maxTurns {
            let shouldReserveFinalTurn = shouldReserveFinalResponseTurn(
                completedTurns: turnCount,
                maxTurns: maxTurns
            )
            if shouldReserveFinalTurn {
                requestMessages.append(.user(content: .text(
                    """
                    <system-reminder>
                    \(finalTurnResponseReminderText())
                    </system-reminder>
                    """
                )))
            }

            turnCount += 1

            let response = try await client.chat(
                body: ChatRequestBody(
                    messages: requestMessages,
                    tools: shouldReserveFinalTurn || tools.isEmpty ? nil : tools
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
                let toolResponse = await executeToolCall(toolRequest, executeTool: executeTool)
                requestMessages.append(
                    .tool(
                        content: .text(toolResponse.text),
                        toolCallID: toolRequest.id
                    )
                )
            }
        }

        let fallback = AppConfig.nonEmpty(finalText) ?? "Reached maximum number of turns."
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
}
