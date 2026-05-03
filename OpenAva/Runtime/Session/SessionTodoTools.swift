import Foundation
import OpenClawKit
import OpenClawProtocol

final class SessionTodoTools: ToolDefinitionProvider {
    static let functionName = "todo_write"

    private static let toolDescription = """
    Update the todo list for the current session. To be used proactively and often to track progress and pending tasks.
    Use this tool for complex multi-step work, non-trivial tasks, explicit todo-list requests, and when the user provides multiple tasks.
    Do not use it for a single straightforward task, trivial work, or purely conversational/informational requests.
    Keep exactly one task in_progress whenever the list is active, mark tasks completed immediately after finishing them, and clear the list when every task is completed.
    Always provide both content (imperative) and activeForm (present continuous) for each task.
    """

    func toolDefinitions() -> [ToolDefinition] {
        [
            ToolDefinition(
                functionName: Self.functionName,
                command: "todo.write",
                description: Self.toolDescription,
                parametersSchema: AnyCodable([
                    "type": "object",
                    "properties": [
                        "todos": [
                            "type": "array",
                            "description": "The updated todo list for the current session.",
                            "items": [
                                "type": "object",
                                "properties": [
                                    "content": [
                                        "type": "string",
                                        "minLength": 1,
                                        "description": "Imperative task description, such as 'Run tests'.",
                                    ],
                                    "status": [
                                        "type": "string",
                                        "enum": ["pending", "in_progress", "completed"],
                                        "description": "Current execution status for this task.",
                                    ],
                                    "activeForm": [
                                        "type": "string",
                                        "minLength": 1,
                                        "description": "Present continuous phrasing shown while the task is active, such as 'Running tests'.",
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
                maxResultSizeChars: 100 * 1024
            ),
        ]
    }
}
