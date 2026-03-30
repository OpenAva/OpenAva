import Foundation
import OpenClawKit
import OpenClawProtocol

extension ImageSearchService: ToolDefinitionProvider {
    nonisolated func toolDefinitions() -> [ToolDefinition] {
        [
            ToolDefinition(
                functionName: "image_search",
                command: "image.search",
                description: "Find high-quality, free-to-use images related to a topic. Returns direct image URL, source page URL, size, provider, and license metadata.",
                parametersSchema: AnyCodable([
                    "type": "object",
                    "properties": [
                        "query": [
                            "type": "string",
                            "description": "Topic or keywords to search images for.",
                        ],
                        "topK": [
                            "type": "integer",
                            "minimum": 1,
                            "maximum": 20,
                            "description": "Maximum image results to return (default: 8).",
                        ],
                        "minWidth": [
                            "type": "integer",
                            "minimum": 320,
                            "maximum": 10000,
                            "description": "Minimum width threshold used for quality filtering (default: 1024).",
                        ],
                        "minHeight": [
                            "type": "integer",
                            "minimum": 320,
                            "maximum": 10000,
                            "description": "Minimum height threshold used for quality filtering (default: 720).",
                        ],
                        "orientation": [
                            "type": "string",
                            "enum": ["any", "landscape", "portrait", "square"],
                            "description": "Preferred orientation filter (default: any).",
                        ],
                        "safeSearch": [
                            "type": "boolean",
                            "description": "Enable safer filtering when the source supports it (default: true).",
                        ],
                    ],
                    "required": ["query"],
                    "additionalProperties": false,
                ] as [String: Any])
            ),
        ]
    }
}
