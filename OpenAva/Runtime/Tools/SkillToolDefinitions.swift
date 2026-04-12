import Foundation
import OpenClawKit
import OpenClawProtocol

/// Tool definition for invoking a skill by stable skill name.
final class SkillToolDefinitions: ToolDefinitionProvider {
    func toolDefinitions() -> [ToolDefinition] {
        [
            ToolDefinition(
                functionName: "skill_invoke",
                command: "skill.invoke",
                description: "Invoke a skill from the available skills catalog by exact skill name. Use it when the user's request matches a listed skill or when the user explicitly invokes a skill. Call this before responding about the task.",
                parametersSchema: AnyCodable([
                    "type": "object",
                    "properties": [
                        "name": [
                            "type": "string",
                            "description": "Stable skill name from the injected skills list",
                        ],
                        "task": [
                            "type": "string",
                            "description": "Optional task or arguments for the skill. Required for fork-context skills.",
                        ],
                    ],
                    "required": ["name"],
                    "additionalProperties": false,
                ] as [String: Any])
            ),
        ]
    }
}
