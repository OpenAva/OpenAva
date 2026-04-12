import Foundation
import OpenClawKit
import OpenClawProtocol

extension SubAgentTools {
    func registerHandlers(
        into handlers: inout [String: ToolHandler],
        context: ToolHandlerRegistrationContext
    ) {
        for command in ["subagent.run", "subagent.status", "subagent.cancel"] {
            handlers[command] = { request in
                try await Self.handleSubAgentInvoke(
                    request,
                    workspaceRootURL: context.workspaceRootURL,
                    modelConfig: context.modelConfig,
                    toolInvoker: context.toolInvoker
                )
            }
        }
    }

    private static func handleSubAgentInvoke(
        _ request: BridgeInvokeRequest,
        workspaceRootURL: URL?,
        modelConfig: AppConfig.LLMModel?,
        toolInvoker: @escaping @Sendable (BridgeInvokeRequest, String?) async -> BridgeInvokeResponse
    ) async throws -> BridgeInvokeResponse {
        struct RunParams: Decodable {
            let description: String
            let prompt: String
            let subagentType: String?
            let runInBackground: Bool?

            enum CodingKeys: String, CodingKey {
                case description
                case prompt
                case subagentType = "subagent_type"
                case runInBackground = "run_in_background"
            }
        }

        struct TaskParams: Decodable {
            let taskID: String

            enum CodingKeys: String, CodingKey {
                case taskID = "task_id"
            }
        }

        switch request.command {
        case "subagent.run":
            let params = try ToolInvocationHelpers.decodeParams(RunParams.self, from: request.paramsJSON)
            guard let prompt = AppConfig.nonEmpty(params.prompt),
                  let description = AppConfig.nonEmpty(params.description)
            else {
                return BridgeInvokeResponse(
                    id: request.id,
                    ok: false,
                    error: OpenClawNodeError(code: .invalidRequest, message: "INVALID_REQUEST: description and prompt are required")
                )
            }
            guard let modelConfig else {
                return BridgeInvokeResponse(
                    id: request.id,
                    ok: false,
                    error: OpenClawNodeError(code: .unavailable, message: "UNAVAILABLE: no configured model for sub agent execution")
                )
            }
            let definition = SubAgentRegistry.definition(for: params.subagentType) ?? SubAgentRegistry.generalPurpose
            let sessionID = LocalToolRuntime.InvocationContext.sessionID

            if params.runInBackground == true {
                let record = await SubAgentTaskStore.shared.create(
                    agentType: definition.agentType,
                    description: description,
                    prompt: prompt,
                    parentSessionID: sessionID
                )
                let task = Task { @MainActor in
                    do {
                        let output = try await SubAgentRunner.run(
                            prompt: prompt,
                            definition: definition,
                            workspaceRootURL: workspaceRootURL,
                            modelConfig: modelConfig,
                            executeTool: { nestedRequest in
                                await toolInvoker(nestedRequest, sessionID)
                            }
                        )
                        await SubAgentTaskStore.shared.markCompleted(taskID: record.id, result: output.content)
                    } catch {
                        await SubAgentTaskStore.shared.markFailed(taskID: record.id, errorDescription: error.localizedDescription)
                    }
                }
                await SubAgentTaskStore.shared.attach(task: task, for: record.id)
                let payload = [
                    "## Sub Agent Task",
                    "- task_id: \(record.id)",
                    "- agent: \(record.agentType)",
                    "- description: \(record.description)",
                    "- status: \(record.status.rawValue)",
                ].joined(separator: "\n")
                return ToolInvocationHelpers.successResponse(id: request.id, payload: payload)
            }

            let output = try await SubAgentRunner.run(
                prompt: prompt,
                definition: definition,
                workspaceRootURL: workspaceRootURL,
                modelConfig: modelConfig,
                executeTool: { nestedRequest in
                    await toolInvoker(nestedRequest, sessionID)
                }
            )
            let payload = [
                "## Sub Agent Result",
                "- agent: \(output.agentType)",
                "- turns: \(output.totalTurns)",
                "- tool_calls: \(output.totalToolCalls)",
                "- duration_ms: \(output.durationMs)",
                "",
                output.content,
            ].joined(separator: "\n")
            return ToolInvocationHelpers.successResponse(id: request.id, payload: payload)

        case "subagent.status":
            let params = try ToolInvocationHelpers.decodeParams(TaskParams.self, from: request.paramsJSON)
            guard let record = await SubAgentTaskStore.shared.record(taskID: params.taskID) else {
                return BridgeInvokeResponse(
                    id: request.id,
                    ok: false,
                    error: OpenClawNodeError(code: .invalidRequest, message: "NOT_FOUND: sub agent task not found")
                )
            }
            let payload = [
                "## Sub Agent Status",
                "- task_id: \(record.id)",
                "- agent: \(record.agentType)",
                "- status: \(record.status.rawValue)",
                "- updated_at: \(ISO8601DateFormatter().string(from: record.updatedAt))",
                record.result.map { "\n\($0)" } ?? record.errorDescription.map { "\nError: \($0)" } ?? "",
            ].joined(separator: "\n")
            return ToolInvocationHelpers.successResponse(id: request.id, payload: payload)

        case "subagent.cancel":
            let params = try ToolInvocationHelpers.decodeParams(TaskParams.self, from: request.paramsJSON)
            let cancelled = await SubAgentTaskStore.shared.cancel(taskID: params.taskID)
            let payload = cancelled
                ? "Sub agent task \(params.taskID) cancelled."
                : "Sub agent task \(params.taskID) is not running."
            return ToolInvocationHelpers.successResponse(id: request.id, payload: payload)

        default:
            return BridgeInvokeResponse(
                id: request.id,
                ok: false,
                error: OpenClawNodeError(code: .invalidRequest, message: "INVALID_REQUEST: unknown sub agent command")
            )
        }
    }
}
