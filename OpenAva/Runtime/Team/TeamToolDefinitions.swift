import Foundation
import OpenClawKit
import OpenClawProtocol

struct TeamToolDefinitions: ToolDefinitionProvider {
    func toolDefinitions() -> [ToolDefinition] {
        [
            ToolDefinition(
                functionName: "TeamCreate",
                command: "team.create",
                description: "Create a multi-agent team with shared teammates and task list.",
                parametersSchema: AnyCodable([
                    "type": "object",
                    "properties": [
                        "team_name": [
                            "type": "string",
                            "description": "Name for the team",
                        ],
                        "description": [
                            "type": "string",
                            "description": "Optional team purpose",
                        ],
                    ],
                    "required": ["team_name"],
                    "additionalProperties": false,
                ] as [String: Any])
            ),
            ToolDefinition(
                functionName: "TeamDelete",
                command: "team.delete",
                description: "Delete the current team and stop its teammates.",
                parametersSchema: AnyCodable([
                    "type": "object",
                    "properties": [
                        "team_name": [
                            "type": "string",
                            "description": "Optional explicit team name. Defaults to the caller's active team.",
                        ],
                    ],
                    "additionalProperties": false,
                ] as [String: Any])
            ),
            ToolDefinition(
                functionName: "TeamStatus",
                command: "team.status",
                description: "Inspect the current team, teammates, and shared tasks.",
                parametersSchema: AnyCodable([
                    "type": "object",
                    "properties": [
                        "team_name": [
                            "type": "string",
                            "description": "Optional explicit team name. Defaults to the caller's active team.",
                        ],
                    ],
                    "additionalProperties": false,
                ] as [String: Any])
            ),
            ToolDefinition(
                functionName: "Agent",
                command: "team.agent",
                description: "Spawn a teammate inside the active team and give it an initial task.",
                parametersSchema: AnyCodable([
                    "type": "object",
                    "properties": [
                        "name": [
                            "type": "string",
                            "description": "Teammate display name",
                        ],
                        "prompt": [
                            "type": "string",
                            "description": "Initial work assignment for the teammate",
                        ],
                        "team_name": [
                            "type": "string",
                            "description": "Optional explicit team name. Defaults to the caller's active team.",
                        ],
                        "agent_type": [
                            "type": "string",
                            "description": "Optional sub agent type. Defaults to general-purpose.",
                            "enum": SubAgentRegistry.availableAgentTypes(),
                        ],
                        "description": [
                            "type": "string",
                            "description": "Optional role description",
                        ],
                        "plan_mode_required": [
                            "type": "boolean",
                            "description": "When true, the teammate must propose a plan before execution.",
                        ],
                    ],
                    "required": ["name", "prompt"],
                    "additionalProperties": false,
                ] as [String: Any])
            ),
            ToolDefinition(
                functionName: "SendMessage",
                command: "team.message.send",
                description: "Send a direct message between team lead and teammates, or between teammates.",
                parametersSchema: AnyCodable([
                    "type": "object",
                    "properties": [
                        "to": [
                            "type": "string",
                            "description": "Recipient name, such as team-lead or a teammate name",
                        ],
                        "message": [
                            "type": "string",
                            "description": "Message body",
                        ],
                        "team_name": [
                            "type": "string",
                            "description": "Optional explicit team name. Defaults to the caller's active team.",
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
                functionName: "TeamApprovePlan",
                command: "team.plan.approve",
                description: "Approve a teammate's pending plan so it can start execution.",
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
                        "team_name": [
                            "type": "string",
                            "description": "Optional explicit team name. Defaults to the caller's active team.",
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
                functionName: "TaskCreate",
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
                        "team_name": [
                            "type": "string",
                            "description": "Optional explicit team name. Defaults to the caller's active team.",
                        ],
                    ],
                    "required": ["title"],
                    "additionalProperties": false,
                ] as [String: Any])
            ),
            ToolDefinition(
                functionName: "TaskList",
                command: "team.task.list",
                description: "List tasks in the active team task list.",
                parametersSchema: AnyCodable([
                    "type": "object",
                    "properties": [
                        "team_name": [
                            "type": "string",
                            "description": "Optional explicit team name. Defaults to the caller's active team.",
                        ],
                    ],
                    "additionalProperties": false,
                ] as [String: Any])
            ),
            ToolDefinition(
                functionName: "TaskGet",
                command: "team.task.get",
                description: "Get a single task from the active team task list.",
                parametersSchema: AnyCodable([
                    "type": "object",
                    "properties": [
                        "task_id": [
                            "type": "integer",
                            "description": "Numeric task id",
                        ],
                        "team_name": [
                            "type": "string",
                            "description": "Optional explicit team name. Defaults to the caller's active team.",
                        ],
                    ],
                    "required": ["task_id"],
                    "additionalProperties": false,
                ] as [String: Any])
            ),
            ToolDefinition(
                functionName: "TaskUpdate",
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
                        "team_name": [
                            "type": "string",
                            "description": "Optional explicit team name. Defaults to the caller's active team.",
                        ],
                    ],
                    "required": ["task_id"],
                    "additionalProperties": false,
                ] as [String: Any])
            ),
        ]
    }
}
