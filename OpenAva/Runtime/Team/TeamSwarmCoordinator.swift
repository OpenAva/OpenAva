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
        let sessionTitle: String
        let workspacePath: String?
        let colorName: String?
        let spawnedAt: Date
        let description: String?
        let planModeRequired: Bool
        let backendType: TeamBackendType?
        let permissionMode: String?
        var status: MemberStatus
        var isIdle: Bool
        var awaitingPlanApproval: Bool
        var hasApprovedPlan: Bool
        var pendingExecutionPrompt: String?
        var pendingPlanRequestID: String?
        var lastPlan: String?
        var lastResult: String?
        var lastError: String?
        var lastUpdatedAt: Date
        var shutdownRequested: Bool
        var queuedMessageCount: Int?
        var lastMailboxPreview: String?
        var lastIdleSummary: String?
        var lastPeerMessageSummary: String?
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
        let coordinatorUnreadCount: Int
        let coordinatorMailboxPreview: String?
    }

    struct MemberSnapshot {
        let teamName: String
        let teamDescription: String?
        let allowedPaths: [TeamAllowedPath]
        let member: TeamMember
        let teammates: [TeamMember]
        let tasks: [TeamTask]
        let pendingPermissions: [TeamPermissionRequest]
        let coordinatorUnreadCount: Int
        let coordinatorMailboxPreview: String?
    }

    private let colors = ["blue", "green", "orange", "pink", "purple", "teal"]
    private var runtimeRootURL: URL?
    private var workspaceRootURL: URL?
    private var modelConfig: AppConfig.LLMModel?
    private var teamsByName: [String: TeamRecord] = [:]
    private var memberSignals: [String: AsyncStream<Void>.Continuation] = [:]
    private var memberTasks: [String: Task<Void, Never>] = [:]
    private var memberHistories: [String: [ChatRequestBody.Message]] = [:]
    private var loadedPersistencePath: String?

    private init() {}

    func configure(runtimeRootURL: URL?, workspaceRootURL: URL?, modelConfig: AppConfig.LLMModel?) {
        let normalizedPath = runtimeRootURL?.standardizedFileURL.path
        self.workspaceRootURL = workspaceRootURL?.standardizedFileURL
        if loadedPersistencePath != normalizedPath {
            loadedPersistencePath = normalizedPath
            self.runtimeRootURL = runtimeRootURL?.standardizedFileURL
            loadPersistedTeams()
        } else {
            self.runtimeRootURL = runtimeRootURL?.standardizedFileURL
        }
        self.modelConfig = modelConfig
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
            if let summary = member.lastIdleSummary ?? member.lastError ?? member.lastMailboxPreview {
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

    func isTeammateSession(_ sessionID: String) -> Bool {
        sessionID.hasPrefix("team:")
    }

    func memberSnapshot(for sessionID: String) -> MemberSnapshot? {
        for team in teamsByName.values {
            if let member = team.members.first(where: { $0.sessionID == sessionID }) {
                let pending = pendingPermissions(for: team.name)
                let coordinatorMailbox = coordinatorMailboxSummary(for: team.name)
                return MemberSnapshot(
                    teamName: team.name,
                    teamDescription: team.description,
                    allowedPaths: team.allowedPaths ?? [],
                    member: member,
                    teammates: team.members.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending },
                    tasks: team.tasks.sorted { $0.id < $1.id },
                    pendingPermissions: pending,
                    coordinatorUnreadCount: coordinatorMailbox.count,
                    coordinatorMailboxPreview: coordinatorMailbox.preview
                )
            }
        }
        return nil
    }

    func coordinatorSnapshot(for sessionID: String?) -> TeamSnapshot? {
        guard let sessionID else { return nil }
        let team = teamsByName.values.first(where: { $0.coordinatorSessionID == sessionID })
            ?? activeAgentID(from: sessionID).flatMap { activeAgentID in
                teamsByName.values.first(where: {
                    $0.members.contains(where: { $0.id == activeAgentID })
                })
            }
        guard let team else { return nil }
        let coordinatorMailbox = coordinatorMailboxSummary(for: team.name)
        return TeamSnapshot(
            team: team,
            pendingPermissions: pendingPermissions(for: team.name),
            coordinatorUnreadCount: coordinatorMailbox.count,
            coordinatorMailboxPreview: coordinatorMailbox.preview
        )
    }

    func snapshot(teamName: String? = nil, context: ToolContext) -> TeamSnapshot? {
        guard let resolvedTeamName = resolveTeamName(explicitTeamName: teamName, context: context),
              let team = teamsByName[resolvedTeamName]
        else {
            return nil
        }
        let coordinatorMailbox = coordinatorMailboxSummary(for: resolvedTeamName)
        return TeamSnapshot(
            team: team,
            pendingPermissions: pendingPermissions(for: resolvedTeamName),
            coordinatorUnreadCount: coordinatorMailbox.count,
            coordinatorMailboxPreview: coordinatorMailbox.preview
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

        let transcriptLine = "[\(senderName)] \(body)"

        if target.caseInsensitiveCompare(Self.coordinatorName) == .orderedSame {
            writeMailboxMessage(
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
                member.queuedMessageCount = (member.queuedMessageCount ?? 0) + 1
                member.lastMailboxPreview = summarize(body)
                member.lastUpdatedAt = Date()
            }
            appendTranscriptMessage(
                sessionID: member.sessionID,
                title: member.sessionTitle,
                role: .user,
                text: transcriptLine
            )
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
        writeMailboxMessage(
            teamName: resolvedTeamName,
            recipientName: member.name,
            fromName: senderName,
            text: body,
            messageType: messageType,
            summary: summarize(body)
        )
        appendTranscriptMessage(
            sessionID: member.sessionID,
            title: member.sessionTitle,
            role: .user,
            text: transcriptLine
        )
        refreshMailboxMetadata(teamName: resolvedTeamName, memberID: member.id, markBusy: true)
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
        member.isIdle = false
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
            writeMailboxMessage(
                teamName: target.teamName,
                recipientName: member.name,
                fromName: Self.coordinatorName,
                text: pendingPrompt + feedbackLine,
                messageType: "approved_execution",
                summary: summarize(pendingPrompt)
            )
            refreshMailboxMetadata(teamName: target.teamName, memberID: member.id, markBusy: true)
            memberSignals[member.id]?.yield()
        }
        appendTranscriptMessage(
            sessionID: member.sessionID,
            title: member.sessionTitle,
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
        signalStream: AsyncStream<Void>,
        executeTool: @escaping @Sendable (String, String, BridgeInvokeRequest) async -> BridgeInvokeResponse
    ) async {
        if await processMailbox(memberID: memberID, executeTool: executeTool) == false {
            return
        }

        for await _ in signalStream {
            if await processMailbox(memberID: memberID, executeTool: executeTool) == false {
                break
            }
        }
    }

    private func processMailbox(
        memberID: String,
        executeTool: @escaping @Sendable (String, String, BridgeInvokeRequest) async -> BridgeInvokeResponse
    ) async -> Bool {
        guard let resolved = resolveMember(memberID: memberID),
              let teamDirectoryURL = teamDirectoryURL(teamName: resolved.teamName)
        else {
            return true
        }

        let unreadMessages = TeamMailbox.unreadMessages(teamDirectoryURL: teamDirectoryURL, recipientName: resolved.member.name)
        guard !unreadMessages.isEmpty else {
            refreshMailboxMetadata(teamName: resolved.teamName, memberID: memberID)
            return true
        }

        for message in unreadMessages {
            guard let current = resolveMember(memberID: memberID) else {
                break
            }

            if message.messageType == "shutdown_request" {
                try? TeamMailbox.markRead(teamDirectoryURL: teamDirectoryURL, recipientName: current.member.name, messageIDs: [message.id])
                finishMember(teamName: current.teamName, memberID: memberID, status: .stopped, result: "Shutdown requested.", error: nil)
                appendTranscriptMessage(
                    sessionID: current.member.sessionID,
                    title: current.member.sessionTitle,
                    role: .system,
                    text: "Teammate stopped."
                )
                refreshMailboxMetadata(teamName: current.teamName, memberID: memberID)
                return false
            }

            if current.member.planModeRequired, !current.member.hasApprovedPlan, message.messageType != "approved_execution" {
                await runPlanStep(teamName: current.teamName, member: current.member, queuedMessage: message)
            } else {
                await runExecutionStep(teamName: current.teamName, member: current.member, queuedMessage: message, executeTool: executeTool)
            }

            try? TeamMailbox.markRead(teamDirectoryURL: teamDirectoryURL, recipientName: current.member.name, messageIDs: [message.id])
            refreshMailboxMetadata(teamName: current.teamName, memberID: memberID)
        }

        return true
    }

    private func runPlanStep(teamName: String, member: TeamMember, queuedMessage: TeamMailboxMessage) async {
        guard let modelConfig else {
            finishMember(teamName: teamName, memberID: member.id, status: .failed, result: nil, error: "No configured model for teammate planning.")
            return
        }
        updateMember(teamName: teamName, memberID: member.id) { member in
            member.status = .awaitingPlanApproval
            member.isIdle = true
            member.awaitingPlanApproval = true
            member.pendingExecutionPrompt = queuedMessage.text
            member.lastUpdatedAt = Date()
        }
        let wrappedPrompt = """
        You are teammate \(member.name) inside team \(teamName).
        Prepare an implementation plan only.
        Do not make edits or execute destructive tools.

        Assigned work from \(queuedMessage.from):
        \(queuedMessage.text)
        """

        do {
            let output = try await TeamSwarmRunner.runTurn(
                history: memberHistories[member.id] ?? [],
                prompt: wrappedPrompt,
                definition: SubAgentRegistry.plan,
                workspaceRootURL: workspaceRootURL,
                modelConfig: modelConfig,
                executeTool: { request in
                    BridgeInvokeResponse(
                        id: request.id,
                        ok: false,
                        error: OpenClawNodeError(code: .unavailable, message: "PLAN_MODE: tools are disabled until the coordinator approves the plan")
                    )
                }
            )
            memberHistories[member.id] = output.messages
            let planRequestID = persistPlanApprovalRequest(teamName: teamName, member: member, plan: output.content)
            updateMember(teamName: teamName, memberID: member.id) { member in
                member.lastPlan = output.content
                member.lastResult = output.content
                member.lastError = nil
                member.pendingPlanRequestID = planRequestID
                member.lastUpdatedAt = Date()
            }
            appendTranscriptMessage(sessionID: member.sessionID, title: member.sessionTitle, role: .assistant, text: output.content)
            if let team = teamsByName[teamName] {
                appendCoordinatorMessage(
                    team: team,
                    fromName: member.name,
                    text: "Proposed a plan and is waiting for approval.\n\n\(output.content)"
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
        queuedMessage: TeamMailboxMessage,
        executeTool: @escaping @Sendable (String, String, BridgeInvokeRequest) async -> BridgeInvokeResponse
    ) async {
        guard let modelConfig else {
            finishMember(teamName: teamName, memberID: member.id, status: .failed, result: nil, error: "No configured model for teammate execution.")
            return
        }
        let baseDefinition = SubAgentRegistry.definition(for: member.agentType) ?? SubAgentRegistry.generalPurpose
        let definition = SubAgentDefinition(
            agentType: baseDefinition.agentType,
            description: baseDefinition.description,
            systemPrompt: [
                baseDefinition.systemPrompt,
                "You are teammate \(member.name) in team \(teamName).",
                "Use team_task_list/team_task_update to coordinate work and team_message_send to communicate with the coordinator or peers.",
                "Do not create nested teams.",
            ].joined(separator: "\n\n"),
            toolPolicy: baseDefinition.toolPolicy,
            disallowedFunctionNames: baseDefinition.disallowedFunctionNames.union(["team_create", "team_delete"]),
            maxTurns: max(baseDefinition.maxTurns, 8),
            supportsBackground: true
        )

        updateMember(teamName: teamName, memberID: member.id) { member in
            member.status = .busy
            member.isIdle = false
            member.lastUpdatedAt = Date()
            member.lastError = nil
        }

        let prompt = executionPrompt(teamName: teamName, member: member, queuedMessage: queuedMessage)
        do {
            let output = try await TeamSwarmRunner.runTurn(
                history: memberHistories[member.id] ?? [],
                prompt: prompt,
                definition: definition,
                workspaceRootURL: workspaceRootURL,
                modelConfig: modelConfig,
                authorizeTool: { [definition] request in
                    definition.allowsTool(functionName: request.name)
                        ? .allow
                        : .deny("TOOL_NOT_ALLOWED: \(request.name)")
                },
                executeTool: { request in
                    await executeTool(teamName, member.id, request)
                }
            )
            memberHistories[member.id] = output.messages
            finishMember(teamName: teamName, memberID: member.id, status: .idle, result: output.content, error: nil)
            appendTranscriptMessage(sessionID: member.sessionID, title: member.sessionTitle, role: .assistant, text: output.content)
            if let team = teamsByName[teamName] {
                appendCoordinatorMessage(team: team, fromName: member.name, text: output.content)
            }
        } catch {
            finishMember(teamName: teamName, memberID: member.id, status: .failed, result: nil, error: error.localizedDescription)
        }
    }

    private func executionPrompt(teamName: String, member: TeamMember, queuedMessage: TeamMailboxMessage) -> String {
        let taskLines = teamsByName[teamName]?.tasks.sorted { $0.id < $1.id }.map { task in
            let owner = task.owner ?? "unassigned"
            return "- [#\(task.id)] \(task.status.rawValue) | owner=\(owner) | \(task.title)"
        }.joined(separator: "\n") ?? "- no tasks"
        return """
        You are teammate \(member.name) inside team \(teamName).
        Current team task list:
        \(taskLines)

        Latest message from \(queuedMessage.from):
        \(queuedMessage.text)
        """
    }

    private func finishMember(teamName: String, memberID: String, status: MemberStatus, result: String?, error: String?) {
        updateMember(teamName: teamName, memberID: memberID) { member in
            member.status = status
            member.isIdle = status == .idle || status == .awaitingPlanApproval || status == .stopped
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
                appendTranscriptMessage(sessionID: resolved.member.sessionID, title: resolved.member.sessionTitle, role: .system, text: "Error: \(error)")
                if let team = teamsByName[teamName] {
                    appendCoordinatorMessage(team: team, fromName: resolved.member.name, text: "Failed: \(error)")
                }
            } else if status == .idle {
                appendTranscriptMessage(sessionID: resolved.member.sessionID, title: resolved.member.sessionTitle, role: .system, text: "Teammate is idle.")
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
        updateMember(teamName: teamName, memberID: senderMemberID) { member in
            member.lastPeerMessageSummary = "To \(recipientName): \(summarize(message) ?? message)"
            member.lastUpdatedAt = Date()
        }
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

    private func writeMailboxMessage(
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

    private func refreshMailboxMetadata(teamName: String, memberID: String, markBusy: Bool = false) {
        guard let resolved = resolveMember(memberID: memberID),
              resolved.teamName == teamName,
              let teamDirectoryURL = teamDirectoryURL(teamName: teamName)
        else {
            return
        }
        let unreadCount = TeamMailbox.unreadCount(teamDirectoryURL: teamDirectoryURL, recipientName: resolved.member.name)
        let preview = summarize(TeamMailbox.lastPreview(teamDirectoryURL: teamDirectoryURL, recipientName: resolved.member.name))
        updateMember(teamName: teamName, memberID: memberID) { member in
            member.queuedMessageCount = unreadCount
            member.lastMailboxPreview = preview
            member.lastUpdatedAt = Date()
            if markBusy {
                member.status = .busy
                member.isIdle = false
            }
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

    private func coordinatorMailboxSummary(for teamName: String) -> (count: Int, preview: String?) {
        guard let teamDirectoryURL = teamDirectoryURL(teamName: teamName) else {
            return (0, nil)
        }
        return (
            TeamMailbox.unreadCount(teamDirectoryURL: teamDirectoryURL, recipientName: Self.coordinatorName),
            summarize(TeamMailbox.lastPreview(teamDirectoryURL: teamDirectoryURL, recipientName: Self.coordinatorName))
        )
    }

    private func resolveColor(for senderName: String, teamName: String) -> String? {
        guard senderName.caseInsensitiveCompare(Self.coordinatorName) != .orderedSame else {
            return nil
        }
        return teamsByName[teamName]?.members.first(where: { $0.name.caseInsensitiveCompare(senderName) == .orderedSame })?.colorName
    }

    private func appendCoordinatorMessage(team: TeamRecord, fromName: String, text: String) {
        appendTranscriptMessage(
            sessionID: team.coordinatorSessionID,
            title: nil,
            role: .system,
            text: "[\(team.name)/\(fromName)] \(text)"
        )
        notifyChanged()
    }

    private func appendTranscriptMessage(
        sessionID: String,
        title: String?,
        role: MessageRole,
        text: String
    ) {
        guard let runtimeRootURL else { return }
        let provider = TranscriptStorageProvider.provider(runtimeRootURL: runtimeRootURL)
        if let title {
            provider.setTitle(title, for: sessionID)
        }
        let existing = provider.messages(in: sessionID)
        let message = provider.createMessage(in: sessionID, role: role)
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
        return Self.coordinatorName
    }

    private func activeAgentID(from sessionID: String) -> String? {
        guard let separatorRange = sessionID.range(of: "::") else { return nil }
        let rawValue = String(sessionID[..<separatorRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        return rawValue.isEmpty || rawValue == "global" ? nil : rawValue
    }

    private func teammateSessionID(teamName: String, memberName: String) -> String {
        "team:\(teamName):member:\(memberName)"
    }

    private func persist() {
        synchronizeTeamDirectories()
    }

    private func loadPersistedTeams() {
        memberSignals.removeAll()
        memberTasks.values.forEach { $0.cancel() }
        memberTasks.removeAll()
        memberHistories.removeAll()

        let persistedFiles = loadTeamFilesFromDirectories() ?? [:]
        let teamProfiles = TeamStore.load().teams
        let agentByID = Dictionary(uniqueKeysWithValues: AgentStore.load().agents.map { ($0.id, $0) })
        let loadedTeams = teamProfiles.compactMap { teamRecord(for: $0, persisted: persistedFiles[$0.name], agentByID: agentByID) }

        guard !loadedTeams.isEmpty else {
            teamsByName.removeAll()
            return
        }

        teamsByName = Dictionary(uniqueKeysWithValues: loadedTeams.map { record in
            var team = record
            team.members = team.members.map { member in
                var member = member
                member.status = .stopped
                member.isIdle = true
                member.awaitingPlanApproval = member.pendingPlanRequestID != nil
                if let teamDirectoryURL = teamDirectoryURL(teamName: team.name) {
                    member.queuedMessageCount = TeamMailbox.unreadCount(teamDirectoryURL: teamDirectoryURL, recipientName: member.name)
                    member.lastMailboxPreview = summarize(TeamMailbox.lastPreview(teamDirectoryURL: teamDirectoryURL, recipientName: member.name))
                }
                return member
            }
            return (team.name, team)
        })
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
                        name: member.name,
                        agentType: member.agentType,
                        model: nil,
                        prompt: member.pendingExecutionPrompt,
                        color: member.colorName,
                        planModeRequired: member.planModeRequired,
                        joinedAt: member.spawnedAt,
                        sessionId: member.sessionID,
                        subscriptions: [],
                        backendType: member.backendType,
                        isActive: member.status != .stopped,
                        mode: member.permissionMode,
                        queuedMessageCount: member.queuedMessageCount,
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
        let members = profile.agentPoolIDs.enumerated().compactMap { offset, agentID -> TeamMember? in
            guard let agent = agentByID[agentID] else { return nil }
            let persistedMember = persisted?.members.first(where: { $0.agentId == agentID.uuidString })
            return TeamMember(
                id: agentID.uuidString,
                name: agent.name,
                agentType: persistedMember?.agentType ?? SubAgentRegistry.generalPurpose.agentType,
                sessionID: persistedMember?.sessionId ?? teammateSessionID(teamName: profile.name, memberName: agent.name),
                sessionTitle: "[\(profile.name)] \(agent.name)",
                workspacePath: agent.workspacePath,
                colorName: persistedMember?.color ?? colors[offset % colors.count],
                spawnedAt: persistedMember?.joinedAt ?? profile.createdAt,
                description: nil,
                planModeRequired: persistedMember?.planModeRequired ?? false,
                backendType: persistedMember?.backendType ?? .inProcess,
                permissionMode: persistedMember?.mode,
                status: MemberStatus(rawValue: persistedMember?.lastStatus ?? "stopped") ?? .stopped,
                isIdle: !(persistedMember?.isActive ?? false),
                awaitingPlanApproval: persistedMember?.pendingPlanRequestID != nil,
                hasApprovedPlan: (persistedMember?.planModeRequired ?? false) ? persistedMember?.pendingPlanRequestID == nil : true,
                pendingExecutionPrompt: persistedMember?.prompt,
                pendingPlanRequestID: persistedMember?.pendingPlanRequestID,
                lastPlan: nil,
                lastResult: nil,
                lastError: nil,
                lastUpdatedAt: persisted?.updatedAt ?? profile.updatedAt,
                shutdownRequested: false,
                queuedMessageCount: persistedMember?.queuedMessageCount,
                lastMailboxPreview: nil,
                lastIdleSummary: nil,
                lastPeerMessageSummary: nil
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
        runtimeRootURL?.appendingPathComponent("team-swarms", isDirectory: true)
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
