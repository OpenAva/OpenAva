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
            handlers[command] = { request in
                try await Self.handleTeamInvoke(
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
        struct EmptyParams: Decodable {}

        struct MessageParams: Decodable {
            let to: String
            let message: String
            let messageType: String?

            enum CodingKeys: String, CodingKey {
                case to
                case message
                case messageType = "message_type"
            }
        }

        struct ApproveParams: Decodable {
            let sessionID: String?
            let name: String?
            let feedback: String?

            enum CodingKeys: String, CodingKey {
                case sessionID = "session_id"
                case name
                case feedback
            }
        }

        struct TaskCreateParams: Decodable {
            let title: String
            let detail: String?
        }

        struct TaskGetParams: Decodable {
            let taskID: Int

            enum CodingKeys: String, CodingKey {
                case taskID = "task_id"
            }
        }

        struct TaskUpdateParams: Decodable {
            let taskID: Int
            let title: String?
            let detail: String?
            let owner: String?
            let status: String?
            let addBlockedBy: [Int]?

            enum CodingKeys: String, CodingKey {
                case taskID = "task_id"
                case title
                case detail
                case owner
                case status
                case addBlockedBy = "add_blocked_by"
            }
        }

        let context = toolContextProvider()

        switch request.command {
        case "team.status":
            _ = try ToolInvocationHelpers.decodeParams(EmptyParams.self, from: request.paramsJSON)
            guard let snapshot = TeamSwarmCoordinator.shared.snapshot(context: context) else {
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
                context: context
            )
            return BridgeInvokeResponse(id: request.id, ok: true, payload: "Message sent to \(params.to).")

        case "team.plan.approve":
            let params = try ToolInvocationHelpers.decodeParams(ApproveParams.self, from: request.paramsJSON)
            let member = try TeamSwarmCoordinator.shared.approvePlan(
                sessionID: params.sessionID,
                memberName: params.name,
                feedback: params.feedback,
                context: context
            )
            return BridgeInvokeResponse(id: request.id, ok: true, payload: "Approved plan for \(member.name).")

        case "team.task.create":
            let params = try ToolInvocationHelpers.decodeParams(TaskCreateParams.self, from: request.paramsJSON)
            let task = try TeamSwarmCoordinator.shared.createTask(title: params.title, detail: params.detail, context: context)
            return BridgeInvokeResponse(id: request.id, ok: true, payload: renderTask(task, heading: "Task Created"))

        case "team.task.list":
            _ = try ToolInvocationHelpers.decodeParams(EmptyParams.self, from: request.paramsJSON)
            let tasks = try TeamSwarmCoordinator.shared.listTasks(context: context)
            let completedTaskIDs = Set(tasks.filter { $0.status == .completed }.map(\.id))
            let lines = tasks.map { renderTaskLine($0, completedTaskIDs: completedTaskIDs) }
            let payload = (["## Team Tasks"] + (lines.isEmpty ? ["No tasks."] : lines)).joined(separator: "\n")
            return ToolInvocationHelpers.successResponse(id: request.id, payload: payload)

        case "team.task.get":
            let params = try ToolInvocationHelpers.decodeParams(TaskGetParams.self, from: request.paramsJSON)
            let task = try TeamSwarmCoordinator.shared.getTask(id: params.taskID, context: context)
            return BridgeInvokeResponse(id: request.id, ok: true, payload: renderTask(task, heading: "Task"))

        case "team.task.update":
            let params = try ToolInvocationHelpers.decodeParams(TaskUpdateParams.self, from: request.paramsJSON)
            let status = params.status.flatMap { TeamSwarmCoordinator.TaskStatus(rawValue: $0) }
            let wasTeammateInvocation = context.senderMemberID != nil
            let task = try TeamSwarmCoordinator.shared.updateTask(
                id: params.taskID,
                title: params.title,
                detail: params.detail,
                status: status,
                owner: params.owner,
                addBlockedBy: params.addBlockedBy ?? [],
                context: context
            )
            var payload = renderTask(task, heading: "Task Updated")
            if status == .completed, wasTeammateInvocation {
                payload += "\n\nTask completed. Call team_task_list now to find your next available task or see if your work unblocked others."
            }
            return BridgeInvokeResponse(id: request.id, ok: true, payload: payload)

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
            "- created_at: \(iso8601(team.createdAt))",
            "- updated_at: \(iso8601(team.updatedAt))",
            "- pending_permission_requests: \(pendingPermissions.count)",
            "",
            "### Members",
        ].compactMap { $0 }
        if team.members.isEmpty {
            lines.append("- none")
        } else {
            lines.append(contentsOf: team.members.map { member in
                let planMode = member.planModeRequired ? "required" : "off"
                let error = member.lastError ?? "none"
                return "- \(member.name) | status=\(member.status.rawValue) | agent_type=\(member.agentType) | plan_mode=\(planMode) | error=\(error)"
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
                let completedTaskIDs = Set(team.tasks.filter { $0.status == .completed }.map(\.id))
                var line = renderTaskLine(task, completedTaskIDs: completedTaskIDs)
                if let detail = task.detail, !detail.isEmpty {
                    line += " | detail=\(detail)"
                }
                return line
            })
        }
        return lines.joined(separator: "\n")
    }

    private static func renderTask(_ task: TeamSwarmCoordinator.TeamTask, heading: String) -> String {
        let unresolvedBlockedBy = unresolvedBlockedBy(task, completedTaskIDs: [])
        return [
            "## \(heading)",
            "- id: \(task.id)",
            "- title: \(task.title)",
            task.detail.map { "- detail: \($0)" },
            "- status: \(task.status.rawValue)",
            "- owner: \(task.owner ?? "unassigned")",
            unresolvedBlockedBy.isEmpty ? nil : "- blocked_by: \(unresolvedBlockedBy.map(String.init).joined(separator: ", "))",
        ].compactMap { $0 }.joined(separator: "\n")
    }

    private static func renderTaskLine(
        _ task: TeamSwarmCoordinator.TeamTask,
        completedTaskIDs: Set<Int>
    ) -> String {
        let unresolvedBlockedBy = unresolvedBlockedBy(task, completedTaskIDs: completedTaskIDs)
        let blockedSuffix = unresolvedBlockedBy.isEmpty
            ? ""
            : " | blocked_by=\(unresolvedBlockedBy.map(String.init).joined(separator: ","))"
        return "- [#\(task.id)] \(task.status.rawValue) | owner=\(task.owner ?? "unassigned")\(blockedSuffix) | \(task.title)"
    }

    private static func unresolvedBlockedBy(
        _ task: TeamSwarmCoordinator.TeamTask,
        completedTaskIDs: Set<Int>
    ) -> [Int] {
        task.blockedBy.filter { !completedTaskIDs.contains($0) }
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}
