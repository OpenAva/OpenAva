import Foundation
import OpenClawKit
import OpenClawProtocol

extension WebSearchService: ToolDefinitionProvider {
    nonisolated func toolDefinitions() -> [ToolDefinition] {
        [
            ToolDefinition(
                functionName: "web_search",
                command: "web.search",
                description: "Search the web without API keys using multiple public sources, then deduplicate and rerank results. Returns title, link, summary, domain, rank, and source.",
                parametersSchema: AnyCodable([
                    "type": "object",
                    "properties": [
                        "query": [
                            "type": "string",
                            "description": "Search query text",
                        ],
                        "topK": [
                            "type": "integer",
                            "minimum": 1,
                            "maximum": 20,
                            "description": "Maximum results to return (default: 8)",
                        ],
                        "fetchTopK": [
                            "type": "integer",
                            "minimum": 0,
                            "maximum": 10,
                            "description": "Fetch full page text for top K results for better reranking (default: 3)",
                        ],
                        "lang": [
                            "type": "string",
                            "description": "Preferred language, e.g. zh-CN, en-US (default: zh-CN)",
                        ],
                        "safeSearch": [
                            "type": "string",
                            "enum": ["off", "moderate", "strict"],
                            "description": "Safety filtering mode (default: moderate)",
                        ],
                    ],
                    "required": ["query"],
                    "additionalProperties": false,
                ] as [String: Any]),
                isReadOnly: true,
                isConcurrencySafe: true,
                maxResultSizeChars: 32 * 1024
            ),
        ]
    }
}
