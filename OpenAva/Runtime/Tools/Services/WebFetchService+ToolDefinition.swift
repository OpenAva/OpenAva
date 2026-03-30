import Foundation
import OpenClawKit
import OpenClawProtocol

/// Tool definition provider for web fetch service
extension WebFetchService: ToolDefinitionProvider {
    func toolDefinitions() -> [ToolDefinition] {
        [
            ToolDefinition(
                functionName: "web_fetch",
                command: "web.fetch",
                description: "Fetch and extract content from a web page. Returns AI-friendly plain text sections (not JSON), including metadata and extracted content.",
                parametersSchema: AnyCodable([
                    "type": "object",
                    "properties": [
                        "url": [
                            "type": "string",
                            "description": "The URL to fetch content from",
                        ],
                        "extractMode": [
                            "type": "string",
                            "enum": ["text", "markdown"],
                            "description": "Content extraction mode: 'text' for plain text, 'markdown' for formatted markdown (default: markdown)",
                        ],
                        "maxChars": [
                            "type": "integer",
                            "minimum": 100,
                            "description": "Maximum characters to return (truncates when exceeded).",
                        ],
                    ],
                    "required": ["url"],
                    "additionalProperties": false,
                ] as [String: Any])
            ),
        ]
    }
}
