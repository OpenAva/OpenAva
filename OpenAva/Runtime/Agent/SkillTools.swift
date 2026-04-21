import Foundation
import OpenClawKit
import OpenClawProtocol

/// Tool definition for invoking a skill by stable skill name.
final class SkillTools: ToolDefinitionProvider {
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
            ToolDefinition(
                functionName: "skill_upsert",
                command: "skill.upsert",
                description: "Create or update a runtime skill when the current task reveals a reusable multi-step workflow worth reusing in future tasks. Use this sparingly for durable procedural knowledge, not one-off task details.",
                parametersSchema: AnyCodable([
                    "type": "object",
                    "properties": [
                        "name": [
                            "type": "string",
                            "description": "Stable skill name or slug. Reuse an existing slug to refine an existing runtime skill.",
                        ],
                        "description": [
                            "type": "string",
                            "description": "Concise one-line summary of the reusable workflow",
                        ],
                        "whenToUse": [
                            "type": "string",
                            "description": "Short trigger condition describing when this skill should be invoked",
                        ],
                        "content": [
                            "type": "string",
                            "description": "Full skill instructions in markdown",
                        ],
                        "userInvocable": [
                            "type": "boolean",
                            "description": "Whether users may explicitly invoke this skill",
                        ],
                        "supportingFiles": [
                            "type": "array",
                            "description": "Optional supporting files to attach under references/, templates/, or scripts/",
                            "items": [
                                "type": "object",
                                "properties": [
                                    "path": ["type": "string"],
                                    "content": ["type": "string"],
                                ],
                                "required": ["path", "content"],
                                "additionalProperties": false,
                            ],
                        ],
                    ],
                    "required": ["name", "description", "whenToUse", "content"],
                    "additionalProperties": false,
                ] as [String: Any]),
                isReadOnly: false,
                isDestructive: true,
                isConcurrencySafe: false
            ),
        ]
    }
}
