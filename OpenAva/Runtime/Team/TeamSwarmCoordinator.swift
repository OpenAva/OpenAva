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

    private let colors = ["blue", "green", "orange", "pink", "purple", "teal"]
    private var agentStoreRootURL: URL?
    private var teamsByName: [String: TeamRecord] = [:]
    private var memberSignals: [String: AsyncStream<Void>.Continuation] = [:]
    private var memberTasks: [String: Task<Void, Never>] = [:]
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

        let formattedBody = formattedDirectMessage(fromName: senderName, text: body)

        if target.caseInsensitiveCompare(Self.coordinatorName) == .orderedSame {
            enqueuePendingTeamMessage(
                teamName: resolvedTeamName,
                recipientName: Self.coordinatorName,
                fromName: senderName,
                text: formattedBody,
                messageType: messageType,
                summary: summarize(body)
            )
            return
        }

        guard let member = team.members.first(where: { $0.name.caseInsensitiveCompare(target) == .orderedSame }) else {
            throw TeamError("TEAMMATE_NOT_FOUND: \(target)")
        }

        if member.awaitingPlanApproval, messageType != "approved_execution", messageType != "shutdown_request" {
            updateMember(teamName: resolvedTeamName, memberID: member.id) { member in
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
            markMemberShutdownRequested(teamName: resolvedTeamName, memberID: member.id)
        }
        enqueuePendingTeamMessage(
            teamName: resolvedTeamName,
            recipientName: member.name,
            fromName: senderName,
            text: formattedBody,
            messageType: messageType,
            summary: summarize(body)
        )
        markMemberBusy(teamName: resolvedTeamName, memberID: member.id)
        let didHaveWorker = memberTasks[member.id] != nil
        ensureMemberWorker(member: member)
        if didHaveWorker {
            memberSignals[member.id]?.yield()
        }
        synchronizeTeamDirectories()
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
        let pendingExecutionInput = member.pendingExecutionInput
        member.pendingExecutionInput = nil
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

        if let pendingExecutionInput {
            let feedbackLine = normalized(feedback).map { "\n\nCoordinator feedback: \($0)" } ?? ""
            enqueuePendingTeamMessage(
                teamName: target.teamName,
                recipientName: member.name,
                fromName: Self.coordinatorName,
                text: pendingExecutionInput + feedbackLine,
                messageType: "approved_execution",
                summary: summarize(pendingExecutionInput)
            )
            markMemberBusy(teamName: target.teamName, memberID: member.id)
            let didHaveWorker = memberTasks[member.id] != nil
            ensureMemberWorker(member: member)
            if didHaveWorker {
                memberSignals[member.id]?.yield()
            }
        }
        synchronizeTeamDirectories()
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
        synchronizeTeamDirectories()
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
            member.pendingExecutionInput = pendingMessage.text
            member.lastResult = nil
            member.lastError = nil
            member.lastUpdatedAt = Date()
        }

        do {
            let output = try await performMemberTurn(
                teamName: teamName,
                member: member,
                prompt: pendingMessage.text
            )
            let planRequestID = persistPlanApprovalRequest(teamName: teamName, member: member, plan: output)
            updateMember(teamName: teamName, memberID: member.id) { member in
                member.lastPlan = output
                member.lastResult = output
                member.lastError = nil
                member.pendingPlanRequestID = planRequestID
                member.lastUpdatedAt = Date()
            }
            synchronizeTeamDirectories()
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

        do {
            let output = try await performMemberTurn(
                teamName: teamName,
                member: member,
                prompt: pendingMessage.text
            )
            finishMember(teamName: teamName, memberID: member.id, status: .idle, result: output, error: nil)
        } catch {
            finishMember(teamName: teamName, memberID: member.id, status: .failed, result: nil, error: error.localizedDescription)
        }
    }

    private func performMemberTurn(
        teamName _: String,
        member: TeamMember,
        prompt: String
    ) async throws -> String {
        let agent = try agentProfile(for: member)
        let modelConfig = try resolvedModelConfig(for: agent, memberName: member.name)
        return try await AgentMainSessionRegistry.shared.submitToMainSession(
            for: agent,
            modelConfig: modelConfig,
            invocationSessionID: member.sessionID,
            shouldExtractDurableMemory: false
        ) { resources in
            let session = resources.session
            let storageProvider = resources.storageProvider

            guard let model = session.models.chat else {
                throw TeamError("TEAMMATE_MODEL_NOT_CONFIGURED: \(member.name)")
            }

            let baselineMessages = storageProvider.messages(in: Self.mainSessionID)
            let baselineMessageIDs = Set(baselineMessages.map(\.id))
            let baselineLastMessageID = baselineMessages.last?.id

            session.refreshContentsFromDatabase(scrolling: false)
            let input = ConversationSession.UserInput(text: prompt)
            await awaitMessageSubmission(
                session: session,
                model: model,
                input: input
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
        synchronizeTeamDirectories()
        notifyChanged()
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

    private func loadPersistedTeams() {
        memberSignals.removeAll()
        memberTasks.values.forEach { $0.cancel() }
        memberTasks.removeAll()
        let persistedManifests = loadTeamManifestsFromDirectories() ?? [:]
        let teamProfiles = TeamStore.load().teams
        let agentByID = Dictionary(uniqueKeysWithValues: loadAgentState().agents.map { ($0.id, $0) })
        let loadedTeams = teamProfiles.compactMap { teamRecord(for: $0, persisted: persistedManifests[$0.name], agentByID: agentByID) }

        guard !loadedTeams.isEmpty else {
            teamsByName.removeAll()
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
    }

    private func synchronizeTeamDirectories() {
        guard let rootURL = teamsRootURL else { return }
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
            let teamManifest = TeamManifest(
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
            guard let data = try? JSONEncoder().encode(teamManifest) else { continue }
            try? data.write(to: directoryURL.appendingPathComponent("config.json", isDirectory: false), options: [.atomic])
        }
    }

    private func loadTeamManifestsFromDirectories() -> [String: TeamManifest]? {
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

        guard !files.isEmpty else { return nil }
        return Dictionary(uniqueKeysWithValues: files.map { ($0.name, $0) })
    }

    private func teamRecord(
        for profile: TeamProfile,
        persisted: TeamManifest?,
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
                pendingExecutionInput: persistedMember?.input,
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

    private var teamsRootURL: URL? {
        TeamStore.runtimeDirectoryURL(fileManager: .default, createDirectoryIfNeeded: true)
    }

    private func teamDirectoryURL(teamName: String) -> URL? {
        teamsRootURL?.appendingPathComponent(teamName, isDirectory: true)
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
