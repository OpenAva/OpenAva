import Foundation
import OpenClawKit
import OpenClawProtocol

extension AShareMarketService: ToolDefinitionProvider {
    nonisolated func toolDefinitions() -> [ToolDefinition] {
        [
            ToolDefinition(
                functionName: "a_share_market",
                command: "finance.a_share",
                description: "Get China A-share realtime quotes from Sina, with optional minute-level volume analysis for SH/SZ stocks.",
                parametersSchema: AnyCodable([
                    "type": "object",
                    "properties": [
                        "codes": [
                            "type": "array",
                            "items": ["type": "string"],
                            "minItems": 1,
                            "maxItems": 20,
                            "description": "Stock codes like ['600789','002446'] or codes with SH/SZ prefix.",
                        ],
                        "minute": [
                            "type": "boolean",
                            "description": "Include minute-level volume analysis.",
                        ],
                        "json": [
                            "type": "boolean",
                            "description": "Return raw JSON instead of formatted text.",
                        ],
                    ],
                    "required": ["codes"],
                    "additionalProperties": false,
                ] as [String: Any]),
                isReadOnly: true,
                isConcurrencySafe: true,
                maxResultSizeChars: 24 * 1024
            ),
        ]
    }
}
