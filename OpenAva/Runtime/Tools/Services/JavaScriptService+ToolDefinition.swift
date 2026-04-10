import Foundation
import OpenClawKit
import OpenClawProtocol

extension JavaScriptService: ToolDefinitionProvider {
    func toolDefinitions() -> [ToolDefinition] {
        [
            ToolDefinition(
                functionName: "javascript_execute",
                command: "javascript.execute",
                description: "Execute JavaScript with Apple system JavaScriptCore. The code runs as the body of an async function and can use openava.input, openava.session, and await openava.tools.call(functionName, args) for allowed tools.",
                parametersSchema: AnyCodable([
                    "type": "object",
                    "properties": [
                        "code": [
                            "type": "string",
                            "description": "JavaScript source code executed as the body of an async function. Use return to produce the final result.",
                        ],
                        "input": [
                            "description": "Optional JSON-serializable value exposed as openava.input in the JavaScript runtime.",
                        ],
                        "allowed_tools": [
                            "type": "array",
                            "description": "Optional allowlist of tool function names callable from JavaScript. Defaults to built-in read-only tools.",
                            "items": [
                                "type": "string",
                            ],
                        ],
                        "session_id": [
                            "type": "string",
                            "description": "Optional persistent JavaScript session id. When provided, later calls with the same id reuse the same JS context, preserving variables, functions, and openava.session state.",
                        ],
                        "timeout_ms": [
                            "type": "integer",
                            "description": "Best-effort execution timeout in milliseconds (default: 15000, max: 120000).",
                        ],
                    ],
                    "required": ["code"],
                    "additionalProperties": false,
                ] as [String: Any])
            ),
        ]
    }
}
