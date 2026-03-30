import Foundation
import OpenClawKit
import OpenClawProtocol

extension YouTubeTranscriptService: ToolDefinitionProvider {
    nonisolated func toolDefinitions() -> [ToolDefinition] {
        [
            ToolDefinition(
                functionName: "youtube_transcript",
                command: "youtube.transcript",
                description: "Fetch and read transcript text from a YouTube video URL or video ID, with optional preferred language hint and timestamped segments.",
                parametersSchema: AnyCodable([
                    "type": "object",
                    "properties": [
                        "input": [
                            "type": "string",
                            "description": "YouTube video URL or 11-character video ID.",
                        ],
                        "preferredLanguage": [
                            "type": "string",
                            "description": "Preferred transcript language code (hint), such as en, en-US, zh-Hans. If unavailable, falls back to default track.",
                        ],
                        "maxSegments": [
                            "type": "integer",
                            "minimum": 1,
                            "maximum": 2000,
                            "description": "Maximum transcript segments returned (default: 500).",
                        ],
                    ],
                    "required": ["input"],
                    "additionalProperties": false,
                ] as [String: Any])
            ),
        ]
    }
}
