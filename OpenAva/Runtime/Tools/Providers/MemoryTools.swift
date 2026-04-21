import Foundation
import OpenClawKit
import OpenClawProtocol

/// Tool definitions for memory retrieval workflows.
final class MemoryTools: ToolDefinitionProvider {
    func toolDefinitions() -> [ToolDefinition] {
        [
            ToolDefinition(
                functionName: "memory_recall",
                command: "memory.recall",
                description: "Recall relevant durable memories from the shared memory pool by searching indexed memory topics across all agents.",
                parametersSchema: AnyCodable([
                    "type": "object",
                    "properties": [
                        "query": [
                            "type": "string",
                            "description": "Natural language query describing the memory you want to recall",
                        ],
                        "limit": [
                            "type": "integer",
                            "description": "Maximum number of memory hits to return (default: 5, range: 1-20)",
                        ],
                    ],
                    "required": ["query"],
                    "additionalProperties": false,
                ] as [String: Any]),
                isReadOnly: true,
                isConcurrencySafe: true,
                maxResultSizeChars: 24 * 1024
            ),
            ToolDefinition(
                functionName: "memory_upsert",
                command: "memory.upsert",
                description: "Create or update a durable typed memory topic in the shared memory pool accessible to all agents.",
                parametersSchema: AnyCodable([
                    "type": "object",
                    "properties": [
                        "name": [
                            "type": "string",
                            "description": "Short human-readable memory title",
                        ],
                        "type": [
                            "type": "string",
                            "description": "Memory type",
                            "enum": ["user", "feedback", "project", "reference"],
                        ],
                        "description": [
                            "type": "string",
                            "description": "One-line description for the memory index",
                        ],
                        "content": [
                            "type": "string",
                            "description": "Full durable memory content to store in the topic file",
                        ],
                        "slug": [
                            "type": "string",
                            "description": "Optional stable slug / filename stem for updates",
                        ],
                        "expiresAt": [
                            "type": "string",
                            "description": "Optional ISO 8601 expiration timestamp after which this memory becomes inactive",
                        ],
                        "conflictsWith": [
                            "type": "array",
                            "description": "Optional list of memory slugs that should be marked inactive due to conflict with this memory",
                            "items": [
                                "type": "string",
                            ],
                        ],
                    ],
                    "required": ["name", "type", "description", "content"],
                    "additionalProperties": false,
                ] as [String: Any]),
                isReadOnly: false,
                isDestructive: true,
                isConcurrencySafe: false
            ),
            ToolDefinition(
                functionName: "memory_forget",
                command: "memory.forget",
                description: "Remove a stale durable memory topic from the shared memory pool by slug / filename stem.",
                parametersSchema: AnyCodable([
                    "type": "object",
                    "properties": [
                        "slug": [
                            "type": "string",
                            "description": "Memory slug or filename stem to delete",
                        ],
                    ],
                    "required": ["slug"],
                    "additionalProperties": false,
                ] as [String: Any]),
                isReadOnly: false,
                isDestructive: true,
                isConcurrencySafe: false
            ),
            ToolDefinition(
                functionName: "memory_transcript_search",
                command: "memory.transcript_search",
                description: "Search persisted agent transcripts when durable memory is insufficient and exact past conversation details matter.",
                parametersSchema: AnyCodable([
                    "type": "object",
                    "properties": [
                        "query": [
                            "type": "string",
                            "description": "Keyword or phrase to search for in persisted transcripts",
                        ],
                        "sessionID": [
                            "type": "string",
                            "description": "Optional session identifier to limit search to one transcript",
                        ],
                        "caseInsensitive": [
                            "type": "boolean",
                            "description": "Whether to perform case-insensitive matching (default: true)",
                        ],
                        "limit": [
                            "type": "integer",
                            "description": "Maximum number of hits to return (default: 20, range: 1-100)",
                        ],
                    ],
                    "required": ["query"],
                    "additionalProperties": false,
                ] as [String: Any]),
                isReadOnly: true,
                isConcurrencySafe: true,
                maxResultSizeChars: 24 * 1024
            ),
        ]
    }
}
