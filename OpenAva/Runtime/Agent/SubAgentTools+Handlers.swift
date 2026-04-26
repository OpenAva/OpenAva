import ChatUI
import Foundation
import OpenClawKit
import OpenClawProtocol

extension SubAgentTools {
    func registerHandlers(
        into handlers: inout [String: ToolHandler],
        context: ToolHandlerRegistrationContext
    ) {
        for command in ["subagent.run", "subagent.continue", "subagent.status", "subagent.cancel"] {
            handlers[command] = { request in
                try await Self.handleSubAgentInvoke(
                    request,
                    workspaceRootURL: context.workspaceRootURL,
                    modelConfig: context.modelConfig,
                    activeRuntimeRootURLProvider: context.activeRuntimeRootURLProvider,
                    toolInvoker: context.toolInvoker
                )
            }
        }
    }

    private static func handleSubAgentInvoke(
        _ request: BridgeInvokeRequest,
        workspaceRootURL: URL?,
        modelConfig: AppConfig.LLMModel?,
        activeRuntimeRootURLProvider: @escaping @Sendable () -> URL?,
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

        struct ContinueParams: Decodable {
            let taskID: String
            let prompt: String

            enum CodingKeys: String, CodingKey {
                case taskID = "task_id"
                case prompt
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
                await spawnBackgroundWorkerIfNeeded(
                    taskID: record.id,
                    definition: definition,
                    workspaceRootURL: workspaceRootURL,
                    runtimeRootURL: activeRuntimeRootURLProvider(),
                    modelConfig: modelConfig,
                    sessionID: sessionID,
                    toolInvoker: toolInvoker
                )
                let payload = [
                    "## Sub Agent Task",
                    "- task_id: \(record.id)",
                    "- agent: \(record.agentType)",
                    "- description: \(record.description)",
                    "- status: running",
                ].joined(separator: "\n")
                return ToolInvocationHelpers.successResponse(id: request.id, payload: payload)
            }

            let output = try await executeSubAgentTask(
                taskID: record.id,
                prompt: prompt,
                definition: definition,
                workspaceRootURL: workspaceRootURL,
                runtimeRootURL: activeRuntimeRootURLProvider(),
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

        case "subagent.continue":
            let params = try ToolInvocationHelpers.decodeParams(ContinueParams.self, from: request.paramsJSON)
            guard let prompt = AppConfig.nonEmpty(params.prompt) else {
                return BridgeInvokeResponse(
                    id: request.id,
                    ok: false,
                    error: OpenClawNodeError(code: .invalidRequest, message: "INVALID_REQUEST: prompt is required")
                )
            }
            guard let modelConfig else {
                return BridgeInvokeResponse(
                    id: request.id,
                    ok: false,
                    error: OpenClawNodeError(code: .unavailable, message: "UNAVAILABLE: no configured model for sub agent execution")
                )
            }
            guard let taskRecord = await SubAgentTaskStore.shared.enqueuePrompt(taskID: params.taskID, prompt: prompt) else {
                return BridgeInvokeResponse(
                    id: request.id,
                    ok: false,
                    error: OpenClawNodeError(code: .invalidRequest, message: "NOT_FOUND: sub agent task not found or prompt invalid")
                )
            }
            guard taskRecord.status != .completed, taskRecord.status != .failed, taskRecord.status != .cancelled else {
                return BridgeInvokeResponse(
                    id: request.id,
                    ok: false,
                    error: OpenClawNodeError(code: .invalidRequest, message: "INVALID_REQUEST: sub agent task is not resumable")
                )
            }
            let definition = SubAgentRegistry.definition(for: taskRecord.agentType) ?? SubAgentRegistry.generalPurpose
            await spawnBackgroundWorkerIfNeeded(
                taskID: taskRecord.id,
                definition: definition,
                workspaceRootURL: workspaceRootURL,
                runtimeRootURL: activeRuntimeRootURLProvider(),
                modelConfig: modelConfig,
                sessionID: taskRecord.parentSessionID,
                toolInvoker: toolInvoker
            )
            await syncTaskMessageIfPossible(taskID: taskRecord.id, sessionID: taskRecord.parentSessionID)
            let payload = [
                "## Sub Agent Follow-up",
                "- task_id: \(taskRecord.id)",
                "- agent: \(taskRecord.agentType)",
                "- status: running",
                "- queued_prompt: \(prompt)",
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

    private static func spawnBackgroundWorkerIfNeeded(
        taskID: String,
        definition: SubAgentDefinition,
        workspaceRootURL: URL?,
        runtimeRootURL: URL?,
        modelConfig: AppConfig.LLMModel,
        sessionID: String?,
        toolInvoker: @escaping @Sendable (BridgeInvokeRequest, String?) async -> BridgeInvokeResponse
    ) async {
        let alreadyRunning = await SubAgentTaskStore.shared.hasAttachedTask(taskID: taskID)
        guard !alreadyRunning else { return }
        let task = Task { @MainActor in
            defer {
                Task {
                    await SubAgentTaskStore.shared.detach(taskID: taskID)
                }
            }
            await backgroundWorkerLoop(
                taskID: taskID,
                definition: definition,
                workspaceRootURL: workspaceRootURL,
                runtimeRootURL: runtimeRootURL,
                modelConfig: modelConfig,
                sessionID: sessionID,
                toolInvoker: toolInvoker
            )
        }
        await SubAgentTaskStore.shared.attach(task: task, for: taskID)
    }

    private static func backgroundWorkerLoop(
        taskID: String,
        definition: SubAgentDefinition,
        workspaceRootURL: URL?,
        runtimeRootURL: URL?,
        modelConfig: AppConfig.LLMModel,
        sessionID: String?,
        toolInvoker: @escaping @Sendable (BridgeInvokeRequest, String?) async -> BridgeInvokeResponse
    ) async {
        var currentPrompt: String? = nil
        if let record = await SubAgentTaskStore.shared.record(taskID: taskID),
           let restored = await SubAgentTaskStore.shared.restoreConversation(taskID: taskID),
           restored.isEmpty
        {
            currentPrompt = record.prompt
        }

        while !Task.isCancelled {
            let prompt: String?
            if let currentPrompt {
                prompt = currentPrompt
            } else {
                prompt = await SubAgentTaskStore.shared.takeNextPrompt(taskID: taskID)
            }
            currentPrompt = nil
            guard let prompt else {
                if let snapshot = await SubAgentTaskStore.shared.snapshot(taskID: taskID),
                   snapshot.record.status == .running,
                   !snapshot.record.conversation.isEmpty
                {
                    await SubAgentTaskStore.shared.markWaiting(
                        taskID: taskID,
                        result: snapshot.record.result ?? "",
                        conversation: snapshot.record.conversation,
                        summary: snapshot.progress?.summary ?? "Waiting for follow-up",
                        totalTurns: snapshot.record.totalTurns,
                        totalToolCalls: snapshot.record.totalToolCalls,
                        durationMs: snapshot.record.durationMs
                    )
                    await syncTaskMessageIfPossible(taskID: taskID, sessionID: sessionID)
                }
                break
            }

            do {
                _ = try await executeSubAgentTask(
                    taskID: taskID,
                    prompt: prompt,
                    definition: definition,
                    workspaceRootURL: workspaceRootURL,
                    runtimeRootURL: runtimeRootURL,
                    modelConfig: modelConfig,
                    sessionID: sessionID,
                    executeTool: { nestedRequest in
                        await toolInvoker(nestedRequest, sessionID)
                    },
                    completeIfNoPendingPrompts: false
                )
            } catch {
                break
            }
        }
    }

    private static func executeSubAgentTask(
        taskID: String,
        prompt: String,
        definition: SubAgentDefinition,
        workspaceRootURL: URL?,
        runtimeRootURL: URL?,
        modelConfig: AppConfig.LLMModel,
        sessionID: String?,
        executeTool: @escaping @Sendable (BridgeInvokeRequest) async -> BridgeInvokeResponse,
        completeIfNoPendingPrompts: Bool = true
    ) async throws -> SubAgentRunOutput {
        do {
            guard let record = await SubAgentTaskStore.shared.record(taskID: taskID) else {
                throw NSError(domain: "SubAgentTools", code: 404, userInfo: [NSLocalizedDescriptionKey: "Sub agent task not found."])
            }
            let restoredConversation = await SubAgentTaskStore.shared.restoreConversation(taskID: taskID)
            let output = try await SubAgentRunner.run(
                prompt: prompt,
                definition: definition,
                workspaceRootURL: workspaceRootURL,
                runtimeRootURL: runtimeRootURL,
                modelConfig: modelConfig,
                existingMessages: restoredConversation?.isEmpty == false ? restoredConversation : nil,
                existingConversation: record.conversation.isEmpty ? nil : record.conversation,
                startingTurnCount: record.totalTurns,
                startingToolCallCount: record.totalToolCalls,
                startedAt: record.createdAt,
                executeTool: executeTool,
                onProgress: { snapshot in
                    await SubAgentTaskStore.shared.updateProgress(taskID: taskID, snapshot: snapshot)
                    await syncTaskMessageIfPossible(taskID: taskID, sessionID: sessionID)
                }
            )

            let latestRecord = await SubAgentTaskStore.shared.record(taskID: taskID)
            let hasPendingFollowUps = !(latestRecord?.pendingPrompts.isEmpty ?? true)
            if completeIfNoPendingPrompts, !hasPendingFollowUps {
                await SubAgentTaskStore.shared.markCompleted(
                    taskID: taskID,
                    result: output.content,
                    conversation: output.persistedConversation,
                    summary: resultPreview(from: output.content),
                    totalTurns: output.totalTurns,
                    totalToolCalls: output.totalToolCalls,
                    durationMs: output.durationMs
                )
            } else {
                let summary = hasPendingFollowUps ? "Queued follow-up" : (resultPreview(from: output.content) ?? "Waiting for follow-up")
                await SubAgentTaskStore.shared.saveCheckpoint(
                    taskID: taskID,
                    result: output.content,
                    conversation: output.persistedConversation,
                    summary: summary,
                    totalTurns: output.totalTurns,
                    totalToolCalls: output.totalToolCalls,
                    durationMs: output.durationMs
                )
            }
            await syncTaskMessageIfPossible(taskID: taskID, sessionID: sessionID)
            return output
        } catch {
            let taskSnapshot = await SubAgentTaskStore.shared.snapshot(taskID: taskID)
            let progress = taskSnapshot?.progress
            await SubAgentTaskStore.shared.markFailed(
                taskID: taskID,
                errorDescription: error.localizedDescription,
                summary: progress?.summary ?? "Failed",
                totalTurns: progress?.totalTurns,
                totalToolCalls: progress?.totalToolCalls,
                durationMs: progress?.durationMs
            )
            await syncTaskMessageIfPossible(taskID: taskID, sessionID: sessionID)
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
            case .waiting:
                message.textContent = snapshot.record.result ?? ""
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
