import ChatClient
import ChatUI
import Foundation
import OSLog

private let teamRoomLogger = Logger(subsystem: "com.day1-labs.openava", category: "team.room")

@MainActor
final class TeamRoomOrchestrator {
    static let shared = TeamRoomOrchestrator()

    struct SubmissionContext {
        var activeContext: ActiveSessionContext
        var teams: [TeamProfile]
        var agents: [AgentProfile]
        var fallbackModelConfig: AppConfig.LLMModel?
        var agentCount: Int
    }

    struct AgentReply: Equatable {
        var agent: AgentProfile
        var text: String
        var isError: Bool
    }

    private init() {}

    @discardableResult
    func submitTeamRoomPrompt(
        roomSession: ConversationSession,
        prompt: ConversationSession.PromptInput,
        context: SubmissionContext,
        usingExistingReservation: Bool = true
    ) -> Bool {
        let turnID = UUID().uuidString
        let roomPrompt = Self.promptWithTeamRoomMetadata(prompt, context: context, turnID: turnID)
        roomSession.lastSubmittedPromptInput = roomPrompt
        roomSession.showsInterruptedRetryAction = false

        var taskToAwait: Task<Void, Never>?
        roomSession.cancelCurrentTask { [self] in
            if !usingExistingReservation {
                guard roomSession.queryGuard.reserve() else {
                    teamRoomLogger.notice("team room submit ignored session=\(roomSession.id, privacy: .public) reason=query_already_active")
                    return
                }
            }

            guard let generation = roomSession.queryGuard.tryStart() else {
                if !usingExistingReservation {
                    roomSession.queryGuard.cancelReservation()
                }
                teamRoomLogger.notice("team room submit ignored session=\(roomSession.id, privacy: .public) reason=query_already_active")
                return
            }

            let userMessage = Self.appendUserMessage(roomPrompt, to: roomSession)
            roomSession.notifyMessagesDidChange(scrolling: true)
            roomSession.recordMessageInTranscript(userMessage)

            let task = Task { @MainActor [generation] in
                teamRoomLogger.notice("team room task started session=\(roomSession.id, privacy: .public)")
                roomSession.sessionDelegate?.preventIdleTimer()
                roomSession.sessionDelegate?.sessionExecutionDidStart(for: roomSession.id)

                let backgroundToken = roomSession.sessionDelegate?.beginBackgroundTask { [weak roomSession] in
                    Task { @MainActor [weak roomSession] in
                        roomSession?.interruptCurrentTurn(reason: .backgroundExpired)
                    }
                }

                var didSucceed = true
                var errorDescription: String?

                defer {
                    if let backgroundToken {
                        roomSession.sessionDelegate?.endBackgroundTask(backgroundToken)
                    }

                    roomSession.stopThinkingForAll()
                    roomSession.setLoadingState(nil)
                    roomSession.notifyMessagesDidChange()
                    roomSession.persistMessages()

                    let persistedMessages = roomSession.messages
                    let sessionID = roomSession.id
                    Task { [sessionDelegate = roomSession.sessionDelegate] in
                        await sessionDelegate?.sessionDidPersistMessages(persistedMessages, for: sessionID)
                    }

                    if Task.isCancelled {
                        let interruptReason = roomSession.consumeInterruptReason().rawValue
                        roomSession.sessionDelegate?.sessionExecutionDidInterrupt(for: roomSession.id, reason: interruptReason)
                    } else {
                        roomSession.sessionDelegate?.sessionExecutionDidFinish(
                            for: roomSession.id,
                            success: didSucceed,
                            errorDescription: errorDescription
                        )
                    }
                    roomSession.sessionDelegate?.allowIdleTimer()

                    if roomSession.queryGuard.end(generation) {
                        roomSession.currentTask = nil
                    }
                    teamRoomLogger.notice("team room task finished session=\(roomSession.id, privacy: .public) cancelled=\(String(Task.isCancelled), privacy: .public)")
                }

                do {
                    try await runTeamTurn(
                        roomSession: roomSession,
                        context: context,
                        turnID: turnID
                    )
                } catch is CancellationError {
                    didSucceed = false
                    roomSession.showsInterruptedRetryAction = true
                } catch {
                    didSucceed = false
                    errorDescription = error.localizedDescription
                    Self.appendSystemEvent(
                        "Team Room failed: \(error.localizedDescription)",
                        to: roomSession,
                        context: context
                    )
                }
            }

            roomSession.currentTask = task
            taskToAwait = task
        }

        return taskToAwait != nil
    }

    static func resolveParticipants(
        activeContext: ActiveSessionContext,
        teams: [TeamProfile],
        agents: [AgentProfile]
    ) -> [AgentProfile] {
        switch activeContext {
        case .allAgentsTeam:
            return agents
        case let .team(teamID):
            guard let team = teams.first(where: { $0.id == teamID }) else {
                return []
            }
            return team.agentPoolIDs.compactMap { agentID in
                agents.first(where: { $0.id == agentID })
            }
        case let .agent(agentID):
            return agents.filter { $0.id == agentID }
        }
    }

    @discardableResult
    static func appendAgentReply(
        _ reply: AgentReply,
        to roomSession: ConversationSession,
        context: SubmissionContext,
        turnID: String? = nil
    ) -> ConversationMessage {
        let message = roomSession.appendNewMessage(role: .assistant) { message in
            message.textContent = reply.text
            applyAgentMetadata(
                to: message,
                agent: reply.agent,
                context: context,
                turnID: turnID,
                source: reply.isError ? "team_room_agent_error" : "team_room_agent_reply"
            )
        }
        roomSession.recordMessageInTranscript(message)
        roomSession.notifyMessagesDidChange(scrolling: true)
        return message
    }

    static func applyAgentMetadata(
        to message: ConversationMessage,
        agent: AgentProfile,
        context: SubmissionContext,
        turnID: String?,
        source: String
    ) {
        message.metadata["agentID"] = agent.id.uuidString
        message.metadata["agentName"] = agent.name
        message.metadata["agentEmoji"] = agent.emoji
        message.metadata["teamRoomContext"] = metadataContextValue(context.activeContext)
        message.metadata[ConversationSession.PromptInput.sourceMetadataKey] = source
        if let turnID {
            message.metadata["teamRoomTurnID"] = turnID
        }
        if case let .team(teamID) = context.activeContext {
            message.metadata["teamID"] = teamID.uuidString
            if let team = context.teams.first(where: { $0.id == teamID }) {
                message.metadata["teamName"] = team.name
            }
        }
    }

    private func runTeamTurn(
        roomSession: ConversationSession,
        context: SubmissionContext,
        turnID: String
    ) async throws {
        let allParticipants = Self.resolveParticipants(
            activeContext: context.activeContext,
            teams: context.teams,
            agents: context.agents
        )

        guard !allParticipants.isEmpty else {
            Self.appendSystemEvent(
                "No agents are assigned to this Team Room yet.",
                to: roomSession,
                context: context
            )
            return
        }

        let participants = await resolveAddressedParticipants(
            all: allParticipants,
            roomSession: roomSession,
            context: context,
            turnID: turnID
        )

        var didAppendReply = false
        for agent in participants {
            try Task.checkCancellation()
            roomSession.setLoadingState("Waiting for \(agent.name)…")
            let didProduceReply = try await runAgentTurn(
                agent: agent,
                roomSession: roomSession,
                context: context,
                participantCount: participants.count,
                turnID: turnID
            )
            try Task.checkCancellation()
            didAppendReply = didAppendReply || didProduceReply
        }

        if !didAppendReply {
            Self.appendSystemEvent(
                "No agent replies were produced for this Team Room turn.",
                to: roomSession,
                context: context
            )
        }
    }

    func resolveAddressedParticipants(
        all: [AgentProfile],
        roomSession: ConversationSession,
        context: SubmissionContext,
        turnID: String
    ) async -> [AgentProfile] {
        guard all.count > 1, let modelConfig = context.fallbackModelConfig else {
            return all
        }
        let userText = roomSession.messages
            .last { $0.metadata["teamRoomTurnID"] == turnID && $0.role == .user }?
            .textContent
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !userText.isEmpty else { return all }

        let addressed = await TeamMentionResolver.resolveAddressedAgents(
            userMessage: userText,
            agentNames: all.map(\.name),
            using: modelConfig
        )
        guard !addressed.isEmpty else { return all }

        let lowercased = Set(addressed.map { $0.lowercased() })
        let filtered = all.filter { lowercased.contains($0.name.lowercased()) }
        return filtered.isEmpty ? all : filtered
    }

    private func runAgentTurn(
        agent: AgentProfile,
        roomSession: ConversationSession,
        context: SubmissionContext,
        participantCount: Int,
        turnID: String
    ) async throws -> Bool {
        guard let modelConfig = resolveModelConfig(for: agent, fallback: context.fallbackModelConfig) else {
            Self.appendAgentReply(
                AgentReply(
                    agent: agent,
                    text: "I can’t reply because no configured model is available for this agent.",
                    isError: true
                ),
                to: roomSession,
                context: context,
                turnID: turnID
            )
            return true
        }

        let model = makeAgentModel(for: agent, modelConfig: modelConfig)
        let invocationSessionID = "\(agent.id.uuidString)::\(roomSession.id)"
        let toolProvider = makeAgentToolProvider(
            for: agent,
            modelConfig: modelConfig,
            invocationSessionID: invocationSessionID,
            agentCount: max(context.agentCount, participantCount)
        )
        let messageHooks = Self.agentMessageHooks(for: agent, context: context, turnID: turnID)
        let existingMessageIDs = Set(roomSession.messages.map(\.id))
        let previousSystemPromptProvider = roomSession.systemPromptProvider
        let previousModels = roomSession.models
        let agentSystemPrompt = makeAgentSystemPrompt(
            for: agent,
            modelConfig: modelConfig,
            context: context,
            participantCount: participantCount
        )
        roomSession.systemPromptProvider = { agentSystemPrompt }
        roomSession.models.chat = model
        defer {
            roomSession.systemPromptProvider = previousSystemPromptProvider
            roomSession.models = previousModels
        }

        do {
            var requestMessages = await buildAgentRequestMessages(
                roomSession: roomSession,
                capabilities: model.capabilities,
                turnID: turnID
            )
            let tools = await enabledRequestTools(for: model.capabilities, using: toolProvider)
            let toolUseContext = ToolExecutionContext(
                session: roomSession,
                toolProvider: toolProvider,
                canUseTool: defaultToolPermissionPolicy
            )

            _ = try await query(
                session: roomSession,
                model: model,
                requestMessages: &requestMessages,
                tools: tools,
                toolUseContext: toolUseContext,
                maxTurns: 32,
                querySource: .user,
                messageHooks: messageHooks
            )

            let didProduceAssistant = roomSession.messages.contains { message in
                message.role == .assistant
                    && !existingMessageIDs.contains(message.id)
                    && message.metadata["agentID"] == agent.id.uuidString
                    && message.metadata["teamRoomTurnID"] == turnID
            }

            if !didProduceAssistant {
                Self.appendAgentReply(
                    AgentReply(
                        agent: agent,
                        text: "I finished this turn without producing a visible reply.",
                        isError: true
                    ),
                    to: roomSession,
                    context: context,
                    turnID: turnID
                )
                return true
            }

            return true
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            Self.appendAgentReply(
                AgentReply(
                    agent: agent,
                    text: "I couldn’t complete this turn: \(error.localizedDescription)",
                    isError: true
                ),
                to: roomSession,
                context: context,
                turnID: turnID
            )
            return true
        }
    }

    private func resolveModelConfig(
        for agent: AgentProfile,
        fallback: AppConfig.LLMModel?
    ) -> AppConfig.LLMModel? {
        let selected = LLMConfigStore
            .loadCollection()
            .selectedModel(preferredID: agent.selectedModelID)
        if let selected, selected.isConfigured {
            return selected
        }
        if let fallback, fallback.isConfigured {
            return fallback
        }
        return nil
    }

    private func makeAgentModel(
        for agent: AgentProfile,
        modelConfig: AppConfig.LLMModel
    ) -> ConversationSession.Model {
        ConversationSession.Model(
            client: LLMChatClient(modelConfig: modelConfig),
            capabilities: [.visual, .tool],
            contextLength: modelConfig.contextTokens,
            maxOutputTokens: modelConfig.resolvedMaxOutputTokens,
            autoCompactEnabled: agent.autoCompactEnabled
        )
    }

    private func makeAgentToolProvider(
        for agent: AgentProfile,
        modelConfig: AppConfig.LLMModel,
        invocationSessionID: String,
        agentCount: Int
    ) -> ToolRegistryProvider {
        let toolRuntime = ToolRuntime.makeDefault(
            workspaceRootURL: agent.workspaceURL,
            supportRootURL: agent.contextURL,
            teamsRootURL: agent.workspaceURL,
            modelConfig: modelConfig,
            agentCount: max(agentCount, 1)
        )
        return ToolRegistryProvider(toolRuntime: toolRuntime, invocationSessionID: invocationSessionID)
    }

    private func enabledRequestTools(
        for capabilities: Set<ModelCapability>,
        using toolProvider: any ToolProvider
    ) async -> [ChatRequestBody.Tool]? {
        guard capabilities.contains(.tool) else { return nil }
        let enabledTools = await toolProvider.enabledTools()
        return enabledTools.isEmpty ? nil : enabledTools
    }

    private func buildAgentRequestMessages(
        roomSession: ConversationSession,
        capabilities: Set<ModelCapability>,
        turnID: String
    ) async -> [ChatRequestBody.Message] {
        var requestMessages = roomSession.historyMessages()
            .filter { message in
                message.metadata["teamRoomTurnID"] != turnID || message.role == .user
            }
            .flatMap { message in
                roomSession.buildRequestMessages(from: message, capabilities: capabilities)
            }

        if let instructionMessage = await roomSession.buildInstructionRequestMessage(
            for: requestMessages,
            capabilities: capabilities
        ) {
            let insertIndex = requestMessages.lastIndex { message in
                switch message {
                case .system, .developer:
                    true
                default:
                    false
                }
            }.map { $0 + 1 } ?? 0
            requestMessages.insert(instructionMessage, at: insertIndex)
        }

        return requestMessages
    }

    private func makeAgentSystemPrompt(
        for agent: AgentProfile,
        modelConfig: AppConfig.LLMModel,
        context: SubmissionContext,
        participantCount: Int
    ) -> String {
        let basePrompt = AgentContextLoader.composeSystemPrompt(
            baseSystemPrompt: modelConfig.systemPrompt,
            workspaceRootURL: agent.contextURL,
            agentCount: max(participantCount, 1)
        ) ?? modelConfig.systemPrompt ?? "You are a helpful assistant."

        let roomName: String = switch context.activeContext {
        case .allAgentsTeam:
            "Global Team Room"
        case let .team(teamID):
            context.teams.first(where: { $0.id == teamID })?.name ?? "Team Room"
        case .agent:
            "Team Room"
        }

        let participationNote = participantCount == 1
            ? "The user is addressing you directly."
            : "The user is asking the room, and \(participantCount) agent(s) may answer independently."

        let roomInstruction = """
        You are \(agent.name), replying directly in \(roomName).
        The visible conversation transcript is the single source of truth for this Team Room.
        \(participationNote)
        Do not speak as a coordinator and do not summarize other agents unless the user explicitly asks you to.
        Provide your own useful contribution as \(agent.name).
        """

        return [basePrompt, roomInstruction]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    private static func agentMessageHooks(
        for agent: AgentProfile,
        context: SubmissionContext,
        turnID: String
    ) -> QueryMessageHooks {
        QueryMessageHooks(
            configureAssistantMessage: { message in
                applyAgentMetadata(
                    to: message,
                    agent: agent,
                    context: context,
                    turnID: turnID,
                    source: "team_room_agent_reply"
                )
            },
            configureToolMessage: { message in
                applyAgentMetadata(
                    to: message,
                    agent: agent,
                    context: context,
                    turnID: turnID,
                    source: "team_room_agent_tool_result"
                )
            }
        )
    }

    private static func promptWithTeamRoomMetadata(
        _ prompt: ConversationSession.PromptInput,
        context: SubmissionContext,
        turnID: String
    ) -> ConversationSession.PromptInput {
        var metadata = prompt.metadata
        metadata["teamRoomTurnID"] = turnID
        metadata["teamRoomContext"] = metadataContextValue(context.activeContext)
        if case let .team(teamID) = context.activeContext {
            metadata["teamID"] = teamID.uuidString
            if let team = context.teams.first(where: { $0.id == teamID }) {
                metadata["teamName"] = team.name
            }
        }
        return ConversationSession.PromptInput(
            text: prompt.text,
            attachments: prompt.attachments,
            source: prompt.source,
            metadata: metadata
        )
    }

    private static func appendUserMessage(
        _ prompt: ConversationSession.PromptInput,
        to roomSession: ConversationSession
    ) -> ConversationMessage {
        roomSession.appendNewMessage(role: .user) { message in
            message.textContent = prompt.text
            for attachment in prompt.attachments {
                message.parts.append(attachment)
            }
            for (key, value) in prompt.metadata {
                message.metadata[key] = value
            }
        }
    }

    private static func appendSystemEvent(
        _ text: String,
        to roomSession: ConversationSession,
        context: SubmissionContext
    ) {
        let message = roomSession.appendNewMessage(role: .system) { message in
            message.textContent = text
            message.metadata[ConversationSession.PromptInput.sourceMetadataKey] = "team_room_system_event"
            message.metadata["teamRoomContext"] = metadataContextValue(context.activeContext)
            if case let .team(teamID) = context.activeContext {
                message.metadata["teamID"] = teamID.uuidString
            }
        }
        roomSession.recordMessageInTranscript(message)
        roomSession.notifyMessagesDidChange(scrolling: true)
    }

    private static func metadataContextValue(_ context: ActiveSessionContext) -> String {
        switch context {
        case .allAgentsTeam:
            "globalTeam"
        case let .team(teamID):
            "team:\(teamID.uuidString)"
        case let .agent(agentID):
            "agent:\(agentID.uuidString)"
        }
    }
}
