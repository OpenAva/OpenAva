import Foundation
import OpenClawKit
import OpenClawProtocol

extension YahooFinanceService: ToolDefinitionProvider {
    func toolDefinitions() -> [ToolDefinition] {
        [
            ToolDefinition(
                functionName: "yahoo_finance",
                command: "finance.yahoo",
                description: "Get Yahoo Finance market data including quote snapshots, chart candles, security summary modules, and symbol search.",
                parametersSchema: AnyCodable([
                    "type": "object",
                    "properties": [
                        "action": [
                            "type": "string",
                            "enum": ["quote", "chart", "summary", "search"],
                            "description": "Data type to fetch from Yahoo Finance.",
                        ],
                        "symbols": [
                            "type": "array",
                            "items": ["type": "string"],
                            "description": "Ticker symbols for quote action, e.g. ['AAPL','MSFT'].",
                        ],
                        "symbol": [
                            "type": "string",
                            "description": "Single ticker symbol for chart or summary action.",
                        ],
                        "range": [
                            "type": "string",
                            "description": "Chart range like 1d, 5d, 1mo, 6mo, 1y, 5y, max. Used by chart action.",
                        ],
                        "interval": [
                            "type": "string",
                            "description": "Chart interval like 1m, 5m, 15m, 1h, 1d, 1wk, 1mo. Used by chart action.",
                        ],
                        "includePrePost": [
                            "type": "boolean",
                            "description": "Include pre-market and post-market candles. Used by chart action.",
                        ],
                        "modules": [
                            "type": "array",
                            "items": ["type": "string"],
                            "description": "Summary modules, e.g. ['price','financialData','summaryDetail'].",
                        ],
                        "query": [
                            "type": "string",
                            "description": "Search query text, such as company name or symbol keyword. Used by search action.",
                        ],
                        "quotesCount": [
                            "type": "integer",
                            "minimum": 1,
                            "maximum": 20,
                            "description": "How many quote suggestions to return for search action.",
                        ],
                        "newsCount": [
                            "type": "integer",
                            "minimum": 0,
                            "maximum": 20,
                            "description": "How many news suggestions to return for search action.",
                        ],
                    ],
                    "required": ["action"],
                    "additionalProperties": false,
                ] as [String: Any])
            ),
        ]
    }
}
