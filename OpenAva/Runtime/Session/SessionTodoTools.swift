import Foundation
import OpenClawKit
import OpenClawProtocol

final class SessionTodoTools: ToolDefinitionProvider {
    func toolDefinitions() -> [ToolDefinition] {
        [
            ToolDefinition(
                functionName: "todo_write",
                command: "todo.write",
                description: "Create and maintain the current session task checklist. Use it proactively for complex multi-step work, keep exactly one task in_progress, and clear the checklist when everything is completed.",
                parametersSchema: AnyCodable([
                    "type": "object",
                    "properties": [
                        "todos": [
                            "type": "array",
                            "description": "The updated task checklist for the current session.",
                            "items": [
                                "type": "object",
                                "properties": [
                                    "content": [
                                        "type": "string",
                                        "description": "Short task description shown to the user.",
                                    ],
                                    "status": [
                                        "type": "string",
                                        "enum": ["pending", "in_progress", "completed"],
                                        "description": "Current execution status for this task.",
                                    ],
                                    "activeForm": [
                                        "type": "string",
                                        "description": "Present-tense phrasing used while the task is active, such as 'Running tests'.",
                                    ],
                                ],
                                "required": ["content", "status", "activeForm"],
                                "additionalProperties": false,
                            ],
                        ],
                    ],
                    "required": ["todos"],
                    "additionalProperties": false,
                ] as [String: Any]),
                isReadOnly: false,
                isDestructive: false,
                isConcurrencySafe: false,
                maxResultSizeChars: 16 * 1024
            ),
        ]
    }
}
