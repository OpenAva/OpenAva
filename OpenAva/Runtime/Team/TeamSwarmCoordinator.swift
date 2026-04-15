import ChatClient
import ChatUI
import Foundation
import OpenClawKit

extension Notification.Name {
    static let openAvaTeamSwarmDidChange = Notification.Name("openava.teamSwarmDidChange")
}

@MainActor
final class TeamSwarmCoordinator {
    static let shared = TeamSwarmCoordinator()

    static let coordinatorName = "coordinator"
    static let mainSessionID = "main"

    struct ToolContext {
        let sessionID: String?
        let senderMemberID: String?
    }

    enum MemberStatus: String, Codable {
        case idle
        case busy
        case awaitingPlanApproval
        case stopped
        case failed
    }

    enum TaskStatus: String, Codable, CaseIterable {
        case pending
        case inProgress = "in_progress"
        case blocked
        case completed
    }

    struct TeamTask: Codable, Identifiable, Equatable {
        let id: Int
        var title: String
        var detail: String?
        var status: TaskStatus
        var owner: String?
        var createdAt: Date
        var updatedAt: Date
    }

    struct TeamMember: Codable, Identifiable, Equatable {
        let id: String
        let name: String
        let agentType: String
        let sessionID: String
        let planModeRequired: Bool
        let permissionMode: String?
        var status: MemberStatus
        var awaitingPlanApproval: Bool
        var hasApprovedPlan: Bool
        var pendingExecutionPrompt: String?
        var pendingPlanRequestID: String?
        var lastPlan: String?
        var lastResult: String?
        var lastError: String?
        var lastUpdatedAt: Date
        var shutdownRequested: Bool
        var lastIdleSummary: String?
    }

    struct TeamRecord: Codable, Equatable {
        let name: String
        var description: String?
        let coordinatorSessionID: String
        let createdAt: Date
        var updatedAt: Date
        var hiddenPaneIDs: [String]?
        var allowedPaths: [TeamAllowedPath]?
        var nextTaskID: Int
        var members: [TeamMember]
        var tasks: [TeamTask]
    }

    struct TeamSnapshot {
        let team: TeamRecord
        let pendingPermissions: [TeamPermissionRequest]
    }

    private struct MemberExecutionSignature: Equatable {
        let teamName: String
        let memberID: String
        let memberName: String
        let invocationSessionID: String
        let workspacePath: String
        let runtimePath: String
        let agentEmoji: String
        let modelConfig: AppConfig.LLMModel
        let autoCompactEnabled: Bool
    }

    private struct MemberExecutionEnvironment {
        let signature: MemberExecutionSignature
        let storageProvider: TranscriptStorageProvider
        let delegate: TeamExecutionSessionDelegate
        let session: ConversationSession
        let messageListView: MessageListView
    }

    private let colors = ["blue", "green", "orange", "pink", "purple", "teal"]
    private var runtimeRootURL: URL?
    private var agentWorkspaceRootURL: URL?
    private var teamsByName: [String: TeamRecord] = [:]
    private var memberSignals: [String: AsyncStream<Void>.Continuation] = [:]
    private var memberTasks: [String: Task<Void, Never>] = [:]
    private var memberExecutionEnvironments: [String: MemberExecutionEnvironment] = [:]
    private var loadedConfigurationSignature: String?

    private init() {}

    func configure(
        runtimeRootURL: URL?,
        workspaceRootURL: URL?,
        modelConfig _: AppConfig.LLMModel?,
        executeTool _: (@Sendable (String, String, String?, BridgeInvokeRequest) async -> BridgeInvokeResponse)? = nil
    ) {
        let normalizedRuntimeRootURL = runtimeRootURL?.standardizedFileURL
        let normalizedAgentWorkspaceRootURL = workspaceRootURL?.standardizedFileURL
        let configurationSignature = [
            normalizedRuntimeRootURL?.path ?? "",
            normalizedAgentWorkspaceRootURL?.path ?? "",
        ].joined(separator: "|")
        if loadedConfigurationSignature != configurationSignature {
            loadedConfigurationSignature = configurationSignature
            self.runtimeRootURL = normalizedRuntimeRootURL
            self.agentWorkspaceRootURL = normalizedAgentWorkspaceRootURL
            loadPersistedTeams()
        } else {
            self.runtimeRootURL = normalizedRuntimeRootURL
            self.agentWorkspaceRootURL = normalizedAgentWorkspaceRootURL
        }
    }

    func reload() {
        loadPersistedTeams()
        notifyChanged()
    }

    struct TeamMenuSnapshot {
        let busyCount: Int
        let pendingApprovalCount: Int
        let failedCount: Int
        let activeTaskCount: Int
        let memberStatuses: [String: MemberStatus]
        let memberSummaries: [String: String]
    }

    func menuSnapshot(teamName: String) -> TeamMenuSnapshot? {
        guard let team = teamsByName[teamName] else { return nil }
        let pending = pendingPermissions(for: teamName)
        var statuses: [String: MemberStatus] = [:]
        var summaries: [String: String] = [:]
        for member in team.members {
            statuses[member.id] = member.status
            if let summary = member.lastIdleSummary ?? member.lastError {
                summaries[member.id] = summary
            }
        }
        return TeamMenuSnapshot(
            busyCount: team.members.filter { $0.status == .busy }.count,
            pendingApprovalCount: pending.count,
            failedCount: team.members.filter { $0.status == .failed }.count,
            activeTaskCount: team.tasks.filter { $0.status == .inProgress || $0.status == .pending }.count,
            memberStatuses: statuses,
            memberSummaries: summaries
        )
    }

    func snapshot(teamName: String? = nil, context: ToolContext) -> TeamSnapshot? {
        guard let resolvedTeamName = resolveTeamName(explicitTeamName: teamName, context: context),
              let team = teamsByName[resolvedTeamName]
        else {
            return nil
        }
        return TeamSnapshot(
            team: team,
            pendingPermissions: pendingPermissions(for: resolvedTeamName)
        )
    }

    func pendingPermissions(teamName: String?, context: ToolContext) -> [TeamPermissionRequest] {
        guard let resolvedTeamName = resolveTeamName(explicitTeamName: teamName, context: context) else { return [] }
        return pendingPermissions(for: resolvedTeamName)
    }

    func sendMessage(
        to rawTarget: String,
        message: String,
        messageType: String,
        teamName: String?,
        context: ToolContext
    ) throws {
        guard let resolvedTeamName = resolveTeamName(explicitTeamName: teamName, context: context),
              let team = teamsByName[resolvedTeamName]
        else {
            throw TeamError("TEAM_NOT_FOUND")
        }
        let body = normalized(message) ?? ""
        guard !body.isEmpty else {
            throw TeamError("INVALID_REQUEST: message must not be empty")
        }
        let target = sanitize(rawTarget)
        let senderName = senderName(for: context, teamName: resolvedTeamName) ?? Self.coordinatorName
        let isPeerMessage = senderName.caseInsensitiveCompare(Self.coordinatorName) != .orderedSame

        if target.caseInsensitiveCompare(Self.coordinatorName) == .orderedSame {
            enqueuePendingTeamMessage(
                teamName: resolvedTeamName,
                recipientName: Self.coordinatorName,
                fromName: senderName,
                text: body,
                messageType: messageType,
                summary: summarize(body)
            )
            appendCoordinatorMessage(team: team, fromName: senderName, text: body)
            return
        }

        guard let member = team.members.first(where: { $0.name.caseInsensitiveCompare(target) == .orderedSame }) else {
            throw TeamError("TEAMMATE_NOT_FOUND: \(target)")
        }

        if member.awaitingPlanApproval, messageType != "approved_execution", messageType != "shutdown_request" {
            updateMember(teamName: resolvedTeamName, memberID: member.id) { member in
                let merged = [
                    member.pendingExecutionPrompt,
                    "Additional message from \(senderName): \(body)",
                ].compactMap { $0 }.joined(separator: "\n\n")
                member.pendingExecutionPrompt = merged
                member.lastUpdatedAt = Date()
            }
            if isPeerMessage {
                registerPeerSummary(teamName: resolvedTeamName, senderMemberID: context.senderMemberID, recipientName: member.name, message: body)
            }
            persist()
            notifyChanged()
            return
        }

        if messageType == "shutdown_request" {
            markMemberShutdownRequested(teamName: resolvedTeamName, memberID: member.id)
        }
        enqueuePendingTeamMessage(
            teamName: resolvedTeamName,
            recipientName: member.name,
            fromName: senderName,
            text: body,
            messageType: messageType,
            summary: summarize(body)
        )
        markMemberBusy(teamName: resolvedTeamName, memberID: member.id)
        ensureMemberWorker(member: member)
        if isPeerMessage {
            registerPeerSummary(teamName: resolvedTeamName, senderMemberID: context.senderMemberID, recipientName: member.name, message: body)
        }
        memberSignals[member.id]?.yield()
        persist()
        notifyChanged()
    }

    func approvePlan(sessionID: String?, memberName: String?, teamName: String?, feedback: String?, context: ToolContext) throws -> TeamMember {
        guard let target = resolveMember(sessionID: sessionID, memberName: memberName, teamName: teamName, context: context) else {
            throw TeamError("TEAMMATE_NOT_FOUND")
        }
        guard var team = teamsByName[target.teamName],
              let index = team.members.firstIndex(where: { $0.id == target.member.id })
        else {
            throw TeamError("TEAM_NOT_FOUND")
        }
        var member = team.members[index]
        guard member.awaitingPlanApproval else {
            throw TeamError("PLAN_NOT_PENDING")
        }
        member.awaitingPlanApproval = false
        member.hasApprovedPlan = true
        member.status = .busy
        member.lastUpdatedAt = Date()
        let pendingPlanRequestID = member.pendingPlanRequestID
        let pendingPrompt = member.pendingExecutionPrompt
        member.pendingExecutionPrompt = nil
        member.pendingPlanRequestID = nil
        team.members[index] = member
        team.updatedAt = Date()
        teamsByName[target.teamName] = team

        if let pendingPlanRequestID,
           let teamDirectoryURL = teamDirectoryURL(teamName: target.teamName)
        {
            _ = try? TeamPermissionSync.resolve(
                teamDirectoryURL: teamDirectoryURL,
                requestID: pendingPlanRequestID,
                resolution: TeamPermissionResolution(
                    status: .approved,
                    resolvedBy: senderName(for: context, teamName: target.teamName) ?? Self.coordinatorName,
                    feedback: normalized(feedback)
                )
            )
        }

        if let pendingPrompt {
            let feedbackLine = normalized(feedback).map { "\n\nCoordinator feedback: \($0)" } ?? ""
            enqueuePendingTeamMessage(
                teamName: target.teamName,
                recipientName: member.name,
                fromName: Self.coordinatorName,
                text: pendingPrompt + feedbackLine,
                messageType: "approved_execution",
                summary: summarize(pendingPrompt)
            )
            markMemberBusy(teamName: target.teamName, memberID: member.id)
            ensureMemberWorker(member: member)
            memberSignals[member.id]?.yield()
        }
        appendTranscriptMessage(
            role: .system,
            text: "Plan approved by \(senderName(for: context, teamName: target.teamName) ?? Self.coordinatorName)."
        )
        persist()
        notifyChanged()
        return member
    }

    func createTask(title: String, detail: String?, teamName: String?, context: ToolContext) throws -> TeamTask {
        guard let resolvedTeamName = resolveTeamName(explicitTeamName: teamName, context: context),
              var team = teamsByName[resolvedTeamName]
        else {
            throw TeamError("TEAM_NOT_FOUND")
        }
        let normalizedTitle = normalized(title) ?? ""
        guard !normalizedTitle.isEmpty else {
            throw TeamError("INVALID_REQUEST: title must not be empty")
        }
        let now = Date()
        let task = TeamTask(
            id: team.nextTaskID,
            title: normalizedTitle,
            detail: normalized(detail),
            status: .pending,
            owner: nil,
            createdAt: now,
            updatedAt: now
        )
        team.nextTaskID += 1
        team.tasks.append(task)
        team.updatedAt = now
        teamsByName[resolvedTeamName] = team
        persist()
        notifyChanged()
        return task
    }

    func listTasks(teamName: String?, context: ToolContext) throws -> [TeamTask] {
        guard let resolvedTeamName = resolveTeamName(explicitTeamName: teamName, context: context),
              let team = teamsByName[resolvedTeamName]
        else {
            throw TeamError("TEAM_NOT_FOUND")
        }
        return team.tasks.sorted { $0.id < $1.id }
    }

    func getTask(id: Int, teamName: String?, context: ToolContext) throws -> TeamTask {
        guard let resolvedTeamName = resolveTeamName(explicitTeamName: teamName, context: context),
              let team = teamsByName[resolvedTeamName],
              let task = team.tasks.first(where: { $0.id == id })
        else {
            throw TeamError("TASK_NOT_FOUND")
        }
        return task
    }

    func updateTask(
        id: Int,
        teamName: String?,
        title: String?,
        detail: String?,
        status: TaskStatus?,
        owner: String?,
        context: ToolContext
    ) throws -> TeamTask {
        guard let resolvedTeamName = resolveTeamName(explicitTeamName: teamName, context: context),
              var team = teamsByName[resolvedTeamName],
              let index = team.tasks.firstIndex(where: { $0.id == id })
        else {
            throw TeamError("TASK_NOT_FOUND")
        }
        var task = team.tasks[index]
        if let title = normalized(title) {
            task.title = title
        }
        if let detail {
            task.detail = normalized(detail)
        }
        if let status {
            task.status = status
        }
        if let owner {
            task.owner = normalized(owner)
        }
        task.updatedAt = Date()
        team.tasks[index] = task
        team.updatedAt = task.updatedAt
        teamsByName[resolvedTeamName] = team
        persist()
        notifyChanged()
        return task
    }

    private func runMemberLoop(
        memberID: String,
        signalStream: AsyncStream<Void>
    ) async {
        if await processPendingTeamMessages(memberID: memberID) == false {
            return
        }

        for await _ in signalStream {
            if await processPendingTeamMessages(memberID: memberID) == false {
                break
            }
        }
    }

    private func processPendingTeamMessages(memberID: String) async -> Bool {
        guard let resolved = resolveMember(memberID: memberID),
              let teamDirectoryURL = teamDirectoryURL(teamName: resolved.teamName)
        else {
            return true
        }

        let pendingMessages = TeamMailbox.unreadMessages(teamDirectoryURL: teamDirectoryURL, recipientName: resolved.member.name)
        guard !pendingMessages.isEmpty else {
            return true
        }

        for message in pendingMessages {
            guard let current = resolveMember(memberID: memberID) else {
                break
            }

            if message.messageType == "shutdown_request" {
                try? TeamMailbox.markRead(teamDirectoryURL: teamDirectoryURL, recipientName: current.member.name, messageIDs: [message.id])
                finishMember(teamName: current.teamName, memberID: memberID, status: .stopped, result: "Shutdown requested.", error: nil)
                appendTranscriptMessage(role: .system, text: "Teammate stopped.")
                return false
            }

            if current.member.planModeRequired, !current.member.hasApprovedPlan, message.messageType != "approved_execution" {
                await runPlanStep(teamName: current.teamName, member: current.member, pendingMessage: message)
            } else {
                await runExecutionStep(teamName: current.teamName, member: current.member, pendingMessage: message)
            }

            try? TeamMailbox.markRead(teamDirectoryURL: teamDirectoryURL, recipientName: current.member.name, messageIDs: [message.id])
        }

        return true
    }

    private func runPlanStep(teamName: String, member: TeamMember, pendingMessage: TeamMailboxMessage) async {
        updateMember(teamName: teamName, memberID: member.id) { member in
            member.status = .awaitingPlanApproval
            member.awaitingPlanApproval = true
            member.pendingExecutionPrompt = pendingMessage.text
            member.lastResult = nil
            member.lastError = nil
            member.lastUpdatedAt = Date()
        }

        do {
            let output = try await performMemberTurn(
                teamName: teamName,
                member: member,
                prompt: planningPrompt(teamName: teamName, member: member, pendingMessage: pendingMessage)
            )
            let planRequestID = persistPlanApprovalRequest(teamName: teamName, member: member, plan: output)
            updateMember(teamName: teamName, memberID: member.id) { member in
                member.lastPlan = output
                member.lastResult = output
                member.lastError = nil
                member.pendingPlanRequestID = planRequestID
                member.lastUpdatedAt = Date()
            }
            if let team = teamsByName[teamName] {
                appendCoordinatorMessage(
                    team: team,
                    fromName: member.name,
                    text: "Proposed a plan and is waiting for approval.\n\n\(output)"
                )
            }
            persist()
            notifyChanged()
        } catch {
            finishMember(teamName: teamName, memberID: member.id, status: .failed, result: nil, error: error.localizedDescription)
        }
    }

    private func runExecutionStep(
        teamName: String,
        member: TeamMember,
        pendingMessage: TeamMailboxMessage
    ) async {
        updateMember(teamName: teamName, memberID: member.id) { member in
            member.status = .busy
            member.lastUpdatedAt = Date()
            member.lastResult = nil
            member.lastError = nil
        }

        let prompt = executionPrompt(teamName: teamName, member: member, pendingMessage: pendingMessage)
        do {
            let output = try await performMemberTurn(
                teamName: teamName,
                member: member,
                prompt: prompt
            )
            finishMember(teamName: teamName, memberID: member.id, status: .idle, result: output, error: nil)
            if let team = teamsByName[teamName] {
                appendCoordinatorMessage(team: team, fromName: member.name, text: output)
            }
        } catch {
            finishMember(teamName: teamName, memberID: member.id, status: .failed, result: nil, error: error.localizedDescription)
        }
    }

    private func executionPrompt(
        teamName: String,
        member: TeamMember,
        pendingMessage: TeamMailboxMessage
    ) -> String {
        let taskLines = teamsByName[teamName]?.tasks.sorted { $0.id < $1.id }.map { task in
            let owner = task.owner ?? "unassigned"
            return "- [#\(task.id)] \(task.status.rawValue) | owner=\(owner) | \(task.title)"
        }.joined(separator: "\n") ?? "- no tasks"
        return """
        Team execution instructions:
        Work directly in this main conversation so your execution history is preserved here.
        Use the same standard toolset available to the runtime; team membership does not change tool availability.
        Coordinate with the coordinator or peers via `team_message_send` when useful.
        Use `team_task_list` / `team_task_update` to keep the team state accurate.
        Do not create nested teams.

        You are teammate \(member.name) inside team \(teamName).

        Current team task list:
        \(taskLines)

        Latest message from \(pendingMessage.from):
        \(pendingMessage.text)
        """
    }

    private func planningPrompt(teamName: String, member: TeamMember, pendingMessage: TeamMailboxMessage) -> String {
        let taskLines = teamsByName[teamName]?.tasks.sorted { $0.id < $1.id }.map { task in
            let owner = task.owner ?? "unassigned"
            return "- [#\(task.id)] \(task.status.rawValue) | owner=\(owner) | \(task.title)"
        }.joined(separator: "\n") ?? "- no tasks"
        return """
        Team planning instructions:
        Think and reply in this main conversation so the planning trace is preserved here.
        Keep the plan grounded in the current team state and assigned work.
        Prefer to produce the plan directly from the available context.
        If a tool is truly necessary to avoid guessing, use it deliberately and then return to the plan.
        Do not claim the work is already done.
        Return only the plan that should be approved by the coordinator.

        You are teammate \(member.name) inside team \(teamName).

        Current team task list:
        \(taskLines)

        Assigned work from \(pendingMessage.from):
        \(pendingMessage.text)
        """
    }

    private func performMemberTurn(
        teamName: String,
        member: TeamMember,
        prompt: String
    ) async throws -> String {
        let environment = try memberExecutionEnvironment(teamName: teamName, member: member)
        guard let model = environment.session.models.chat else {
            throw TeamError("TEAMMATE_MODEL_NOT_CONFIGURED: \(member.name)")
        }

        let baselineMessageIDs = Set(environment.storageProvider.messages(in: Self.mainSessionID).map(\.id))
        environment.delegate.prepareForTurn()

        environment.session.refreshContentsFromDatabase(scrolling: false)
        let input = ConversationSession.UserInput(text: prompt)
        await withCheckedContinuation { continuation in
            environment.session.runInference(
                model: model,
                messageListView: environment.messageListView,
                input: input
            ) {
                continuation.resume()
            }
        }

        let outcome = environment.delegate.consumeOutcome()
        let latestAssistantText = AppConfig.nonEmpty(
            environment.storageProvider.messages(in: Self.mainSessionID)
                .filter { $0.role == .assistant && !baselineMessageIDs.contains($0.id) }
                .last?
                .textContent
        )

        if outcome?.success == false {
            throw TeamError(outcome?.errorDescription ?? "Member execution failed.")
        }
        return latestAssistantText ?? "Completed without a textual final response."
    }

    private func memberExecutionEnvironment(
        teamName: String,
        member: TeamMember
    ) throws -> MemberExecutionEnvironment {
        let agent = try agentProfile(for: member)
        let modelConfig = try resolvedModelConfig(for: agent, memberName: member.name)
        let signature = MemberExecutionSignature(
            teamName: teamName,
            memberID: member.id,
            memberName: member.name,
            invocationSessionID: member.sessionID,
            workspacePath: agent.workspacePath,
            runtimePath: agent.localRuntimePath,
            agentEmoji: agent.emoji,
            modelConfig: modelConfig,
            autoCompactEnabled: agent.autoCompactEnabled
        )

        if let cached = memberExecutionEnvironments[member.id], cached.signature == signature {
            return cached
        }

        let chatClient = LLMChatClient(modelConfig: modelConfig)
        let storageProvider = TranscriptStorageProvider.provider(runtimeRootURL: agent.runtimeURL)
        let storage = TeamSessionStorageProvider(base: storageProvider)
        let toolRuntime = ToolRuntime.makeDefault(
            workspaceRootURL: agent.workspaceURL,
            runtimeRootURL: agent.runtimeURL,
            modelConfig: modelConfig,
            configureTeamSwarm: false
        )
        let toolProvider = ToolRegistryProvider(toolRuntime: toolRuntime, invocationSessionID: member.sessionID)
        let systemPrompt = teamSessionSystemPrompt(teamName: teamName, member: member)
        let delegate = TeamExecutionSessionDelegate(
            base: AgentSessionDelegate(
                sessionID: Self.mainSessionID,
                workspaceRootURL: agent.workspaceURL,
                runtimeRootURL: agent.runtimeURL,
                baseSystemPrompt: systemPrompt,
                chatClient: chatClient,
                agentName: member.name,
                agentEmoji: agent.emoji,
                shouldExtractDurableMemory: false
            )
        )
        let sessionConfiguration = ConversationSession.Configuration(
            storage: storage,
            tools: toolProvider,
            delegate: delegate,
            systemPrompt: systemPrompt,
            collapseReasoningWhenComplete: true
        )
        let session = ConversationSessionManager.shared.session(for: Self.mainSessionID, configuration: sessionConfiguration)
        session.models = ConversationSession.Models(
            chat: ConversationSession.Model(
                client: chatClient,
                capabilities: [.visual, .tool],
                contextLength: modelConfig.contextTokens,
                autoCompactEnabled: agent.autoCompactEnabled
            )
        )

        let environment = MemberExecutionEnvironment(
            signature: signature,
            storageProvider: storageProvider,
            delegate: delegate,
            session: session,
            messageListView: MessageListView()
        )
        memberExecutionEnvironments[member.id] = environment
        return environment
    }

    private func agentProfile(for member: TeamMember) throws -> AgentProfile {
        guard let memberUUID = UUID(uuidString: member.id),
              let agent = AgentStore.load(workspaceRootURL: agentWorkspaceRootURL).agents.first(where: { $0.id == memberUUID })
        else {
            throw TeamError("TEAMMATE_AGENT_NOT_FOUND: \(member.name)")
        }
        return agent
    }

    private func resolvedModelConfig(for agent: AgentProfile, memberName: String) throws -> AppConfig.LLMModel {
        guard let modelConfig = LLMConfigStore.loadCollection().selectedModel(preferredID: agent.selectedModelID),
              modelConfig.isConfigured
        else {
            throw TeamError("TEAMMATE_MODEL_NOT_CONFIGURED: \(memberName)")
        }
        return modelConfig
    }

    private func teamSessionSystemPrompt(teamName: String, member: TeamMember) -> String {
        """
        You are teammate \(member.name) inside the OpenAva team \(teamName).

        This session is the teammate's primary conversation. All planning and execution for delegated team work must happen here so the execution record remains visible in this transcript.

        You have access to the same standard runtime toolset as other teammates in this session. Team roles do not change tool availability.
        Coordinate with the coordinator or peers via `team_message_send` when useful.
        Keep team tasks up to date with `team_task_list` and `team_task_update`.
        Do not create nested teams.
        """
    }

    private func finishMember(teamName: String, memberID: String, status: MemberStatus, result: String?, error: String?) {
        updateMember(teamName: teamName, memberID: memberID) { member in
            member.status = status
            member.lastResult = result ?? member.lastResult
            member.lastError = error
            member.lastUpdatedAt = Date()
            if status == .idle {
                member.lastIdleSummary = summarize(result)
            }
            if status == .stopped {
                member.shutdownRequested = true
            }
        }
        if let resolved = resolveMember(memberID: memberID) {
            if let error {
                appendTranscriptMessage(role: .system, text: "Error: \(error)")
                if let team = teamsByName[teamName] {
                    appendCoordinatorMessage(team: team, fromName: resolved.member.name, text: "Failed: \(error)")
                }
            } else if status == .idle {
                appendTranscriptMessage(role: .system, text: "Teammate is idle.")
                if let team = teamsByName[teamName] {
                    let summary = summarize(result) ?? "No summary available."
                    appendCoordinatorMessage(team: team, fromName: resolved.member.name, text: "Idle update: \(summary)")
                }
            }
        }
        persist()
        notifyChanged()
    }

    private func registerPeerSummary(teamName: String, senderMemberID: String?, recipientName: String, message: String) {
        guard let senderMemberID else { return }
        if let team = teamsByName[teamName],
           let sender = resolveMember(memberID: senderMemberID)?.member.name
        {
            appendCoordinatorMessage(team: team, fromName: sender, text: "Peer DM to \(recipientName): \(summarize(message) ?? message)")
        }
    }

    private func markMemberShutdownRequested(teamName: String, memberID: String) {
        updateMember(teamName: teamName, memberID: memberID) { member in
            member.shutdownRequested = true
            member.lastUpdatedAt = Date()
        }
    }

    private func enqueuePendingTeamMessage(
        teamName: String,
        recipientName: String,
        fromName: String,
        text: String,
        messageType: String,
        summary: String?
    ) {
        guard let teamDirectoryURL = teamDirectoryURL(teamName: teamName) else { return }
        let message = TeamMailboxMessage(
            id: UUID().uuidString,
            from: fromName,
            text: text,
            timestamp: Date(),
            read: false,
            color: resolveColor(for: fromName, teamName: teamName),
            summary: summary,
            messageType: messageType
        )
        try? TeamMailbox.append(teamDirectoryURL: teamDirectoryURL, recipientName: recipientName, message: message)
    }

    private func markMemberBusy(teamName: String, memberID: String) {
        updateMember(teamName: teamName, memberID: memberID) { member in
            member.lastUpdatedAt = Date()
            member.status = .busy
        }
    }

    private func persistPlanApprovalRequest(teamName: String, member: TeamMember, plan: String) -> String? {
        guard let teamDirectoryURL = teamDirectoryURL(teamName: teamName) else { return nil }
        let request = TeamPermissionRequest(
            id: UUID().uuidString,
            kind: "plan_execution",
            workerID: member.id,
            workerName: member.name,
            teamName: teamName,
            toolName: "team.plan.approve",
            description: summarize(plan, limit: 280) ?? "Plan approval requested.",
            inputJSON: nil,
            status: .pending,
            resolvedBy: nil,
            resolvedAt: nil,
            feedback: nil,
            createdAt: Date()
        )
        _ = try? TeamPermissionSync.writePending(teamDirectoryURL: teamDirectoryURL, request: request)
        return request.id
    }

    private func pendingPermissions(for teamName: String) -> [TeamPermissionRequest] {
        guard let teamDirectoryURL = teamDirectoryURL(teamName: teamName) else { return [] }
        return TeamPermissionSync.readPending(teamDirectoryURL: teamDirectoryURL)
    }

    private func resolveColor(for senderName: String, teamName: String) -> String? {
        guard senderName.caseInsensitiveCompare(Self.coordinatorName) != .orderedSame else {
            return nil
        }
        guard let index = teamsByName[teamName]?.members.firstIndex(where: {
            $0.name.caseInsensitiveCompare(senderName) == .orderedSame
        }) else {
            return nil
        }
        return color(forMemberAt: index)
    }

    private func color(forMemberAt index: Int) -> String? {
        guard !colors.isEmpty else { return nil }
        return colors[index % colors.count]
    }

    private func appendCoordinatorMessage(team: TeamRecord, fromName: String, text: String) {
        appendTranscriptMessage(role: .system, text: "[\(team.name)/\(fromName)] \(text)")
        notifyChanged()
    }

    private func appendTranscriptMessage(
        role: MessageRole,
        text: String
    ) {
        guard let runtimeRootURL else { return }
        let provider = TranscriptStorageProvider.provider(runtimeRootURL: runtimeRootURL)
        let existing = provider.messages(in: Self.mainSessionID)
        let message = provider.createMessage(in: Self.mainSessionID, role: role)
        message.textContent = text
        provider.save(existing + [message])
    }

    private func updateMember(teamName: String, memberID: String, mutate: (inout TeamMember) -> Void) {
        guard var team = teamsByName[teamName],
              let index = team.members.firstIndex(where: { $0.id == memberID })
        else {
            return
        }
        var member = team.members[index]
        mutate(&member)
        team.members[index] = member
        team.updatedAt = Date()
        teamsByName[teamName] = team
    }

    private func ensureMemberWorker(member: TeamMember) {
        guard memberTasks[member.id] == nil else {
            return
        }

        let memberID = member.id
        let signalStream = AsyncStream<Void> { continuation in
            memberSignals[memberID] = continuation
        }

        let workerTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await runMemberLoop(memberID: memberID, signalStream: signalStream)
            memberTasks.removeValue(forKey: memberID)
            memberSignals.removeValue(forKey: memberID)
        }

        memberTasks[memberID] = workerTask
        memberSignals[memberID]?.yield()
    }

    private func resolveTeamName(explicitTeamName: String?, context: ToolContext) -> String? {
        if let explicitTeamName = normalized(explicitTeamName), teamsByName[explicitTeamName] != nil {
            return explicitTeamName
        }
        if let senderMemberID = context.senderMemberID,
           let resolved = resolveMember(memberID: senderMemberID)
        {
            return resolved.teamName
        }
        if let sessionID = context.sessionID {
            if let matchedBySession = teamsByName.values.first(where: { $0.coordinatorSessionID == sessionID })?.name {
                return matchedBySession
            }
            if let activeAgentID = activeAgentID(from: sessionID) {
                return teamsByName.values.first(where: {
                    $0.members.contains(where: { $0.id == activeAgentID })
                })?.name
            }
        }
        return nil
    }

    private func resolveMember(memberID: String) -> (teamName: String, member: TeamMember)? {
        for (teamName, team) in teamsByName {
            if let member = team.members.first(where: { $0.id == memberID }) {
                return (teamName, member)
            }
        }
        return nil
    }

    private func resolveMember(
        sessionID: String?,
        memberName: String?,
        teamName: String?,
        context: ToolContext
    ) -> (teamName: String, member: TeamMember)? {
        if let sessionID {
            for (teamName, team) in teamsByName {
                if let member = team.members.first(where: { $0.sessionID == sessionID }) {
                    return (teamName, member)
                }
            }
        }
        guard let resolvedTeamName = resolveTeamName(explicitTeamName: teamName, context: context),
              let team = teamsByName[resolvedTeamName],
              let memberName = normalized(memberName),
              let member = team.members.first(where: { $0.name.caseInsensitiveCompare(memberName) == .orderedSame })
        else {
            return nil
        }
        return (resolvedTeamName, member)
    }

    private func senderName(for context: ToolContext, teamName: String) -> String? {
        if let senderMemberID = context.senderMemberID,
           let resolved = resolveMember(memberID: senderMemberID),
           resolved.teamName == teamName
        {
            return resolved.member.name
        }
        if let sessionID = context.sessionID,
           let senderMemberID = activeAgentID(from: sessionID),
           let resolved = resolveMember(memberID: senderMemberID),
           resolved.teamName == teamName
        {
            return resolved.member.name
        }
        return Self.coordinatorName
    }

    private func activeAgentID(from sessionID: String) -> String? {
        guard let separatorRange = sessionID.range(of: "::") else { return nil }
        let rawValue = String(sessionID[..<separatorRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        return rawValue.isEmpty || rawValue == "global" ? nil : rawValue
    }

    private func teammateInvocationSessionID(memberID: String) -> String {
        "\(memberID)::\(Self.mainSessionID)"
    }

    private func persist() {
        synchronizeTeamDirectories()
    }

    private func loadPersistedTeams() {
        memberSignals.removeAll()
        memberTasks.values.forEach { $0.cancel() }
        memberTasks.removeAll()
        memberExecutionEnvironments.removeAll()

        let persistedFiles = loadTeamFilesFromDirectories() ?? [:]
        let teamProfiles = TeamStore.load().teams
        let agentByID = Dictionary(uniqueKeysWithValues: AgentStore.load(workspaceRootURL: agentWorkspaceRootURL).agents.map { ($0.id, $0) })
        let loadedTeams = teamProfiles.compactMap { teamRecord(for: $0, persisted: persistedFiles[$0.name], agentByID: agentByID) }

        guard !loadedTeams.isEmpty else {
            teamsByName.removeAll()
            purgeLegacyTeamTranscriptSessions(sessionIDs: [])
            return
        }

        teamsByName = Dictionary(uniqueKeysWithValues: loadedTeams.map { record in
            var team = record
            team.members = team.members.map { member in
                var member = member
                member.status = .stopped
                member.awaitingPlanApproval = member.pendingPlanRequestID != nil
                return member
            }
            return (team.name, team)
        })
        let legacySessionIDs = teamsByName.values.flatMap { team in
            [team.coordinatorSessionID] + team.members.map(\.sessionID)
        }
        purgeLegacyTeamTranscriptSessions(sessionIDs: legacySessionIDs)
    }

    private func purgeLegacyTeamTranscriptSessions(sessionIDs: [String]) {
        guard let runtimeRootURL else { return }
        let removable = Set(sessionIDs.filter { $0 != Self.mainSessionID })
        guard !removable.isEmpty else { return }
        TranscriptStorageProvider
            .provider(runtimeRootURL: runtimeRootURL)
            .removeSessions(Array(removable))
    }

    private func synchronizeTeamDirectories() {
        guard let rootURL = teamRootURL else { return }
        try? FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let currentNames = Set(teamsByName.keys)
        if let existingURLs = try? FileManager.default.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil) {
            for url in existingURLs where !currentNames.contains(url.lastPathComponent) {
                try? FileManager.default.removeItem(at: url)
            }
        }

        for team in teamsByName.values {
            guard let directoryURL = teamDirectoryURL(teamName: team.name) else { continue }
            try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let teamFile = TeamFile(
                name: team.name,
                description: team.description,
                createdAt: team.createdAt,
                updatedAt: team.updatedAt,
                coordinatorId: "\(Self.coordinatorName)@\(team.name)",
                coordinatorSessionId: team.coordinatorSessionID,
                hiddenPaneIds: team.hiddenPaneIDs ?? [],
                teamAllowedPaths: team.allowedPaths ?? [],
                nextTaskID: team.nextTaskID,
                tasks: team.tasks,
                members: team.members.map { member in
                    TeamFileMember(
                        agentId: member.id,
                        agentType: member.agentType,
                        prompt: member.pendingExecutionPrompt,
                        planModeRequired: member.planModeRequired,
                        sessionId: member.sessionID,
                        mode: member.permissionMode,
                        lastStatus: member.status.rawValue,
                        pendingPlanRequestID: member.pendingPlanRequestID
                    )
                }
            )
            guard let data = try? JSONEncoder().encode(teamFile) else { continue }
            try? data.write(to: directoryURL.appendingPathComponent("config.json", isDirectory: false), options: [.atomic])
        }
    }

    private func loadTeamFilesFromDirectories() -> [String: TeamFile]? {
        guard let rootURL = teamRootURL,
              let directoryURLs = try? FileManager.default.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil)
        else {
            return nil
        }

        let files = directoryURLs.compactMap { url -> TeamFile? in
            let configURL = url.appendingPathComponent("config.json", isDirectory: false)
            guard let data = try? Data(contentsOf: configURL),
                  let teamFile = try? JSONDecoder().decode(TeamFile.self, from: data)
            else {
                return nil
            }
            return teamFile
        }

        guard !files.isEmpty else { return nil }
        return Dictionary(uniqueKeysWithValues: files.map { ($0.name, $0) })
    }

    private func teamRecord(
        for profile: TeamProfile,
        persisted: TeamFile?,
        agentByID: [UUID: AgentProfile]
    ) -> TeamRecord? {
        let members = profile.agentPoolIDs.compactMap { agentID -> TeamMember? in
            guard let agent = agentByID[agentID] else { return nil }
            let persistedMember = persisted?.members.first(where: { $0.agentId == agentID.uuidString })
            return TeamMember(
                id: agentID.uuidString,
                name: agent.name,
                agentType: persistedMember?.agentType ?? SubAgentRegistry.generalPurpose.agentType,
                sessionID: persistedMember?.sessionId ?? teammateInvocationSessionID(memberID: agentID.uuidString),
                planModeRequired: persistedMember?.planModeRequired ?? false,
                permissionMode: persistedMember?.mode,
                status: MemberStatus(rawValue: persistedMember?.lastStatus ?? "stopped") ?? .stopped,
                awaitingPlanApproval: persistedMember?.pendingPlanRequestID != nil,
                hasApprovedPlan: (persistedMember?.planModeRequired ?? false) ? persistedMember?.pendingPlanRequestID == nil : true,
                pendingExecutionPrompt: persistedMember?.prompt,
                pendingPlanRequestID: persistedMember?.pendingPlanRequestID,
                lastPlan: nil,
                lastResult: nil,
                lastError: nil,
                lastUpdatedAt: persisted?.updatedAt ?? profile.updatedAt,
                shutdownRequested: false,
                lastIdleSummary: nil
            )
        }

        guard !members.isEmpty else { return nil }
        let coordinatorSessionID = persisted?.coordinatorSessionId ?? profile.name

        return TeamRecord(
            name: profile.name,
            description: normalized(profile.description),
            coordinatorSessionID: coordinatorSessionID,
            createdAt: persisted?.createdAt ?? profile.createdAt,
            updatedAt: persisted?.updatedAt ?? profile.updatedAt,
            hiddenPaneIDs: persisted?.hiddenPaneIds ?? [],
            allowedPaths: persisted?.teamAllowedPaths ?? [],
            nextTaskID: max(persisted?.nextTaskID ?? 1, 1),
            members: members,
            tasks: persisted?.tasks ?? []
        )
    }

    private var teamRootURL: URL? {
        TeamStore.runtimeDirectoryURL(fileManager: .default, createDirectoryIfNeeded: true)
    }

    private func teamDirectoryURL(teamName: String) -> URL? {
        teamRootURL?.appendingPathComponent(teamName, isDirectory: true)
    }

    private func notifyChanged() {
        NotificationCenter.default.post(name: .openAvaTeamSwarmDidChange, object: nil)
    }

    private func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private func summarize(_ value: String?, limit: Int = 140) -> String? {
        guard let normalized = normalized(value) else { return nil }
        guard normalized.count > limit else { return normalized }
        return String(normalized.prefix(limit)) + "…"
    }

    private func sanitize(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
    }
}

private struct TeamError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? {
        message
    }
}

private final class TeamSessionStorageProvider: StorageProvider, @unchecked Sendable {
    private let base: TranscriptStorageProvider

    init(base: TranscriptStorageProvider) {
        self.base = base
    }

    func createMessage(in sessionID: String, role: MessageRole) -> ConversationMessage {
        base.createMessage(in: sessionID, role: role)
    }

    func save(_ messages: [ConversationMessage]) {
        base.save(messages)
    }

    func messages(in sessionID: String) -> [ConversationMessage] {
        base.messages(in: sessionID)
    }

    func delete(_ messageIDs: [String]) {
        base.delete(messageIDs)
    }

    func title(for id: String) -> String? {
        base.title(for: id)
    }

    func setTitle(_ title: String, for id: String) {
        base.setTitle(title, for: id)
    }
}

@MainActor
private final class TeamExecutionSessionDelegate: SessionDelegate, @unchecked Sendable {
    struct TurnOutcome {
        let success: Bool
        let errorDescription: String?
    }

    private let base: AgentSessionDelegate
    private var latestOutcome: TurnOutcome?

    init(base: AgentSessionDelegate) {
        self.base = base
    }

    func prepareForTurn() {
        latestOutcome = nil
    }

    func consumeOutcome() -> TurnOutcome? {
        defer { latestOutcome = nil }
        return latestOutcome
    }

    func beginBackgroundTask(expiration: @escaping @Sendable () -> Void) -> Any? {
        base.beginBackgroundTask(expiration: expiration)
    }

    func endBackgroundTask(_ token: Any) {
        base.endBackgroundTask(token)
    }

    func preventIdleTimer() {
        base.preventIdleTimer()
    }

    func allowIdleTimer() {
        base.allowIdleTimer()
    }

    func sessionExecutionDidStart(for sessionID: String) {
        base.sessionExecutionDidStart(for: sessionID)
    }

    func sessionExecutionDidFinish(for sessionID: String, success: Bool, errorDescription: String?) {
        latestOutcome = TurnOutcome(success: success, errorDescription: errorDescription)
        base.sessionExecutionDidFinish(for: sessionID, success: success, errorDescription: errorDescription)
    }

    func sessionExecutionDidInterrupt(for sessionID: String, reason: String) {
        latestOutcome = TurnOutcome(success: false, errorDescription: reason)
        base.sessionExecutionDidInterrupt(for: sessionID, reason: reason)
    }

    func sessionDidReportUsage(_ usage: TokenUsage, for sessionID: String) {
        base.sessionDidReportUsage(usage, for: sessionID)
    }

    func sessionDidPersistMessages(_ messages: [ConversationMessage], for sessionID: String) async {
        await base.sessionDidPersistMessages(messages, for: sessionID)
    }

    func searchSensitivityPrompt() -> String? {
        base.searchSensitivityPrompt()
    }

    func composeSystemPrompt() async -> String? {
        await base.composeSystemPrompt()
    }
}
