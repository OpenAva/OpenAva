import Foundation
import OpenClawKit
import OpenClawProtocol

final class SubAgentTools: ToolDefinitionProvider {
    func toolDefinitions() -> [ToolDefinition] {
        let availableTypes = SubAgentRegistry.availableAgentTypes().joined(separator: ", ")

        return [
            ToolDefinition(
                functionName: "subagent_run",
                command: "subagent.run",
                description: "Launch a focused sub agent for delegated work. Available types: \(availableTypes). Sub agents run with isolated context and cannot recursively spawn more sub agents in this version.",
                parametersSchema: AnyCodable([
                    "type": "object",
                    "properties": [
                        "description": [
                            "type": "string",
                            "description": "Short one-line description of the delegated task",
                        ],
                        "prompt": [
                            "type": "string",
                            "description": "The detailed task the sub agent should execute",
                        ],
                        "subagent_type": [
                            "type": "string",
                            "description": "Optional agent type. Defaults to general-purpose.",
                            "enum": SubAgentRegistry.availableAgentTypes(),
                        ],
                        "run_in_background": [
                            "type": "boolean",
                            "description": "When true, launch the sub agent asynchronously and return a task id immediately.",
                        ],
                    ],
                    "required": ["description", "prompt"],
                    "additionalProperties": false,
                ] as [String: Any])
            ),
            ToolDefinition(
                functionName: "subagent_status",
                command: "subagent.status",
                description: "Check the latest status of an asynchronously running sub agent task.",
                parametersSchema: AnyCodable([
                    "type": "object",
                    "properties": [
                        "task_id": [
                            "type": "string",
                            "description": "Task id returned by subagent_run when run_in_background is true",
                        ],
                    ],
                    "required": ["task_id"],
                    "additionalProperties": false,
                ] as [String: Any])
            ),
            ToolDefinition(
                functionName: "subagent_cancel",
                command: "subagent.cancel",
                description: "Cancel a running background sub agent task.",
                parametersSchema: AnyCodable([
                    "type": "object",
                    "properties": [
                        "task_id": [
                            "type": "string",
                            "description": "Task id returned by subagent_run when run_in_background is true",
                        ],
                    ],
                    "required": ["task_id"],
                    "additionalProperties": false,
                ] as [String: Any])
            ),
        ]
    }
}
