import ChatClient
import ChatUI
import Foundation
import OpenClawKit

extension Notification.Name {
    static let openAvaTeamSwarmDidChange = Notification.Name("openava.teamSwarmDidChange")
}

#if DEBUG
    extension TeamSwarmCoordinator {
        struct FinishMemberTestSnapshot {
            let member: TeamMember
            let tasksByID: [Int: TeamTask]
        }

        func test_finishMember(
            memberID: String,
            status: MemberStatus,
            result: String?,
            error: String?
        ) throws -> FinishMemberTestSnapshot {
            finishMember(memberID: memberID, status: status, result: result, error: error)
            guard let team = teamRecord,
                  let member = team.members.first(where: { $0.id == memberID })
            else {
                throw TeamError("TEAM_MEMBER_NOT_FOUND: \(memberID)")
            }
            return FinishMemberTestSnapshot(
                member: member,
                tasksByID: Dictionary(uniqueKeysWithValues: team.tasks.map { ($0.id, $0) })
            )
        }
    }
#endif

@MainActor
final class TeamSwarmCoordinator {
    static let shared = TeamSwarmCoordinator()

    static let coordinatorName = "coordinator"
    static let mainSessionID = "main"

    struct ToolContext {
        let sessionID: String?
        let senderMemberID: String?

        init(sessionID: String? = nil, senderMemberID: String? = nil) {
            self.sessionID = sessionID
            self.senderMemberID = senderMemberID
        }
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
        var blockedBy: [Int]
        var createdAt: Date
        var updatedAt: Date

        enum CodingKeys: String, CodingKey {
            case id
            case title
            case detail
            case status
            case owner
            case blockedBy
            case createdAt
            case updatedAt
        }

        init(
            id: Int,
            title: String,
            detail: String?,
            status: TaskStatus,
            owner: String?,
            blockedBy: [Int] = [],
            createdAt: Date,
            updatedAt: Date
        ) {
            self.id = id
            self.title = title
            self.detail = detail
            self.status = status
            self.owner = owner
            self.blockedBy = blockedBy
            self.createdAt = createdAt
            self.updatedAt = updatedAt
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(Int.self, forKey: .id)
            title = try container.decode(String.self, forKey: .title)
            detail = try container.decodeIfPresent(String.self, forKey: .detail)
            status = try container.decode(TaskStatus.self, forKey: .status)
            owner = try container.decodeIfPresent(String.self, forKey: .owner)
            blockedBy = try container.decodeIfPresent([Int].self, forKey: .blockedBy) ?? []
            createdAt = try container.decode(Date.self, forKey: .createdAt)
            updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        }
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
        /// Pending input text that should be executed after approval.
        var pendingExecutionInput: String?
        var pendingPlanRequestID: String?
        var lastPlan: String?
        var lastResult: String?
        var lastError: String?
        var lastUpdatedAt: Date
        var shutdownRequested: Bool
        var lastIdleSummary: String?
    }

    struct TeamRecord: Codable, Equatable {
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

    private let colors = ["blue", "green", "orange", "pink", "purple", "teal"]
    private var agentStoreRootURL: URL?
    private var teamRecord: TeamRecord?
    private var memberSignals: [String: AsyncStream<Void>.Continuation] = [:]
    private var memberTasks: [String: Task<Void, Never>] = [:]
    private var coordinatorInboxDeliveryTask: Task<Void, Never>?
    private var loadedConfigurationSignature: String?

    private init() {}

    func configure(
        agentStoreRootURL: URL?
    ) {
        let normalizedAgentStoreRootURL = agentStoreRootURL?.standardizedFileURL
        let configurationSignature = normalizedAgentStoreRootURL?.path ?? ""
        if loadedConfigurationSignature != configurationSignature {
            loadedConfigurationSignature = configurationSignature
            self.agentStoreRootURL = normalizedAgentStoreRootURL
            loadPersistedTeams()
        } else {
            self.agentStoreRootURL = normalizedAgentStoreRootURL
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

    func menuSnapshot() -> TeamMenuSnapshot? {
        guard let team = teamRecord else { return nil }
        let pending = pendingPermissions()
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

    func snapshot(context: ToolContext) -> TeamSnapshot? {
        guard let team = resolvedTeam(context: context) else {
            return nil
        }
        return TeamSnapshot(
            team: team,
            pendingPermissions: pendingPermissions()
        )
    }

    func sendMessage(
        to rawTarget: String,
        message: String,
        messageType: String,
        context: ToolContext
    ) throws {
        guard let team = resolvedTeam(context: context) else {
            throw TeamError("TEAM_NOT_FOUND")
        }
        let body = normalized(message) ?? ""
        guard !body.isEmpty else {
            throw TeamError("INVALID_REQUEST: message must not be empty")
        }
        let target = sanitize(rawTarget)
        let senderName = senderName(for: context) ?? Self.coordinatorName

        if target.caseInsensitiveCompare(Self.coordinatorName) == .orderedSame {
            enqueuePendingTeamMessage(
                recipientName: Self.coordinatorName,
                fromName: senderName,
                text: formattedDirectMessage(fromName: senderName, text: body),
                messageType: messageType,
                summary: summarize(body)
            )
            return
        }

        guard let member = team.members.first(where: { $0.name.caseInsensitiveCompare(target) == .orderedSame }) else {
            throw TeamError("TEAMMATE_NOT_FOUND: \(target)")
        }

        deliverMessage(
            body: body,
            messageType: messageType,
            senderName: senderName,
            member: member
        )
    }

    private func pendingCoordinatorInboxMessages(limit: Int? = nil) -> [TeamMailboxMessage] {
        guard let teamDirectoryURL = teamDirectoryURL() else {
            return []
        }
        let messages = TeamMailbox.unreadMessages(
            teamDirectoryURL: teamDirectoryURL,
            recipientName: Self.coordinatorName
        )
        return limitedInboxMessages(messages, limit: limit)
    }

    private func markCoordinatorInboxMessagesRead(_ messages: [TeamMailboxMessage]) {
        guard let teamDirectoryURL = teamDirectoryURL(), !messages.isEmpty else {
            return
        }
        try? TeamMailbox.markRead(
            teamDirectoryURL: teamDirectoryURL,
            recipientName: Self.coordinatorName,
            messageIDs: Set(messages.map(\.id))
        )
        notifyChanged()
    }

    private func limitedInboxMessages(_ messages: [TeamMailboxMessage], limit: Int?) -> [TeamMailboxMessage] {
        guard let limit, limit > 0, messages.count > limit else {
            return messages
        }
        return Array(messages.suffix(limit))
    }

    @discardableResult
    func sendScheduledMessage(
        toAgentID agentID: String,
        message: String,
        messageType: String = "scheduled_message"
    ) -> Bool {
        guard let member = resolveMember(memberID: agentID),
              let body = normalized(message)
        else {
            return false
        }

        deliverMessage(
            body: body,
            messageType: messageType,
            senderName: Self.coordinatorName,
            member: member
        )
        return true
    }

    func approvePlan(sessionID: String?, memberName: String?, feedback: String?, context: ToolContext) throws -> TeamMember {
        guard let member = resolveMember(sessionID: sessionID, memberName: memberName, context: context) else {
            throw TeamError("TEAMMATE_NOT_FOUND")
        }
        guard var team = resolvedTeam(context: context),
              let index = team.members.firstIndex(where: { $0.id == member.id })
        else {
            throw TeamError("TEAM_NOT_FOUND")
        }
        var updatedMember = team.members[index]
        guard updatedMember.awaitingPlanApproval else {
            throw TeamError("PLAN_NOT_PENDING")
        }
        updatedMember.awaitingPlanApproval = false
        updatedMember.hasApprovedPlan = true
        updatedMember.status = .busy
        updatedMember.lastUpdatedAt = Date()
        let pendingPlanRequestID = updatedMember.pendingPlanRequestID
        let pendingExecutionInput = updatedMember.pendingExecutionInput
        updatedMember.pendingExecutionInput = nil
        updatedMember.pendingPlanRequestID = nil
        team.members[index] = updatedMember
        team.updatedAt = Date()
        teamRecord = team

        if let pendingPlanRequestID,
           let teamDirectoryURL = teamDirectoryURL()
        {
            _ = try? TeamPermissionSync.resolve(
                teamDirectoryURL: teamDirectoryURL,
                requestID: pendingPlanRequestID,
                resolution: TeamPermissionResolution(
                    status: .approved,
                    resolvedBy: senderName(for: context) ?? Self.coordinatorName,
                    feedback: normalized(feedback)
                )
            )
        }

        if let pendingExecutionInput {
            let feedbackLine = normalized(feedback).map { "\n\nPlan approval feedback: \($0)" } ?? ""
            enqueuePendingTeamMessage(
                recipientName: updatedMember.name,
                fromName: Self.coordinatorName,
                text: pendingExecutionInput + feedbackLine,
                messageType: "approved_execution",
                summary: summarize(pendingExecutionInput)
            )
            markMemberBusy(memberID: updatedMember.id)
            let didHaveWorker = memberTasks[updatedMember.id] != nil
            ensureMemberWorker(member: updatedMember)
            if didHaveWorker {
                memberSignals[updatedMember.id]?.yield()
            }
        }
        synchronizeTeamDirectories()
        notifyChanged()
        return updatedMember
    }

    func createTask(title: String, detail: String?, context: ToolContext) throws -> TeamTask {
        guard var team = resolvedTeam(context: context) else {
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
            blockedBy: [],
            createdAt: now,
            updatedAt: now
        )
        team.nextTaskID += 1
        team.tasks.append(task)
        team.updatedAt = now
        teamRecord = team
        synchronizeTeamDirectories()
        notifyChanged()
        return task
    }

    func listTasks(context: ToolContext) throws -> [TeamTask] {
        guard let team = resolvedTeam(context: context) else {
            throw TeamError("TEAM_NOT_FOUND")
        }
        return team.tasks.sorted { $0.id < $1.id }
    }

    func getTask(id: Int, context: ToolContext) throws -> TeamTask {
        guard let team = resolvedTeam(context: context),
              let task = team.tasks.first(where: { $0.id == id })
        else {
            throw TeamError("TASK_NOT_FOUND")
        }
        return task
    }

    func updateTask(
        id: Int,
        title: String?,
        detail: String?,
        status: TaskStatus?,
        owner: String?,
        addBlockedBy: [Int] = [],
        context: ToolContext
    ) throws -> TeamTask {
        guard var team = resolvedTeam(context: context),
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
        } else if status == .inProgress,
                  task.owner == nil,
                  let senderMemberID = context.senderMemberID,
                  let senderName = team.members.first(where: { $0.id == senderMemberID })?.name
        {
            task.owner = senderName
        }
        if !addBlockedBy.isEmpty {
            let existingTaskIDs = Set(team.tasks.map(\.id))
            let filteredBlockedBy = addBlockedBy.filter { blockerID in
                blockerID != id && existingTaskIDs.contains(blockerID)
            }
            if !filteredBlockedBy.isEmpty {
                let mergedBlockedBy = Set(task.blockedBy).union(filteredBlockedBy)
                task.blockedBy = mergedBlockedBy.sorted()
                if task.status == .pending {
                    task.status = .blocked
                }
            }
        }
        if status == .completed {
            task.owner = task.owner ?? normalized(owner)
            let completedTaskID = task.id
            for dependentIndex in team.tasks.indices where dependentIndex != index {
                if team.tasks[dependentIndex].blockedBy.contains(completedTaskID) {
                    team.tasks[dependentIndex].blockedBy.removeAll { $0 == completedTaskID }
                    if team.tasks[dependentIndex].blockedBy.isEmpty,
                       team.tasks[dependentIndex].status == .blocked
                    {
                        team.tasks[dependentIndex].status = .pending
                    }
                    team.tasks[dependentIndex].updatedAt = Date()
                }
            }
        }
        if task.status == .pending, !task.blockedBy.isEmpty {
            task.status = .blocked
        }
        if task.status == .blocked, task.blockedBy.isEmpty {
            task.status = .pending
        }
        task.updatedAt = Date()
        team.tasks[index] = task
        team.updatedAt = task.updatedAt
        teamRecord = team
        synchronizeTeamDirectories()
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
        guard let member = resolveMember(memberID: memberID),
              let teamDirectoryURL = teamDirectoryURL()
        else {
            return true
        }

        let pendingMessages = TeamMailbox.unreadMessages(teamDirectoryURL: teamDirectoryURL, recipientName: member.name)
        guard !pendingMessages.isEmpty else {
            return true
        }

        for message in pendingMessages {
            guard let current = resolveMember(memberID: memberID) else {
                break
            }

            if message.messageType == "shutdown_request" {
                try? TeamMailbox.markRead(teamDirectoryURL: teamDirectoryURL, recipientName: current.name, messageIDs: [message.id])
                finishMember(memberID: memberID, status: .stopped, result: "Shutdown requested.", error: nil)
                return false
            }

            if current.planModeRequired, !current.hasApprovedPlan, message.messageType != "approved_execution" {
                await runPlanStep(member: current, pendingMessage: message)
            } else {
                await runExecutionStep(member: current, pendingMessage: message)
            }

            try? TeamMailbox.markRead(teamDirectoryURL: teamDirectoryURL, recipientName: current.name, messageIDs: [message.id])
        }

        return true
    }

    private func runPlanStep(member: TeamMember, pendingMessage: TeamMailboxMessage) async {
        updateMember(memberID: member.id) { member in
            member.status = .awaitingPlanApproval
            member.awaitingPlanApproval = true
            member.pendingExecutionInput = pendingMessage.text
            member.lastResult = nil
            member.lastError = nil
            member.lastUpdatedAt = Date()
        }

        do {
            let output = try await performMemberTurn(
                member: member,
                pendingMessage: pendingMessage
            )
            let planRequestID = persistPlanApprovalRequest(member: member, plan: output)
            updateMember(memberID: member.id) { member in
                member.lastPlan = output
                member.lastResult = output
                member.lastError = nil
                member.pendingPlanRequestID = planRequestID
                member.lastUpdatedAt = Date()
            }
            synchronizeTeamDirectories()
            notifyChanged()
        } catch {
            finishMember(memberID: member.id, status: .failed, result: nil, error: error.localizedDescription)
        }
    }

    private func runExecutionStep(member: TeamMember, pendingMessage: TeamMailboxMessage) async {
        updateMember(memberID: member.id) { member in
            member.status = .busy
            member.lastUpdatedAt = Date()
            member.lastResult = nil
            member.lastError = nil
        }

        do {
            let output = try await performMemberTurn(
                member: member,
                pendingMessage: pendingMessage
            )
            finishMember(memberID: member.id, status: .idle, result: output, error: nil)
        } catch {
            finishMember(memberID: member.id, status: .failed, result: nil, error: error.localizedDescription)
        }
    }

    private func performMemberTurn(
        member: TeamMember,
        pendingMessage: TeamMailboxMessage
    ) async throws -> String {
        let agent = try agentProfile(for: member)
        let modelConfig = try resolvedModelConfig(for: agent, memberName: member.name)
        let agentCount = max(loadAgentState().agents.count, 1)
        return try await AgentMainSessionRegistry.shared.submitToMainSession(
            for: agent,
            modelConfig: modelConfig,
            invocationSessionID: member.sessionID,
            shouldExtractDurableMemory: false,
            agentCount: agentCount
        ) { resources in
            let session = resources.session
            let storageProvider = resources.storageProvider

            return try await ToolRuntime.InvocationContext.$teamContext.withValue(
                ToolRuntime.TeamInvocationContext(memberID: member.id)
            ) {
                guard let model = session.models.chat else {
                    throw TeamError("TEAMMATE_MODEL_NOT_CONFIGURED: \(member.name)")
                }

                let baselineMessages = storageProvider.messages(in: Self.mainSessionID)
                let baselineMessageIDs = Set(baselineMessages.map(\.id))
                let baselineLastMessageID = baselineMessages.last?.id

                session.refreshContentsFromDatabase(scrolling: false)
                let promptInput = ConversationSession.PromptInput(
                    text: pendingMessage.text,
                    source: self.promptSource(forTeamMessageType: pendingMessage.messageType),
                    metadata: [
                        ConversationSession.PromptInput.teamMessageTypeMetadataKey: pendingMessage.messageType,
                        ConversationSession.PromptInput.teamSenderMetadataKey: pendingMessage.from,
                    ]
                )
                await session.submitPrompt(
                    model: model,
                    prompt: promptInput
                )

                let latestMessages = storageProvider.messages(in: Self.mainSessionID)
                let newMessages = latestMessages.filter { !baselineMessageIDs.contains($0.id) }

                if let failureMessage = latestMessages.last(where: { message in
                    guard message.role == .assistant,
                          !baselineMessageIDs.contains(message.id)
                    else {
                        return false
                    }
                    let text = message.textContent.trimmingCharacters(in: .whitespacesAndNewlines)
                    return text.hasPrefix("```") && text.hasSuffix("```")
                }) {
                    throw TeamError(failureMessage.textContent.trimmingCharacters(in: .whitespacesAndNewlines))
                }

                if let lastNewMessage = newMessages.last,
                   lastNewMessage.role == .system,
                   lastNewMessage.textContent.localizedCaseInsensitiveContains("Error:")
                {
                    throw TeamError(lastNewMessage.textContent)
                }

                let latestAssistantText = AppConfig.nonEmpty(
                    newMessages
                        .filter { $0.role == .assistant }
                        .last?
                        .textContent
                )

                if latestAssistantText == nil,
                   let lastMessageID = latestMessages.last?.id,
                   baselineLastMessageID == lastMessageID
                {
                    throw TeamError("Member execution did not produce new output.")
                }

                return latestAssistantText ?? "Completed without a textual final response."
            }
        }
    }

    private func promptSource(forTeamMessageType messageType: String) -> ConversationSession.PromptInput.Source {
        switch messageType {
        case "broadcast_message":
            return .teamBroadcast
        case "message":
            return .teamMessage
        case "teammate_idle", "shutdown_request":
            return .systemEvent
        default:
            return .teamTask
        }
    }

    private struct CoordinatorDeliveryConfiguration {
        let agent: AgentProfile
        let modelConfig: AppConfig.LLMModel
        let agentCount: Int
        let invocationSessionID: String
    }

    private func scheduleCoordinatorInboxDelivery() {
        guard coordinatorInboxDeliveryTask == nil else {
            return
        }

        coordinatorInboxDeliveryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await runCoordinatorInboxDeliveryLoop()
            coordinatorInboxDeliveryTask = nil
        }
    }

    private func runCoordinatorInboxDeliveryLoop() async {
        while !Task.isCancelled {
            let messages = pendingCoordinatorInboxMessages(limit: 10)
            guard !messages.isEmpty else {
                return
            }
            guard let configuration = coordinatorDeliveryConfiguration() else {
                return
            }

            let didSubmit = await submitCoordinatorInboxMessages(messages, configuration: configuration)
            if didSubmit {
                markCoordinatorInboxMessagesRead(messages)
            } else {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func coordinatorDeliveryConfiguration() -> CoordinatorDeliveryConfiguration? {
        let state = loadAgentState()
        guard let activeAgent = state.activeAgent,
              let modelConfig = LLMConfigStore
              .loadCollection()
              .selectedModel(preferredID: activeAgent.selectedModelID),
              modelConfig.isConfigured
        else {
            return nil
        }

        let mainSessionID = teamRecord?.coordinatorSessionID ?? Self.mainSessionID
        return CoordinatorDeliveryConfiguration(
            agent: activeAgent,
            modelConfig: modelConfig,
            agentCount: max(state.agents.count, 1),
            invocationSessionID: "\(activeAgent.id.uuidString)::\(mainSessionID)"
        )
    }

    private func submitCoordinatorInboxMessages(
        _ messages: [TeamMailboxMessage],
        configuration: CoordinatorDeliveryConfiguration
    ) async -> Bool {
        let resources = AgentMainSessionRegistry.shared.sessionResources(
            for: configuration.agent,
            modelConfig: configuration.modelConfig,
            invocationSessionID: configuration.invocationSessionID,
            agentCount: configuration.agentCount
        )
        await waitForCoordinatorSessionIdle(resources.session)
        guard !Task.isCancelled else {
            return false
        }

        do {
            return try await AgentMainSessionRegistry.shared.submitToMainSession(
                for: configuration.agent,
                modelConfig: configuration.modelConfig,
                invocationSessionID: configuration.invocationSessionID,
                agentCount: configuration.agentCount
            ) { resources in
                let session = resources.session
                guard !session.isQueryActive,
                      let model = session.models.chat
                else {
                    return false
                }

                session.refreshContentsFromDatabase(scrolling: false)
                return await session.submitPrompt(
                    model: model,
                    prompt: self.coordinatorPromptInput(for: messages)
                )
            }
        } catch {
            return false
        }
    }

    private func waitForCoordinatorSessionIdle(_ session: ConversationSession) async {
        while session.isQueryActive, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    private func coordinatorPromptInput(for messages: [TeamMailboxMessage]) -> ConversationSession.PromptInput {
        let sortedMessages = messages.sorted { $0.timestamp < $1.timestamp }
        let text: String
        if sortedMessages.count == 1, let message = sortedMessages.first {
            text = message.text
        } else {
            text = (["You have \(sortedMessages.count) new team messages. Process them in timestamp order."] + sortedMessages.map { message in
                """
                <team-message id=\"\(message.id)\" from=\"\(message.from)\" type=\"\(message.messageType)\" timestamp=\"\(formatTimestamp(message.timestamp))\">
                \(message.text)
                </team-message>
                """
            }).joined(separator: "\n\n")
        }

        var metadata: [String: String] = [
            ConversationSession.PromptInput.teamMessageTypeMetadataKey: sortedMessages.count == 1 ? (sortedMessages.first?.messageType ?? "message") : "team_message_batch",
            ConversationSession.PromptInput.teamSenderMetadataKey: sortedMessages.map(\.from).joined(separator: ", "),
            "teamMessageIDs": sortedMessages.map(\.id).joined(separator: ","),
        ]

        if let firstMessage = sortedMessages.first {
            metadata["teamFirstMessageID"] = firstMessage.id
        }

        return ConversationSession.PromptInput(
            text: text,
            source: .teamMessage,
            metadata: metadata
        )
    }

    private func formatTimestamp(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private func agentProfile(for member: TeamMember) throws -> AgentProfile {
        guard let memberUUID = UUID(uuidString: member.id),
              let agent = loadAgentState().agents.first(where: { $0.id == memberUUID })
        else {
            throw TeamError("TEAMMATE_AGENT_NOT_FOUND: \(member.name)")
        }
        return agent
    }

    private func loadAgentState() -> AgentStateSnapshot {
        AgentStore.load(workspaceRootURL: agentStoreRootURL)
    }

    private func resolvedModelConfig(for agent: AgentProfile, memberName: String) throws -> AppConfig.LLMModel {
        guard let modelConfig = LLMConfigStore.loadCollection().selectedModel(preferredID: agent.selectedModelID),
              modelConfig.isConfigured
        else {
            throw TeamError("TEAMMATE_MODEL_NOT_CONFIGURED: \(memberName)")
        }
        return modelConfig
    }

    private func finishMember(memberID: String, status: MemberStatus, result: String?, error: String?) {
        let memberName = teamRecord?.members.first(where: { $0.id == memberID })?.name
        let idleSummary = status == .idle ? summarize(result) : nil
        updateMember(memberID: memberID) { member in
            member.status = status
            member.lastResult = result ?? member.lastResult
            member.lastError = error
            member.lastUpdatedAt = Date()
            if status == .idle {
                member.lastIdleSummary = idleSummary
            }
            if status == .stopped {
                member.shutdownRequested = true
            }
        }
        if status == .idle, let memberName {
            completeOwnedInProgressTasks(forMemberNamed: memberName)
            enqueueTeammateIdleMessage(memberName: memberName, summary: idleSummary)
        }
        synchronizeTeamDirectories()
        notifyChanged()
    }

    private func completeOwnedInProgressTasks(forMemberNamed memberName: String) {
        guard var team = teamRecord else { return }

        let normalizedOwner = memberName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedOwner.isEmpty else { return }

        let now = Date()
        var didUpdate = false
        for index in team.tasks.indices {
            guard team.tasks[index].status == .inProgress,
                  team.tasks[index].owner?.caseInsensitiveCompare(normalizedOwner) == .orderedSame
            else {
                continue
            }
            team.tasks[index].status = .completed
            team.tasks[index].updatedAt = now
            didUpdate = true
        }

        guard didUpdate else { return }
        team.updatedAt = now
        teamRecord = team
    }

    private func markMemberShutdownRequested(memberID: String) {
        updateMember(memberID: memberID) { member in
            member.shutdownRequested = true
            member.lastUpdatedAt = Date()
        }
    }

    private func enqueuePendingTeamMessage(
        recipientName: String,
        fromName: String,
        text: String,
        messageType: String,
        summary: String?
    ) {
        guard let teamDirectoryURL = teamDirectoryURL() else { return }
        let message = TeamMailboxMessage(
            id: UUID().uuidString,
            from: fromName,
            text: text,
            timestamp: Date(),
            read: false,
            color: resolveColor(for: fromName),
            summary: summary,
            messageType: messageType
        )
        try? TeamMailbox.append(teamDirectoryURL: teamDirectoryURL, recipientName: recipientName, message: message)
        if recipientName.caseInsensitiveCompare(Self.coordinatorName) == .orderedSame {
            scheduleCoordinatorInboxDelivery()
            notifyChanged()
        }
    }

    private func enqueueTeammateIdleMessage(memberName: String, summary: String?) {
        let normalizedMemberName = memberName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedMemberName.isEmpty else { return }

        let normalizedSummary = summarize(summary, limit: 280)
        enqueuePendingTeamMessage(
            recipientName: Self.coordinatorName,
            fromName: normalizedMemberName,
            text: formattedTeammateIdleMessage(memberName: normalizedMemberName, summary: normalizedSummary),
            messageType: "teammate_idle",
            summary: normalizedSummary
        )
    }

    private func markMemberBusy(memberID: String) {
        updateMember(memberID: memberID) { member in
            member.lastUpdatedAt = Date()
            member.status = .busy
        }
    }

    private func persistPlanApprovalRequest(member: TeamMember, plan: String) -> String? {
        guard let teamDirectoryURL = teamDirectoryURL() else { return nil }
        let request = TeamPermissionRequest(
            id: UUID().uuidString,
            kind: "plan_execution",
            workerID: member.id,
            workerName: member.name,
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

    private func pendingPermissions() -> [TeamPermissionRequest] {
        guard let teamDirectoryURL = teamDirectoryURL() else { return [] }
        return TeamPermissionSync.readPending(teamDirectoryURL: teamDirectoryURL)
    }

    private func resolveColor(for senderName: String) -> String? {
        guard senderName.caseInsensitiveCompare(Self.coordinatorName) != .orderedSame else {
            return nil
        }
        guard let index = teamRecord?.members.firstIndex(where: {
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

    private func updateMember(memberID: String, mutate: (inout TeamMember) -> Void) {
        guard var team = teamRecord,
              let index = team.members.firstIndex(where: { $0.id == memberID })
        else {
            return
        }
        var member = team.members[index]
        mutate(&member)
        team.members[index] = member
        team.updatedAt = Date()
        teamRecord = team
    }

    private func deliverMessage(
        body: String,
        messageType: String,
        senderName: String,
        member: TeamMember
    ) {
        if member.awaitingPlanApproval, messageType != "approved_execution", messageType != "shutdown_request" {
            updateMember(memberID: member.id) { member in
                let merged = [
                    member.pendingExecutionInput,
                    "Additional message from \(senderName): \(body)",
                ].compactMap { $0 }.joined(separator: "\n\n")
                member.pendingExecutionInput = merged
                member.lastUpdatedAt = Date()
            }
            synchronizeTeamDirectories()
            notifyChanged()
            return
        }

        if messageType == "shutdown_request" {
            markMemberShutdownRequested(memberID: member.id)
        }
        enqueuePendingTeamMessage(
            recipientName: member.name,
            fromName: senderName,
            text: formattedDirectMessage(fromName: senderName, text: body),
            messageType: messageType,
            summary: summarize(body)
        )
        markMemberBusy(memberID: member.id)
        let didHaveWorker = memberTasks[member.id] != nil
        ensureMemberWorker(member: member)
        if didHaveWorker {
            memberSignals[member.id]?.yield()
        }
        synchronizeTeamDirectories()
        notifyChanged()
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
    }

    private func resolvedTeam(context: ToolContext) -> TeamRecord? {
        guard let team = teamRecord else { return nil }
        if let senderMemberID = context.senderMemberID,
           team.members.contains(where: { $0.id == senderMemberID })
        {
            return team
        }
        if let sessionID = context.sessionID {
            if sessionID == team.coordinatorSessionID {
                return team
            }
            if let activeAgentID = activeAgentID(from: sessionID),
               team.members.contains(where: { $0.id == activeAgentID })
            {
                return team
            }
        }
        return team
    }

    private func resolveMember(memberID: String) -> TeamMember? {
        teamRecord?.members.first(where: { $0.id == memberID })
    }

    private func resolveMember(
        sessionID: String?,
        memberName: String?,
        context: ToolContext
    ) -> TeamMember? {
        if let sessionID {
            return teamRecord?.members.first(where: { $0.sessionID == sessionID })
        }
        guard let team = resolvedTeam(context: context),
              let memberName = normalized(memberName),
              let member = team.members.first(where: { $0.name.caseInsensitiveCompare(memberName) == .orderedSame })
        else {
            return nil
        }
        return member
    }

    private func senderName(for context: ToolContext) -> String? {
        senderMember(for: context)?.name ?? Self.coordinatorName
    }

    private func senderMember(for context: ToolContext) -> TeamMember? {
        if let senderMemberID = context.senderMemberID,
           let member = resolveMember(memberID: senderMemberID)
        {
            return member
        }
        if let sessionID = context.sessionID,
           let senderMemberID = activeAgentID(from: sessionID),
           let member = resolveMember(memberID: senderMemberID)
        {
            return member
        }
        return nil
    }

    private func activeAgentID(from sessionID: String) -> String? {
        guard let separatorRange = sessionID.range(of: "::") else { return nil }
        let rawValue = String(sessionID[..<separatorRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        return rawValue.isEmpty || rawValue == "global" ? nil : rawValue
    }

    private func teammateInvocationSessionID(memberID: String) -> String {
        "\(memberID)::\(Self.mainSessionID)"
    }

    private func loadPersistedTeams() {
        coordinatorInboxDeliveryTask?.cancel()
        coordinatorInboxDeliveryTask = nil
        memberSignals.removeAll()
        memberTasks.values.forEach { $0.cancel() }
        memberTasks.removeAll()
        let persisted = loadPersistedTeamManifest()
        let agentByID = Dictionary(uniqueKeysWithValues: loadAgentState().agents.map { ($0.id, $0) })
        guard var team = implicitTeamRecord(persisted: persisted, agentByID: agentByID) else {
            teamRecord = nil
            return
        }
        team.members = team.members.map { member in
            var member = member
            member.status = .stopped
            member.awaitingPlanApproval = member.pendingPlanRequestID != nil
            return member
        }
        teamRecord = team
        scheduleCoordinatorInboxDelivery()
    }

    private func synchronizeTeamDirectories() {
        guard let team = teamRecord,
              let directoryURL = teamDirectoryURL()
        else {
            return
        }

        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let teamManifest = TeamManifest(
            createdAt: team.createdAt,
            updatedAt: team.updatedAt,
            coordinatorId: Self.coordinatorName,
            coordinatorSessionId: team.coordinatorSessionID,
            hiddenPaneIds: team.hiddenPaneIDs ?? [],
            teamAllowedPaths: team.allowedPaths ?? [],
            nextTaskID: team.nextTaskID,
            tasks: team.tasks,
            members: team.members.map { member in
                TeamManifestMember(
                    agentId: member.id,
                    agentType: member.agentType,
                    input: member.pendingExecutionInput,
                    planModeRequired: member.planModeRequired,
                    sessionId: member.sessionID,
                    mode: member.permissionMode,
                    lastStatus: member.status.rawValue,
                    pendingPlanRequestID: member.pendingPlanRequestID
                )
            }
        )
        guard let data = try? JSONEncoder().encode(teamManifest) else { return }
        try? data.write(to: directoryURL.appendingPathComponent("config.json", isDirectory: false), options: [.atomic])
    }

    private func loadPersistedTeamManifest() -> TeamManifest? {
        if let directoryURL = teamDirectoryURL() {
            let configURL = directoryURL.appendingPathComponent("config.json", isDirectory: false)
            if let data = try? Data(contentsOf: configURL),
               let teamManifest = try? JSONDecoder().decode(TeamManifest.self, from: data)
            {
                return teamManifest
            }
        }
        return loadLegacyTeamManifestFromDirectories()
    }

    private func loadLegacyTeamManifestFromDirectories() -> TeamManifest? {
        guard let rootURL = teamsRootURL,
              let directoryURLs = try? FileManager.default.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil)
        else {
            return nil
        }

        let files = directoryURLs.compactMap { url -> TeamManifest? in
            let configURL = url.appendingPathComponent("config.json", isDirectory: false)
            guard let data = try? Data(contentsOf: configURL),
                  let teamManifest = try? JSONDecoder().decode(TeamManifest.self, from: data)
            else {
                return nil
            }
            return teamManifest
        }

        return files
            .sorted { lhs, rhs in
                if lhs.updatedAt == rhs.updatedAt {
                    return lhs.createdAt > rhs.createdAt
                }
                return lhs.updatedAt > rhs.updatedAt
            }
            .first
    }

    private func implicitTeamRecord(
        persisted: TeamManifest?,
        agentByID: [UUID: AgentProfile]
    ) -> TeamRecord? {
        let agents = agentByID.values.sorted { lhs, rhs in
            if lhs.createdAtMs == rhs.createdAtMs {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return lhs.createdAtMs < rhs.createdAtMs
        }
        guard agents.count > 1 else {
            return nil
        }

        let members = agents.map { agent -> TeamMember in
            let persistedMember = persisted?.members.first(where: { $0.agentId == agent.id.uuidString })
            return TeamMember(
                id: agent.id.uuidString,
                name: agent.name,
                agentType: persistedMember?.agentType ?? SubAgentRegistry.generalPurpose.agentType,
                sessionID: persistedMember?.sessionId ?? teammateInvocationSessionID(memberID: agent.id.uuidString),
                planModeRequired: persistedMember?.planModeRequired ?? false,
                permissionMode: persistedMember?.mode,
                status: MemberStatus(rawValue: persistedMember?.lastStatus ?? "stopped") ?? .stopped,
                awaitingPlanApproval: persistedMember?.pendingPlanRequestID != nil,
                hasApprovedPlan: (persistedMember?.planModeRequired ?? false) ? persistedMember?.pendingPlanRequestID == nil : true,
                pendingExecutionInput: persistedMember?.input,
                pendingPlanRequestID: persistedMember?.pendingPlanRequestID,
                lastPlan: nil,
                lastResult: nil,
                lastError: nil,
                lastUpdatedAt: persisted?.updatedAt ?? Date(),
                shutdownRequested: false,
                lastIdleSummary: nil
            )
        }

        let createdAt = persisted?.createdAt
            ?? agents
            .map { Date(timeIntervalSince1970: TimeInterval($0.createdAtMs) / 1000) }
            .min()
            ?? Date()

        return TeamRecord(
            coordinatorSessionID: persisted?.coordinatorSessionId ?? Self.mainSessionID,
            createdAt: createdAt,
            updatedAt: persisted?.updatedAt ?? Date(),
            hiddenPaneIDs: persisted?.hiddenPaneIds ?? [],
            allowedPaths: persisted?.teamAllowedPaths ?? [],
            nextTaskID: max(persisted?.nextTaskID ?? 1, 1),
            members: members,
            tasks: persisted?.tasks ?? []
        )
    }

    private var teamsRootURL: URL? {
        TeamStore.storageDirectoryURL(
            fileManager: .default,
            workspaceRootURL: agentStoreRootURL,
            createDirectoryIfNeeded: true
        )
    }

    private func teamDirectoryURL() -> URL? {
        teamsRootURL
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

    private func formattedDirectMessage(fromName: String, text: String) -> String {
        "Message from \(fromName):\n\(text)"
    }

    private func formattedTeammateIdleMessage(memberName: String, summary: String?) -> String {
        guard let summary = normalized(summary) else {
            return "Teammate \(memberName) is now idle."
        }
        return "Teammate \(memberName) is now idle.\nSummary: \(summary)"
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
