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

    static let teamLeadName = "team-lead"

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
        let colorName: String?
        let spawnedAt: Date
        let description: String?
        let planModeRequired: Bool
        var status: MemberStatus
        var isIdle: Bool
        var awaitingPlanApproval: Bool
        var hasApprovedPlan: Bool
        var pendingExecutionPrompt: String?
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
        let leadSessionID: String
        let createdAt: Date
        var updatedAt: Date
        var nextTaskID: Int
        var members: [TeamMember]
        var tasks: [TeamTask]
    }

    struct TeamSnapshot {
        let team: TeamRecord
    }

    struct MemberSnapshot {
        let teamName: String
        let member: TeamMember
        let teammates: [TeamMember]
        let tasks: [TeamTask]
    }

    private struct QueuedMessage {
        let fromName: String
        let body: String
        let messageType: String
    }

    private struct PersistedEnvelope: Codable {
        var teams: [TeamRecord]
    }

    private let colors = ["blue", "green", "orange", "pink", "purple", "teal"]
    private var runtimeRootURL: URL?
    private var workspaceRootURL: URL?
    private var modelConfig: AppConfig.LLMModel?
    private var teamsByName: [String: TeamRecord] = [:]
    private var memberStreams: [String: AsyncStream<QueuedMessage>.Continuation] = [:]
    private var memberTasks: [String: Task<Void, Never>] = [:]
    private var memberHistories: [String: [ChatRequestBody.Message]] = [:]
    private var loadedPersistencePath: String?

    private init() {}

    func configure(runtimeRootURL: URL?, workspaceRootURL: URL?, modelConfig: AppConfig.LLMModel?) {
        let normalizedPath = runtimeRootURL?.standardizedFileURL.path
        if loadedPersistencePath != normalizedPath {
            loadedPersistencePath = normalizedPath
            self.runtimeRootURL = runtimeRootURL?.standardizedFileURL
            loadPersistedTeams()
        } else {
            self.runtimeRootURL = runtimeRootURL?.standardizedFileURL
        }
        self.workspaceRootURL = workspaceRootURL?.standardizedFileURL
        self.modelConfig = modelConfig
    }

    func isTeammateSession(_ sessionID: String) -> Bool {
        sessionID.hasPrefix("team:")
    }

    func memberSnapshot(for sessionID: String) -> MemberSnapshot? {
        for team in teamsByName.values {
            if let member = team.members.first(where: { $0.sessionID == sessionID }) {
                return MemberSnapshot(
                    teamName: team.name,
                    member: member,
                    teammates: team.members.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending },
                    tasks: team.tasks.sorted { $0.id < $1.id }
                )
            }
        }
        return nil
    }

    func leadSnapshot(for sessionID: String?) -> TeamSnapshot? {
        guard let sessionID else { return nil }
        guard let team = teamsByName.values.first(where: { $0.leadSessionID == sessionID }) else {
            return nil
        }
        return TeamSnapshot(team: team)
    }

    func snapshot(teamName: String? = nil, context: ToolContext) -> TeamSnapshot? {
        guard let resolvedTeamName = resolveTeamName(explicitTeamName: teamName, context: context),
              let team = teamsByName[resolvedTeamName]
        else {
            return nil
        }
        return TeamSnapshot(team: team)
    }

    func createTeam(name: String, description: String?, context: ToolContext) throws -> TeamRecord {
        guard let leadSessionID = normalized(context.sessionID) else {
            throw TeamError("TEAM_CONTEXT_MISSING: active session is required for TeamCreate")
        }
        let teamName = sanitize(name)
        guard !teamName.isEmpty else {
            throw TeamError("INVALID_REQUEST: team_name must not be empty")
        }
        guard teamsByName[teamName] == nil else {
            throw TeamError("TEAM_EXISTS: \(teamName)")
        }
        let now = Date()
        let team = TeamRecord(
            name: teamName,
            description: normalized(description),
            leadSessionID: leadSessionID,
            createdAt: now,
            updatedAt: now,
            nextTaskID: 1,
            members: [],
            tasks: []
        )
        teamsByName[teamName] = team
        persist()
        notifyChanged()
        return team
    }

    func deleteTeam(teamName: String?, context: ToolContext) throws -> TeamRecord {
        guard let resolvedTeamName = resolveTeamName(explicitTeamName: teamName, context: context),
              let team = teamsByName.removeValue(forKey: resolvedTeamName)
        else {
            throw TeamError("TEAM_NOT_FOUND")
        }
        for member in team.members {
            memberStreams[member.id]?.finish()
            memberStreams.removeValue(forKey: member.id)
            memberHistories.removeValue(forKey: member.id)
            memberTasks.removeValue(forKey: member.id)?.cancel()
        }
        persist()
        notifyChanged()
        return team
    }

    func spawnMember(
        name: String,
        prompt: String,
        teamName: String?,
        agentType: String?,
        description: String?,
        planModeRequired: Bool,
        context: ToolContext,
        executeTool: @escaping @Sendable (String, String, BridgeInvokeRequest) async -> BridgeInvokeResponse
    ) throws -> TeamMember {
        guard let resolvedTeamName = resolveTeamName(explicitTeamName: teamName, context: context),
              var team = teamsByName[resolvedTeamName]
        else {
            throw TeamError("TEAM_NOT_FOUND")
        }
        let memberName = sanitize(name)
        guard !memberName.isEmpty else {
            throw TeamError("INVALID_REQUEST: teammate name must not be empty")
        }
        guard team.members.first(where: { $0.name.caseInsensitiveCompare(memberName) == .orderedSame }) == nil else {
            throw TeamError("TEAMMATE_EXISTS: \(memberName)")
        }

        let memberID = "\(memberName)@\(resolvedTeamName)"
        let sessionID = teammateSessionID(teamName: resolvedTeamName, memberName: memberName)
        let now = Date()
        let member = TeamMember(
            id: memberID,
            name: memberName,
            agentType: normalized(agentType) ?? SubAgentRegistry.generalPurpose.agentType,
            sessionID: sessionID,
            sessionTitle: "[\(resolvedTeamName)] \(memberName)",
            colorName: colors[team.members.count % colors.count],
            spawnedAt: now,
            description: normalized(description),
            planModeRequired: planModeRequired,
            status: .idle,
            isIdle: true,
            awaitingPlanApproval: false,
            hasApprovedPlan: !planModeRequired,
            pendingExecutionPrompt: nil,
            lastPlan: nil,
            lastResult: nil,
            lastError: nil,
            lastUpdatedAt: now,
            shutdownRequested: false,
            queuedMessageCount: 0,
            lastMailboxPreview: nil,
            lastIdleSummary: nil,
            lastPeerMessageSummary: nil
        )

        team.members.append(member)
        team.updatedAt = now
        teamsByName[resolvedTeamName] = team

        let stream = AsyncStream<QueuedMessage> { continuation in
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.memberStreams.removeValue(forKey: memberID)
                }
            }
            memberStreams[memberID] = continuation
        }

        let task: Task<Void, Never> = Task { [weak self] in
            guard let self else { return }
            await self.runMemberLoop(memberID: memberID, initialStream: stream, executeTool: executeTool)
        }
        memberTasks[memberID] = task

        appendTranscriptMessage(
            sessionID: sessionID,
            title: member.sessionTitle,
            role: .system,
            text: "Teammate \(memberName) joined team \(resolvedTeamName)."
        )
        persist()
        notifyChanged()

        try sendMessage(
            to: memberName,
            message: prompt,
            messageType: "task",
            teamName: resolvedTeamName,
            context: context
        )
        return member
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
        let senderName = senderName(for: context, teamName: resolvedTeamName) ?? Self.teamLeadName
        let isPeerMessage = senderName.caseInsensitiveCompare(Self.teamLeadName) != .orderedSame

        let transcriptLine = "[\(senderName)] \(body)"

        if target.caseInsensitiveCompare(Self.teamLeadName) == .orderedSame {
            appendLeaderMessage(team: team, fromName: senderName, text: body)
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
        memberStreams[member.id]?.yield(QueuedMessage(fromName: senderName, body: body, messageType: messageType))
        appendTranscriptMessage(
            sessionID: member.sessionID,
            title: member.sessionTitle,
            role: .user,
            text: transcriptLine
        )
        updateMember(teamName: resolvedTeamName, memberID: member.id) { member in
            member.status = .busy
            member.isIdle = false
            member.lastUpdatedAt = Date()
            member.queuedMessageCount = (member.queuedMessageCount ?? 0) + 1
            member.lastMailboxPreview = summarize(body)
        }
        if isPeerMessage {
            registerPeerSummary(teamName: resolvedTeamName, senderMemberID: context.senderMemberID, recipientName: member.name, message: body)
        }
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
        let pendingPrompt = member.pendingExecutionPrompt
        member.pendingExecutionPrompt = nil
        team.members[index] = member
        team.updatedAt = Date()
        teamsByName[target.teamName] = team

        if let pendingPrompt {
            let feedbackLine = normalized(feedback).map { "\n\nLeader feedback: \($0)" } ?? ""
            memberStreams[member.id]?.yield(
                QueuedMessage(
                    fromName: Self.teamLeadName,
                    body: pendingPrompt + feedbackLine,
                    messageType: "approved_execution"
                )
            )
        }
        appendTranscriptMessage(
            sessionID: member.sessionID,
            title: member.sessionTitle,
            role: .system,
            text: "Plan approved by \(senderName(for: context, teamName: target.teamName) ?? Self.teamLeadName)."
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
        initialStream: AsyncStream<QueuedMessage>,
        executeTool: @escaping @Sendable (String, String, BridgeInvokeRequest) async -> BridgeInvokeResponse
    ) async {
        for await message in initialStream {
            guard let resolved = resolveMember(memberID: memberID) else { continue }
            updateMember(teamName: resolved.teamName, memberID: memberID) { member in
                let current = member.queuedMessageCount ?? 0
                member.queuedMessageCount = max(current - 1, 0)
                member.lastUpdatedAt = Date()
            }
            if message.messageType == "shutdown_request" {
                finishMember(teamName: resolved.teamName, memberID: memberID, status: .stopped, result: "Shutdown requested.", error: nil)
                appendTranscriptMessage(
                    sessionID: resolved.member.sessionID,
                    title: resolved.member.sessionTitle,
                    role: .system,
                    text: "Teammate stopped."
                )
                break
            }

            if resolved.member.planModeRequired, !resolved.member.hasApprovedPlan {
                await runPlanStep(teamName: resolved.teamName, member: resolved.member, queuedMessage: message)
                continue
            }

            await runExecutionStep(teamName: resolved.teamName, member: resolved.member, queuedMessage: message, executeTool: executeTool)
        }
    }

    private func runPlanStep(teamName: String, member: TeamMember, queuedMessage: QueuedMessage) async {
        guard let modelConfig else {
            finishMember(teamName: teamName, memberID: member.id, status: .failed, result: nil, error: "No configured model for teammate planning.")
            return
        }
        updateMember(teamName: teamName, memberID: member.id) { member in
            member.status = .awaitingPlanApproval
            member.isIdle = true
            member.awaitingPlanApproval = true
            member.pendingExecutionPrompt = queuedMessage.body
            member.lastUpdatedAt = Date()
        }
        let wrappedPrompt = """
        You are teammate \(member.name) inside team \(teamName).
        Prepare an implementation plan only.
        Do not make edits or execute destructive tools.

        Assigned work from \(queuedMessage.fromName):
        \(queuedMessage.body)
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
                        error: OpenClawNodeError(code: .unavailable, message: "PLAN_MODE: tools are disabled until the leader approves the plan")
                    )
                }
            )
            memberHistories[member.id] = output.messages
            updateMember(teamName: teamName, memberID: member.id) { member in
                member.lastPlan = output.content
                member.lastResult = output.content
                member.lastError = nil
                member.lastUpdatedAt = Date()
            }
            appendTranscriptMessage(sessionID: member.sessionID, title: member.sessionTitle, role: .assistant, text: output.content)
            if let team = teamsByName[teamName] {
                appendLeaderMessage(
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
        queuedMessage: QueuedMessage,
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
                "Use TaskList/TaskUpdate to coordinate work and SendMessage to communicate with team-lead or peers.",
                "Do not create nested teams.",
            ].joined(separator: "\n\n"),
            toolPolicy: baseDefinition.toolPolicy,
            disallowedFunctionNames: baseDefinition.disallowedFunctionNames.union(["TeamCreate", "TeamDelete"]),
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
                executeTool: { request in
                    await executeTool(teamName, member.id, request)
                }
            )
            memberHistories[member.id] = output.messages
            finishMember(teamName: teamName, memberID: member.id, status: .idle, result: output.content, error: nil)
            appendTranscriptMessage(sessionID: member.sessionID, title: member.sessionTitle, role: .assistant, text: output.content)
            if let team = teamsByName[teamName] {
                appendLeaderMessage(team: team, fromName: member.name, text: output.content)
            }
        } catch {
            finishMember(teamName: teamName, memberID: member.id, status: .failed, result: nil, error: error.localizedDescription)
        }
    }

    private func executionPrompt(teamName: String, member: TeamMember, queuedMessage: QueuedMessage) -> String {
        let taskLines = teamsByName[teamName]?.tasks.sorted { $0.id < $1.id }.map { task in
            let owner = task.owner ?? "unassigned"
            return "- [#\(task.id)] \(task.status.rawValue) | owner=\(owner) | \(task.title)"
        }.joined(separator: "\n") ?? "- no tasks"
        return """
        You are teammate \(member.name) inside team \(teamName).
        Current team task list:
        \(taskLines)

        Latest message from \(queuedMessage.fromName):
        \(queuedMessage.body)
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
                    appendLeaderMessage(team: team, fromName: resolved.member.name, text: "Failed: \(error)")
                }
            } else if status == .idle {
                appendTranscriptMessage(sessionID: resolved.member.sessionID, title: resolved.member.sessionTitle, role: .system, text: "Teammate is idle.")
                if let team = teamsByName[teamName] {
                    let summary = summarize(result) ?? "No summary available."
                    appendLeaderMessage(team: team, fromName: resolved.member.name, text: "Idle update: \(summary)")
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
            appendLeaderMessage(team: team, fromName: sender, text: "Peer DM to \(recipientName): \(summarize(message) ?? message)")
        }
    }

    private func markMemberShutdownRequested(teamName: String, memberID: String) {
        updateMember(teamName: teamName, memberID: memberID) { member in
            member.shutdownRequested = true
            member.lastUpdatedAt = Date()
        }
    }

    private func appendLeaderMessage(team: TeamRecord, fromName: String, text: String) {
        appendTranscriptMessage(
            sessionID: team.leadSessionID,
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
            return teamsByName.values.first(where: { $0.leadSessionID == sessionID })?.name
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
        return Self.teamLeadName
    }

    private func teammateSessionID(teamName: String, memberName: String) -> String {
        "team:\(teamName):member:\(memberName)"
    }

    private func persist() {
        guard let persistenceURL else { return }
        let envelope = PersistedEnvelope(teams: Array(teamsByName.values).sorted { $0.name < $1.name })
        guard let data = try? JSONEncoder().encode(envelope) else { return }
        try? FileManager.default.createDirectory(at: persistenceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: persistenceURL, options: [.atomic])
    }

    private func loadPersistedTeams() {
        memberStreams.removeAll()
        memberTasks.values.forEach { $0.cancel() }
        memberTasks.removeAll()
        memberHistories.removeAll()
        guard let persistenceURL,
              let data = try? Data(contentsOf: persistenceURL),
              let envelope = try? JSONDecoder().decode(PersistedEnvelope.self, from: data)
        else {
            teamsByName.removeAll()
            return
        }
        teamsByName = Dictionary(uniqueKeysWithValues: envelope.teams.map { record in
            var team = record
            team.members = team.members.map { member in
                var member = member
                member.status = .stopped
                member.isIdle = true
                return member
            }
            return (team.name, team)
        })
    }

    private var persistenceURL: URL? {
        runtimeRootURL?.appendingPathComponent("team-swarms/state.json", isDirectory: false)
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
