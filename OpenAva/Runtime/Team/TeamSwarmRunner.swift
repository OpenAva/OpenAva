import ChatClient
import Foundation
import OpenClawKit

struct TeamSwarmTurnOutput {
    let totalTurns: Int
    let totalToolCalls: Int
    let durationMs: Int
    let content: String
    let messages: [ChatRequestBody.Message]
}

enum TeamToolAuthorization {
    case allow
    case deny(String)
}

@MainActor
enum TeamSwarmRunner {
    static func runTurn(
        history: [ChatRequestBody.Message],
        prompt: String,
        definition: SubAgentDefinition,
        workspaceRootURL: URL?,
        modelConfig: AppConfig.LLMModel,
        authorizeTool: (@Sendable (ToolRequest) async -> TeamToolAuthorization)? = nil,
        executeTool: @escaping @Sendable (BridgeInvokeRequest) async -> BridgeInvokeResponse
    ) async throws -> TeamSwarmTurnOutput {
        let start = Date()
        let client = LLMChatClient(modelConfig: modelConfig)
        let systemPrompt = buildSystemPrompt(definition: definition, workspaceRootURL: workspaceRootURL, modelConfig: modelConfig)
        let tools = await filteredTools(for: definition)

        var requestMessages = history
        if requestMessages.isEmpty {
            requestMessages.append(.system(content: .text(systemPrompt)))
        } else if case .system = requestMessages[0] {
            requestMessages[0] = .system(content: .text(systemPrompt))
        } else {
            requestMessages.insert(.system(content: .text(systemPrompt)), at: 0)
        }
        requestMessages.append(.user(content: .text(prompt)))

        var totalToolCalls = 0
        var totalTurns = 0
        var finalText = ""

        while totalTurns < definition.maxTurns {
            let shouldReserveFinalTurn = shouldReserveFinalResponseTurn(
                completedTurns: totalTurns,
                maxTurns: definition.maxTurns
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

            totalTurns += 1

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
                let content = AppConfig.nonEmpty(finalText) ?? "Teammate finished without a text result."
                return TeamSwarmTurnOutput(
                    totalTurns: totalTurns,
                    totalToolCalls: totalToolCalls,
                    durationMs: Int(Date().timeIntervalSince(start) * 1000),
                    content: content,
                    messages: requestMessages
                )
            }

            totalToolCalls += response.tools.count

            for toolRequest in response.tools {
                let toolResponse = await executeToolCall(
                    toolRequest,
                    authorizeTool: authorizeTool,
                    executeTool: executeTool
                )
                requestMessages.append(
                    .tool(
                        content: .text(toolResponse.text),
                        toolCallID: toolRequest.id
                    )
                )
            }
        }

        let fallback = AppConfig.nonEmpty(finalText) ?? "Teammate reached the turn limit before producing a final text answer."
        return TeamSwarmTurnOutput(
            totalTurns: totalTurns,
            totalToolCalls: totalToolCalls,
            durationMs: Int(Date().timeIntervalSince(start) * 1000),
            content: fallback,
            messages: requestMessages
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
        authorizeTool: (@Sendable (ToolRequest) async -> TeamToolAuthorization)? = nil,
        executeTool: @escaping @Sendable (BridgeInvokeRequest) async -> BridgeInvokeResponse
    ) async -> (text: String, isError: Bool) {
        if let authorizeTool {
            switch await authorizeTool(toolRequest) {
            case .allow:
                break
            case let .deny(message):
                return (trimmedToolResponse(message), true)
            }
        }

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
