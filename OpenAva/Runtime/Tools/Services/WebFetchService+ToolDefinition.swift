import Foundation
import OpenClawKit
import OpenClawProtocol

/// Tool definition provider for web fetch service
extension WebFetchService: ToolDefinitionProvider {
    nonisolated func toolDefinitions() -> [ToolDefinition] {
        [
            ToolDefinition(
                functionName: "web_fetch",
                command: "web.fetch",
                description: "Fetch web content and apply a task-specific prompt to the extracted page text. Returns AI-friendly plain text with metadata and the processed result.",
                parametersSchema: AnyCodable([
                    "type": "object",
                    "properties": [
                        "url": [
                            "type": "string",
                            "description": "The URL to fetch content from",
                        ],
                        "prompt": [
                            "type": "string",
                            "description": "The task or question to apply to the fetched content",
                        ],
                    ],
                    "required": ["url", "prompt"],
                    "additionalProperties": false,
                ] as [String: Any]),
                isReadOnly: true,
                isConcurrencySafe: true,
                maxResultSizeChars: 48 * 1024
            ),
        ]
    }
}
