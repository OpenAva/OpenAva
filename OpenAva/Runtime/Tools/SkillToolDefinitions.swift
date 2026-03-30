import Foundation
import OpenClawKit
import OpenClawProtocol

/// Tool definition for loading skill markdown by stable skill id.
struct SkillToolDefinitions: ToolDefinitionProvider {
    func toolDefinitions() -> [ToolDefinition] {
        [
            ToolDefinition(
                functionName: "skill_load",
                command: "skill.load",
                description: "Load a skill markdown playbook by skill id.",
                parametersSchema: AnyCodable([
                    "type": "object",
                    "properties": [
                        "id": [
                            "type": "string",
                            "description": "Stable skill id from the injected skills list",
                        ],
                    ],
                    "required": ["id"],
                    "additionalProperties": false,
                ] as [String: Any])
            ),
        ]
    }
}
