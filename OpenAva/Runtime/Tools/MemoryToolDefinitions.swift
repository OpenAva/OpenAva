import Foundation
import OpenClawKit
import OpenClawProtocol

/// Tool definitions for memory retrieval workflows.
struct MemoryToolDefinitions: ToolDefinitionProvider {
    func toolDefinitions() -> [ToolDefinition] {
        [
            ToolDefinition(
                functionName: "memory_history_search",
                command: "memory.history_search",
                description: "Search archived history events from HISTORY.md on demand using keyword or regex.",
                parametersSchema: AnyCodable([
                    "type": "object",
                    "properties": [
                        "query": [
                            "type": "string",
                            "description": "Keyword or regex pattern to search for",
                        ],
                        "mode": [
                            "type": "string",
                            "description": "Search mode: keyword or regex (default: keyword)",
                            "enum": ["keyword", "regex"],
                        ],
                        "caseInsensitive": [
                            "type": "boolean",
                            "description": "Whether keyword search is case-insensitive (default: true)",
                        ],
                        "limit": [
                            "type": "integer",
                            "description": "Maximum number of hits to return (default: 20, range: 1-200)",
                        ],
                    ],
                    "required": ["query"],
                    "additionalProperties": false,
                ] as [String: Any])
            ),
            ToolDefinition(
                functionName: "memory_write_long_term",
                command: "memory.write_long_term",
                description: "Update curated long-term memory in MEMORY.md. Prefer this over generic file writes for memory updates.",
                parametersSchema: AnyCodable([
                    "type": "object",
                    "properties": [
                        "content": [
                            "type": "string",
                            "description": "Memory content to write or append",
                        ],
                        "mode": [
                            "type": "string",
                            "description": "Write mode: replace overwrites the file, append adds a new block unless it already exists (default: append)",
                            "enum": ["replace", "append"],
                        ],
                    ],
                    "required": ["content"],
                    "additionalProperties": false,
                ] as [String: Any])
            ),
            ToolDefinition(
                functionName: "memory_append_history",
                command: "memory.append_history",
                description: "Append a timestamped factual history entry to HISTORY.md. Prefer this over generic file writes for history updates.",
                parametersSchema: AnyCodable([
                    "type": "object",
                    "properties": [
                        "entry": [
                            "type": "string",
                            "description": "History summary to append. The runtime adds the timestamp prefix.",
                        ],
                    ],
                    "required": ["entry"],
                    "additionalProperties": false,
                ] as [String: Any])
            ),
        ]
    }
}
