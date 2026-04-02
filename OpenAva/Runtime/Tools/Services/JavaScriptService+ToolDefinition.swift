import Foundation
import OpenClawKit
import OpenClawProtocol

extension JavaScriptService: ToolDefinitionProvider {
    func toolDefinitions() -> [ToolDefinition] {
        [
            ToolDefinition(
                functionName: "javascript_execute",
                command: "javascript.execute",
                description: "Execute JavaScript with Apple system JavaScriptCore. Best for deterministic parsing, data reshaping, filtering, sorting, grouping, aggregation, validation, numeric computation, and combining tool outputs into stable structured results. The code runs inside an async function body, so use return for the final result and await openava.tools.call(functionName, args) to invoke allowed tools. Provide session_id when you want later calls to reuse variables and functions from the same JavaScript session.",
                parametersSchema: AnyCodable([
                    "type": "object",
                    "properties": [
                        "code": [
                            "type": "string",
                            "description": "JavaScript source code executed as the body of an async function. Prefer concise deterministic scripts. Use return to produce the final result.",
                        ],
                        "input": [
                            "description": "Optional JSON-serializable value exposed as openava.input in the JavaScript runtime. Put task data here instead of hardcoding it into code whenever practical.",
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
