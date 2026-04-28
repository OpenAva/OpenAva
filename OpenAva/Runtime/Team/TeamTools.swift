import Foundation
import OpenClawKit
import OpenClawProtocol

final class TeamTools: ToolDefinitionProvider {
    func toolDefinitions() -> [ToolDefinition] {
        [
            ToolDefinition(
                functionName: "team_status",
                command: "team.status",
                description: "Inspect the current team, teammate status, pending approvals, and shared tasks.",
                parametersSchema: AnyCodable([
                    "type": "object",
                    "properties": [:],
                    "additionalProperties": false,
                ] as [String: Any]),
                isReadOnly: true,
                isConcurrencySafe: true
            ),
            ToolDefinition(
                functionName: "team_message_send",
                command: "team.message.send",
                description: "Send a direct team message to a named teammate, or between teammates.",
                parametersSchema: AnyCodable([
                    "type": "object",
                    "properties": [
                        "to": [
                            "type": "string",
                            "description": "Recipient teammate name",
                        ],
                        "message": [
                            "type": "string",
                            "description": "Message body",
                        ],
                        "message_type": [
                            "type": "string",
                            "description": "Optional message type. Use shutdown_request to stop a teammate.",
                            "enum": ["message", "task", "approved_execution", "shutdown_request"],
                        ],
                    ],
                    "required": ["to", "message"],
                    "additionalProperties": false,
                ] as [String: Any])
            ),
            ToolDefinition(
                functionName: "team_plan_approve",
                command: "team.plan.approve",
                description: "Approve a teammate's pending plan request so it can start execution.",
                parametersSchema: AnyCodable([
                    "type": "object",
                    "properties": [
                        "session_id": [
                            "type": "string",
                            "description": "Teammate session id when approving from the UI context",
                        ],
                        "name": [
                            "type": "string",
                            "description": "Teammate name when approving from the main chat",
                        ],
                        "feedback": [
                            "type": "string",
                            "description": "Optional feedback appended to the approval",
                        ],
                    ],
                    "additionalProperties": false,
                ] as [String: Any])
            ),
            ToolDefinition(
                functionName: "team_task_create",
                command: "team.task.create",
                description: "Create a shared task in the active team task list.",
                parametersSchema: AnyCodable([
                    "type": "object",
                    "properties": [
                        "title": [
                            "type": "string",
                            "description": "Task title",
                        ],
                        "detail": [
                            "type": "string",
                            "description": "Optional task detail",
                        ],
                    ],
                    "required": ["title"],
                    "additionalProperties": false,
                ] as [String: Any])
            ),
            ToolDefinition(
                functionName: "team_task_list",
                command: "team.task.list",
                description: "List tasks in the active team task list.",
                parametersSchema: AnyCodable([
                    "type": "object",
                    "properties": [:],
                    "additionalProperties": false,
                ] as [String: Any]),
                isReadOnly: true,
                isConcurrencySafe: true
            ),
            ToolDefinition(
                functionName: "team_task_get",
                command: "team.task.get",
                description: "Get a single task from the active team task list.",
                parametersSchema: AnyCodable([
                    "type": "object",
                    "properties": [
                        "task_id": [
                            "type": "integer",
                            "description": "Numeric task id",
                        ],
                    ],
                    "required": ["task_id"],
                    "additionalProperties": false,
                ] as [String: Any]),
                isReadOnly: true,
                isConcurrencySafe: true
            ),
            ToolDefinition(
                functionName: "team_task_update",
                command: "team.task.update",
                description: "Update task title, detail, owner, or status in the shared team task list.",
                parametersSchema: AnyCodable([
                    "type": "object",
                    "properties": [
                        "task_id": [
                            "type": "integer",
                            "description": "Numeric task id",
                        ],
                        "title": [
                            "type": "string",
                            "description": "Optional new task title",
                        ],
                        "detail": [
                            "type": "string",
                            "description": "Optional new task detail",
                        ],
                        "owner": [
                            "type": "string",
                            "description": "Optional owner name",
                        ],
                        "status": [
                            "type": "string",
                            "description": "Optional new status",
                            "enum": TeamSwarmCoordinator.TaskStatus.allCases.map(\.rawValue),
                        ],
                        "add_blocked_by": [
                            "type": "array",
                            "description": "Optional task ids that must be completed before this task is available",
                            "items": [
                                "type": "integer",
                            ],
                        ],
                    ],
                    "required": ["task_id"],
                    "additionalProperties": false,
                ] as [String: Any])
            ),
        ]
    }
}
