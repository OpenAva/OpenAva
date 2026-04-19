import ChatUI
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
            let sessionID = ToolRuntime.InvocationContext.sessionID
            let record = await SubAgentTaskStore.shared.create(
                agentType: definition.agentType,
                description: description,
                prompt: prompt,
                parentSessionID: sessionID
            )
            await installTaskMessageIfPossible(taskID: record.id, sessionID: sessionID)

            if params.runInBackground == true {
                let task = Task { @MainActor in
                    do {
                        _ = try await executeSubAgentTask(
                            record: record,
                            prompt: prompt,
                            definition: definition,
                            workspaceRootURL: workspaceRootURL,
                            modelConfig: modelConfig,
                            sessionID: sessionID,
                            executeTool: { nestedRequest in
                                await toolInvoker(nestedRequest, sessionID)
                            }
                        )
                    } catch {
                        // State was already recorded for the task card.
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

            let output = try await executeSubAgentTask(
                record: record,
                prompt: prompt,
                definition: definition,
                workspaceRootURL: workspaceRootURL,
                modelConfig: modelConfig,
                sessionID: sessionID,
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
            guard let snapshot = await SubAgentTaskStore.shared.snapshot(taskID: params.taskID) else {
                return BridgeInvokeResponse(
                    id: request.id,
                    ok: false,
                    error: OpenClawNodeError(code: .invalidRequest, message: "NOT_FOUND: sub agent task not found")
                )
            }
            let record = snapshot.record
            let payload = ([
                "## Sub Agent Status",
                "- task_id: \(record.id)",
                "- agent: \(record.agentType)",
                "- status: \(record.status.rawValue)",
                snapshot.progress?.summary.map { "- summary: \($0)" },
                snapshot.progress.map { "- turns: \($0.totalTurns)" },
                snapshot.progress.map { "- tool_calls: \($0.totalToolCalls)" },
                snapshot.progress.map { "- duration_ms: \($0.durationMs)" },
                "- updated_at: \(ISO8601DateFormatter().string(from: record.updatedAt))",
                record.result.map { "\n\($0)" } ?? record.errorDescription.map { "\nError: \($0)" } ?? "",
            ] as [String?]).compactMap { $0 }.joined(separator: "\n")
            return ToolInvocationHelpers.successResponse(id: request.id, payload: payload)

        case "subagent.cancel":
            let params = try ToolInvocationHelpers.decodeParams(TaskParams.self, from: request.paramsJSON)
            let cancelled = await SubAgentTaskStore.shared.cancel(taskID: params.taskID)
            let taskRecord = await SubAgentTaskStore.shared.record(taskID: params.taskID)
            let parentSessionID = taskRecord?.parentSessionID
            if cancelled, let parentSessionID {
                await syncTaskMessageIfPossible(taskID: params.taskID, sessionID: parentSessionID)
            }
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

    private static func executeSubAgentTask(
        record: SubAgentTaskStore.TaskRecord,
        prompt: String,
        definition: SubAgentDefinition,
        workspaceRootURL: URL?,
        modelConfig: AppConfig.LLMModel,
        sessionID: String?,
        executeTool: @escaping @Sendable (BridgeInvokeRequest) async -> BridgeInvokeResponse
    ) async throws -> SubAgentRunOutput {
        do {
            let output = try await SubAgentRunner.run(
                prompt: prompt,
                definition: definition,
                workspaceRootURL: workspaceRootURL,
                modelConfig: modelConfig,
                executeTool: executeTool,
                onProgress: { snapshot in
                    await SubAgentTaskStore.shared.updateProgress(taskID: record.id, snapshot: snapshot)
                    await syncTaskMessageIfPossible(taskID: record.id, sessionID: sessionID)
                }
            )

            await SubAgentTaskStore.shared.markCompleted(
                taskID: record.id,
                result: output.content,
                summary: resultPreview(from: output.content),
                totalTurns: output.totalTurns,
                totalToolCalls: output.totalToolCalls,
                durationMs: output.durationMs
            )
            await syncTaskMessageIfPossible(taskID: record.id, sessionID: sessionID)
            return output
        } catch {
            let taskSnapshot = await SubAgentTaskStore.shared.snapshot(taskID: record.id)
            let progress = taskSnapshot?.progress
            await SubAgentTaskStore.shared.markFailed(
                taskID: record.id,
                errorDescription: error.localizedDescription,
                summary: progress?.summary ?? "Failed",
                totalTurns: progress?.totalTurns,
                totalToolCalls: progress?.totalToolCalls,
                durationMs: progress?.durationMs
            )
            await syncTaskMessageIfPossible(taskID: record.id, sessionID: sessionID)
            throw error
        }
    }

    private static func installTaskMessageIfPossible(taskID: String, sessionID: String?) async {
        guard let snapshot = await SubAgentTaskStore.shared.snapshot(taskID: taskID) else { return }
        let metadata = taskMetadata(from: snapshot)
        let message = await MainActor.run { () -> ConversationMessage? in
            guard let session = cachedSession(for: sessionID) else { return nil }
            let message = session.appendNewMessage(role: .system) { msg in
                msg.subtype = "subagent_task"
                msg.textContent = ""
                msg.subAgentTaskMetadata = metadata
            }
            session.recordMessageInTranscript(message)
            session.notifyMessagesDidChange(scrolling: false)
            return message
        }
        guard let message else { return }
        await SubAgentTaskStore.shared.bindMessage(taskID: taskID, messageID: message.id)
    }

    private static func syncTaskMessageIfPossible(taskID: String, sessionID: String?) async {
        guard let snapshot = await SubAgentTaskStore.shared.snapshot(taskID: taskID),
              let messageID = snapshot.record.messageID
        else {
            return
        }

        let metadata = taskMetadata(from: snapshot)
        await MainActor.run {
            guard let session = cachedSession(for: sessionID),
                  let message = session.messages.first(where: { $0.id == messageID })
            else {
                return
            }

            message.subtype = "subagent_task"
            message.subAgentTaskMetadata = metadata
            switch snapshot.record.status {
            case .completed:
                message.textContent = snapshot.record.result ?? ""
            case .failed:
                message.textContent = snapshot.record.errorDescription ?? ""
            case .cancelled, .running:
                message.textContent = ""
            }
            session.recordMessageInTranscript(message)
            session.notifyMessagesDidChange(scrolling: false)
        }
    }

    @MainActor
    private static func cachedSession(for invocationSessionID: String?) -> ConversationSession? {
        guard let sessionID = resolvedMainSessionID(from: invocationSessionID) else { return nil }
        return ConversationSessionManager.shared.cachedSession(for: sessionID)
    }

    private static func resolvedMainSessionID(from invocationSessionID: String?) -> String? {
        guard let invocationSessionID else { return nil }
        let trimmed = invocationSessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let separator = trimmed.range(of: "::") else { return trimmed }
        let suffix = trimmed[separator.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return suffix.isEmpty ? trimmed : suffix
    }

    private static func taskMetadata(from snapshot: SubAgentTaskStore.TaskSnapshot) -> SubAgentTaskMetadata {
        SubAgentTaskMetadata(
            taskID: snapshot.record.id,
            agentType: snapshot.record.agentType,
            taskDescription: snapshot.record.description,
            status: snapshot.record.status.rawValue,
            summary: snapshot.progress?.summary,
            totalTurns: snapshot.progress?.totalTurns,
            totalToolCalls: snapshot.progress?.totalToolCalls,
            durationMs: snapshot.progress?.durationMs,
            resultPreview: resultPreview(from: snapshot.record.result),
            errorDescription: snapshot.record.errorDescription,
            recentActivities: snapshot.progress?.recentActivities.isEmpty == false ? snapshot.progress?.recentActivities : nil,
            updatedAt: ISO8601DateFormatter().string(from: snapshot.record.updatedAt)
        )
    }

    private static func resultPreview(from text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }
        let singleLine = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard singleLine.count > 140 else { return singleLine }
        return String(singleLine.prefix(140)) + "…"
    }
}
