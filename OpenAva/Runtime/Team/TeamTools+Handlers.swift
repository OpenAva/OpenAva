import Foundation
import OpenClawKit
import OpenClawProtocol

extension TeamTools {
    func registerHandlers(
        into handlers: inout [String: ToolHandler],
        context: ToolHandlerRegistrationContext
    ) {
        for command in ["team.status", "team.message.send", "team.plan.approve",
                        "team.task.create", "team.task.list", "team.task.get", "team.task.update"]
        {
            handlers[command] = { [weak self] request in
                guard self != nil else { throw ToolHandlerError.handlerUnavailable }
                return try await Self.handleTeamInvoke(
                    request,
                    toolContextProvider: context.teamToolContextProvider
                )
            }
        }
    }

    private static func handleTeamInvoke(
        _ request: BridgeInvokeRequest,
        toolContextProvider: @escaping @Sendable () -> TeamSwarmCoordinator.ToolContext
    ) async throws -> BridgeInvokeResponse {
        struct TeamNameParams: Decodable {
            let teamName: String?

            enum CodingKeys: String, CodingKey {
                case teamName = "team_name"
            }
        }

        struct MessageParams: Decodable {
            let to: String
            let message: String
            let teamName: String?
            let messageType: String?

            enum CodingKeys: String, CodingKey {
                case to
                case message
                case teamName = "team_name"
                case messageType = "message_type"
            }
        }

        struct ApproveParams: Decodable {
            let sessionID: String?
            let name: String?
            let teamName: String?
            let feedback: String?

            enum CodingKeys: String, CodingKey {
                case sessionID = "session_id"
                case name
                case teamName = "team_name"
                case feedback
            }
        }

        struct TaskCreateParams: Decodable {
            let title: String
            let detail: String?
            let teamName: String?

            enum CodingKeys: String, CodingKey {
                case title
                case detail
                case teamName = "team_name"
            }
        }

        struct TaskGetParams: Decodable {
            let taskID: Int
            let teamName: String?

            enum CodingKeys: String, CodingKey {
                case taskID = "task_id"
                case teamName = "team_name"
            }
        }

        struct TaskUpdateParams: Decodable {
            let taskID: Int
            let title: String?
            let detail: String?
            let owner: String?
            let status: String?
            let teamName: String?

            enum CodingKeys: String, CodingKey {
                case taskID = "task_id"
                case title
                case detail
                case owner
                case status
                case teamName = "team_name"
            }
        }

        let context = toolContextProvider()

        switch request.command {
        case "team.status":
            let params = try ToolInvocationHelpers.decodeParams(TeamNameParams.self, from: request.paramsJSON)
            guard let snapshot = TeamSwarmCoordinator.shared.snapshot(teamName: params.teamName, context: context) else {
                return BridgeInvokeResponse(
                    id: request.id,
                    ok: false,
                    error: OpenClawNodeError(code: .invalidRequest, message: "TEAM_NOT_FOUND")
                )
            }
            let payload = renderTeamStatus(snapshot)
            return ToolInvocationHelpers.successResponse(id: request.id, payload: payload)

        case "team.message.send":
            let params = try ToolInvocationHelpers.decodeParams(MessageParams.self, from: request.paramsJSON)
            try TeamSwarmCoordinator.shared.sendMessage(
                to: params.to,
                message: params.message,
                messageType: AppConfig.nonEmpty(params.messageType) ?? "message",
                teamName: params.teamName,
                context: context
            )
            return BridgeInvokeResponse(id: request.id, ok: true, payload: "Message sent to \(params.to).")

        case "team.plan.approve":
            let params = try ToolInvocationHelpers.decodeParams(ApproveParams.self, from: request.paramsJSON)
            let member = try TeamSwarmCoordinator.shared.approvePlan(
                sessionID: params.sessionID,
                memberName: params.name,
                teamName: params.teamName,
                feedback: params.feedback,
                context: context
            )
            return BridgeInvokeResponse(id: request.id, ok: true, payload: "Approved plan for \(member.name).")

        case "team.task.create":
            let params = try ToolInvocationHelpers.decodeParams(TaskCreateParams.self, from: request.paramsJSON)
            let task = try TeamSwarmCoordinator.shared.createTask(title: params.title, detail: params.detail, teamName: params.teamName, context: context)
            return BridgeInvokeResponse(id: request.id, ok: true, payload: renderTask(task, heading: "Task Created"))

        case "team.task.list":
            let params = try ToolInvocationHelpers.decodeParams(TeamNameParams.self, from: request.paramsJSON)
            let tasks = try TeamSwarmCoordinator.shared.listTasks(teamName: params.teamName, context: context)
            let lines = tasks.map { renderTaskLine($0) }
            let payload = (["## Team Tasks"] + (lines.isEmpty ? ["No tasks."] : lines)).joined(separator: "\n")
            return ToolInvocationHelpers.successResponse(id: request.id, payload: payload)

        case "team.task.get":
            let params = try ToolInvocationHelpers.decodeParams(TaskGetParams.self, from: request.paramsJSON)
            let task = try TeamSwarmCoordinator.shared.getTask(id: params.taskID, teamName: params.teamName, context: context)
            return BridgeInvokeResponse(id: request.id, ok: true, payload: renderTask(task, heading: "Task"))

        case "team.task.update":
            let params = try ToolInvocationHelpers.decodeParams(TaskUpdateParams.self, from: request.paramsJSON)
            let status = params.status.flatMap { TeamSwarmCoordinator.TaskStatus(rawValue: $0) }
            let task = try TeamSwarmCoordinator.shared.updateTask(
                id: params.taskID,
                teamName: params.teamName,
                title: params.title,
                detail: params.detail,
                status: status,
                owner: params.owner,
                context: context
            )
            return BridgeInvokeResponse(id: request.id, ok: true, payload: renderTask(task, heading: "Task Updated"))

        default:
            return BridgeInvokeResponse(
                id: request.id,
                ok: false,
                error: OpenClawNodeError(code: .invalidRequest, message: "INVALID_REQUEST: unknown team command")
            )
        }
    }

    // MARK: - Rendering

    private static func renderTeamStatus(_ snapshot: TeamSwarmCoordinator.TeamSnapshot) -> String {
        let team = snapshot.team
        let pendingPermissions = snapshot.pendingPermissions
        var lines = [
            "## Team Status",
            "- team_name: \(team.name)",
            team.description.map { "- description: \($0)" },
            "- coordinator_session_id: \(team.coordinatorSessionID)",
            "- created_at: \(iso8601(team.createdAt))",
            "- updated_at: \(iso8601(team.updatedAt))",
            "- pending_permission_requests: \(pendingPermissions.count)",
            "- coordinator_mailbox_unread: \(snapshot.coordinatorUnreadCount)",
            snapshot.coordinatorMailboxPreview.map { "- coordinator_mailbox_preview: \($0)" },
            "",
            "### Members",
        ].compactMap { $0 }
        if team.members.isEmpty {
            lines.append("- none")
        } else {
            lines.append(contentsOf: team.members.map { member in
                let backend = member.backendType?.rawValue ?? "in-process"
                let queued = member.queuedMessageCount ?? 0
                let planMode = member.planModeRequired ? "required" : "off"
                let preview = member.lastMailboxPreview ?? "none"
                let error = member.lastError ?? "none"
                return "- \(member.name) | status=\(member.status.rawValue) | agent_type=\(member.agentType) | backend=\(backend) | plan_mode=\(planMode) | queued=\(queued) | session_id=\(member.sessionID) | inbox=\(preview) | error=\(error)"
            })
        }

        if let allowedPaths = team.allowedPaths, !allowedPaths.isEmpty {
            lines.append("")
            lines.append("### Shared Allowed Paths")
            lines.append(contentsOf: allowedPaths.map { rule in
                "- \(rule.path) | tool=\(rule.toolName) | added_by=\(rule.addedBy) | added_at=\(iso8601(rule.addedAt))"
            })
        }

        if !pendingPermissions.isEmpty {
            lines.append("")
            lines.append("### Pending Permissions")
            lines.append(contentsOf: pendingPermissions.map { request in
                "- \(request.workerName) | kind=\(request.kind) | tool=\(request.toolName) | status=\(request.status.rawValue) | created_at=\(iso8601(request.createdAt)) | \(request.description)"
            })
        }
        lines.append("")
        lines.append("### Tasks")
        if team.tasks.isEmpty {
            lines.append("- none")
        } else {
            lines.append(contentsOf: team.tasks.sorted { $0.id < $1.id }.map { task in
                var line = renderTaskLine(task)
                if let detail = task.detail, !detail.isEmpty {
                    line += " | detail=\(detail)"
                }
                return line
            })
        }
        return lines.joined(separator: "\n")
    }

    private static func renderTask(_ task: TeamSwarmCoordinator.TeamTask, heading: String) -> String {
        [
            "## \(heading)",
            "- id: \(task.id)",
            "- title: \(task.title)",
            task.detail.map { "- detail: \($0)" },
            "- status: \(task.status.rawValue)",
            "- owner: \(task.owner ?? "unassigned")",
        ].compactMap { $0 }.joined(separator: "\n")
    }

    private static func renderTaskLine(_ task: TeamSwarmCoordinator.TeamTask) -> String {
        "- [#\(task.id)] \(task.status.rawValue) | owner=\(task.owner ?? "unassigned") | \(task.title)"
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}
