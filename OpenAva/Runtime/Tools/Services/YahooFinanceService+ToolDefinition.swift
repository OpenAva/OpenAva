import Foundation
import OpenClawKit
import OpenClawProtocol

extension YahooFinanceService: ToolDefinitionProvider {
    nonisolated func toolDefinitions() -> [ToolDefinition] {
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
                ] as [String: Any]),
                isReadOnly: true,
                isConcurrencySafe: true,
                maxResultSizeChars: 24 * 1024
            ),
        ]
    }

    func registerHandlers(into handlers: inout [String: ToolHandler]) {
        handlers["finance.yahoo"] = { [weak self] request in
            guard let self else { throw NodeCapabilityRouter.RouterError.handlerUnavailable }
            return try await self.handleYahooFinanceInvoke(request)
        }
    }

    private func handleYahooFinanceInvoke(_ request: BridgeInvokeRequest) async throws -> BridgeInvokeResponse {
        struct YahooFinanceParams: Decodable {
            var action: String
            var symbols: [String]?
            var symbol: String?
            var range: String?
            var interval: String?
            var includePrePost: Bool?
            var modules: [String]?
            var query: String?
            var quotesCount: Int?
            var newsCount: Int?
        }

        let params = try ToolInvocationHelpers.decodeParams(YahooFinanceParams.self, from: request.paramsJSON)
        let action = params.action.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        switch action {
        case "quote":
            let result = try await fetchQuotes(symbols: params.symbols ?? [])
            let lines = result.quotes.map { quote in
                let price = quote.regularMarketPrice.map { "\($0)" } ?? ""
                let change = quote.regularMarketChangePercent.map { String(format: "%.2f%%", $0) } ?? ""
                return "- \(quote.symbol): \(price) \(quote.currency ?? "") (\(change))"
            }
            let text = "## Yahoo Finance Quotes\n- symbols: \(result.symbols.joined(separator: ", "))\n- count: \(result.count)\n\(lines.isEmpty ? "- (empty)" : lines.joined(separator: "\n"))"
            return ToolInvocationHelpers.successResponse(id: request.id, payload: text)
        case "chart":
            guard let symbol = params.symbol else {
                return ToolInvocationHelpers.invalidRequest(id: request.id, "symbol is required for chart action")
            }
            let result = try await fetchChart(
                symbol: symbol,
                range: params.range ?? "1mo",
                interval: params.interval ?? "1d",
                includePrePost: params.includePrePost ?? false
            )
            let samples = Array(result.points.prefix(10)).map { point in
                "- ts=\(point.timestamp) o=\(point.open.map { "\($0)" } ?? "") h=\(point.high.map { "\($0)" } ?? "") l=\(point.low.map { "\($0)" } ?? "") c=\(point.close.map { "\($0)" } ?? "") v=\(point.volume.map { "\($0)" } ?? "")"
            }
            let text = "## Yahoo Finance Chart\n- symbol: \(result.symbol)\n- range: \(result.range)\n- interval: \(result.interval)\n- points: \(result.points.count)\n\(samples.joined(separator: "\n"))"
            return ToolInvocationHelpers.successResponse(id: request.id, payload: text)
        case "summary":
            guard let symbol = params.symbol else {
                return ToolInvocationHelpers.invalidRequest(id: request.id, "symbol is required for summary action")
            }
            let result = try await fetchSummary(symbol: symbol, modules: params.modules ?? [])
            let text = "## Yahoo Finance Summary\n- symbol: \(result.symbol)\n- modules: \(result.modules.joined(separator: ", "))\n- note: raw summary object is omitted to keep context concise; call specific modules if needed."
            return ToolInvocationHelpers.successResponse(id: request.id, payload: text)
        case "search":
            guard let query = params.query else {
                return ToolInvocationHelpers.invalidRequest(id: request.id, "query is required for search action")
            }
            let result = try await search(
                query: query,
                quotesCount: params.quotesCount ?? 8,
                newsCount: params.newsCount ?? 6
            )
            let quoteLines = result.quotes.map { quote in
                "- \(quote.symbol ?? "") | \(quote.shortname ?? quote.longname ?? "") | \(quote.exchDisp ?? "")"
            }
            let newsLines = result.news.map { news in
                "- \(news.title ?? "") (\(news.publisher ?? "")) \(news.link ?? "")"
            }
            let text = "## Yahoo Finance Search\n- query: \(result.query)\n\n### Quotes\n\(quoteLines.isEmpty ? "- (empty)" : quoteLines.joined(separator: "\n"))\n\n### News\n\(newsLines.isEmpty ? "- (empty)" : newsLines.joined(separator: "\n"))"
            return ToolInvocationHelpers.successResponse(id: request.id, payload: text)
        default:
            return ToolInvocationHelpers.invalidRequest(id: request.id, "action must be one of quote, chart, summary, search")
        }
    }
}
