import Foundation
import OpenClawKit
import OpenClawProtocol

extension TextImageRenderService: ToolDefinitionProvider {
    func toolDefinitions() -> [ToolDefinition] {
        [
            ToolDefinition(
                functionName: "text_to_social_images",
                command: "text.image.render",
                description: "Render plain text into one or more social-media-ready image cards with clean typography and automatic pagination.",
                parametersSchema: AnyCodable([
                    "type": "object",
                    "properties": [
                        "text": [
                            "type": "string",
                            "description": "The main text content to place on images.",
                        ],
                        "title": [
                            "type": "string",
                            "description": "Optional card title shown at the top.",
                        ],
                        "theme": [
                            "type": "string",
                            "enum": ["notes", "dark"],
                            "description": "Visual theme for card style.",
                        ],
                        "width": [
                            "type": "integer",
                            "minimum": 720,
                            "maximum": 2000,
                            "description": "Image width in pixels. Height is derived from aspectRatio.",
                        ],
                        "aspectRatio": [
                            "type": "string",
                            "description": "Aspect ratio formatted as 'w:h', e.g. '3:4', '4:5', '16:9'.",
                        ],
                        "maxPages": [
                            "type": "integer",
                            "minimum": 1,
                            "maximum": 12,
                            "description": "Maximum number of generated images before truncation.",
                        ],
                    ],
                    "required": ["text"],
                    "additionalProperties": false,
                ] as [String: Any])
            ),
        ]
    }
}
