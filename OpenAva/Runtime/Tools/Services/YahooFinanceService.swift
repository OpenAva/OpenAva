import Foundation
import OpenClawKit

enum YahooFinanceServiceError: Error, LocalizedError {
    case invalidRequest(String)
    case invalidResponse
    case apiError(String)

    var errorDescription: String? {
        switch self {
        case let .invalidRequest(message):
            return "Invalid request: \(message)"
        case .invalidResponse:
            return "Invalid response from Yahoo Finance"
        case let .apiError(message):
            return "Yahoo Finance API error: \(message)"
        }
    }
}

struct YahooFinanceQuoteItem: Codable {
    let symbol: String
    let shortName: String?
    let longName: String?
    let currency: String?
    let marketState: String?
    let regularMarketPrice: Double?
    let regularMarketChange: Double?
    let regularMarketChangePercent: Double?
    let regularMarketTime: Int?
    let regularMarketDayHigh: Double?
    let regularMarketDayLow: Double?
    let regularMarketOpen: Double?
    let regularMarketVolume: Double?
    let fiftyTwoWeekHigh: Double?
    let fiftyTwoWeekLow: Double?
    let marketCap: Double?
    let exchange: String?
    let quoteType: String?
}

struct YahooFinanceQuoteResult: Codable {
    let symbols: [String]
    let count: Int
    let quotes: [YahooFinanceQuoteItem]
    let message: String
}

struct YahooFinanceChartPoint: Codable {
    let timestamp: Int
    let open: Double?
    let high: Double?
    let low: Double?
    let close: Double?
    let volume: Double?
}

struct YahooFinanceChartResult: Codable {
    let symbol: String
    let range: String
    let interval: String
    let timezone: String?
    let currency: String?
    let previousClose: Double?
    let points: [YahooFinanceChartPoint]
    let message: String
}

struct YahooFinanceSearchQuote: Codable {
    let symbol: String?
    let shortname: String?
    let longname: String?
    let exchDisp: String?
    let typeDisp: String?
}

struct YahooFinanceSearchNews: Codable {
    let uuid: String?
    let title: String?
    let publisher: String?
    let link: String?
    let providerPublishTime: Int?
}

struct YahooFinanceSearchResult: Codable {
    let query: String
    let quotes: [YahooFinanceSearchQuote]
    let news: [YahooFinanceSearchNews]
    let message: String
}

struct YahooFinanceSummaryResult: Codable {
    let symbol: String
    let modules: [String]
    let data: AnyCodable
    let message: String
}

actor YahooFinanceService {
    private static let timeoutSeconds: TimeInterval = 15
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = Self.timeoutSeconds
        config.timeoutIntervalForResource = Self.timeoutSeconds
        session = URLSession(configuration: config)
    }

    func fetchQuotes(symbols: [String]) async throws -> YahooFinanceQuoteResult {
        let normalizedSymbols = normalizeSymbols(symbols)
        guard !normalizedSymbols.isEmpty else {
            throw YahooFinanceServiceError.invalidRequest("At least one symbol is required")
        }

        var components = URLComponents(string: "https://query1.finance.yahoo.com/v7/finance/quote")
        components?.queryItems = [
            URLQueryItem(name: "symbols", value: normalizedSymbols.joined(separator: ",")),
            URLQueryItem(name: "lang", value: "en-US"),
            URLQueryItem(name: "region", value: "US"),
        ]
        guard let url = components?.url else {
            throw YahooFinanceServiceError.invalidRequest("Failed to build quote URL")
        }

        struct QuoteResponse: Decodable {
            struct QuoteContainer: Decodable {
                struct Item: Decodable {
                    let symbol: String
                    let shortName: String?
                    let longName: String?
                    let currency: String?
                    let marketState: String?
                    let regularMarketPrice: Double?
                    let regularMarketChange: Double?
                    let regularMarketChangePercent: Double?
                    let regularMarketTime: Int?
                    let regularMarketDayHigh: Double?
                    let regularMarketDayLow: Double?
                    let regularMarketOpen: Double?
                    let regularMarketVolume: Double?
                    let fiftyTwoWeekHigh: Double?
                    let fiftyTwoWeekLow: Double?
                    let marketCap: Double?
                    let fullExchangeName: String?
                    let quoteType: String?
                }

                let result: [Item]
            }

            let quoteResponse: QuoteContainer
        }

        let response: QuoteResponse = try await fetchDecodable(from: url)
        let quotes = response.quoteResponse.result.map {
            YahooFinanceQuoteItem(
                symbol: $0.symbol,
                shortName: $0.shortName,
                longName: $0.longName,
                currency: $0.currency,
                marketState: $0.marketState,
                regularMarketPrice: $0.regularMarketPrice,
                regularMarketChange: $0.regularMarketChange,
                regularMarketChangePercent: $0.regularMarketChangePercent,
                regularMarketTime: $0.regularMarketTime,
                regularMarketDayHigh: $0.regularMarketDayHigh,
                regularMarketDayLow: $0.regularMarketDayLow,
                regularMarketOpen: $0.regularMarketOpen,
                regularMarketVolume: $0.regularMarketVolume,
                fiftyTwoWeekHigh: $0.fiftyTwoWeekHigh,
                fiftyTwoWeekLow: $0.fiftyTwoWeekLow,
                marketCap: $0.marketCap,
                exchange: $0.fullExchangeName,
                quoteType: $0.quoteType
            )
        }

        return YahooFinanceQuoteResult(
            symbols: normalizedSymbols,
            count: quotes.count,
            quotes: quotes,
            message: "Fetched \(quotes.count) quote(s) from Yahoo Finance"
        )
    }

    func fetchChart(symbol: String, range: String, interval: String, includePrePost: Bool) async throws -> YahooFinanceChartResult {
        let normalizedSymbol = symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !normalizedSymbol.isEmpty else {
            throw YahooFinanceServiceError.invalidRequest("symbol is required")
        }

        var components = URLComponents(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(normalizedSymbol)")
        components?.queryItems = [
            URLQueryItem(name: "range", value: range),
            URLQueryItem(name: "interval", value: interval),
            URLQueryItem(name: "includePrePost", value: includePrePost ? "true" : "false"),
            URLQueryItem(name: "events", value: "div,splits"),
            URLQueryItem(name: "lang", value: "en-US"),
            URLQueryItem(name: "region", value: "US"),
        ]
        guard let url = components?.url else {
            throw YahooFinanceServiceError.invalidRequest("Failed to build chart URL")
        }

        struct ChartResponse: Decodable {
            struct ChartNode: Decodable {
                struct ChartResultItem: Decodable {
                    struct Meta: Decodable {
                        let symbol: String?
                        let currency: String?
                        let exchangeTimezoneName: String?
                        let chartPreviousClose: Double?
                    }

                    struct Indicators: Decodable {
                        struct QuoteNode: Decodable {
                            let open: [Double?]?
                            let high: [Double?]?
                            let low: [Double?]?
                            let close: [Double?]?
                            let volume: [Double?]?
                        }

                        let quote: [QuoteNode]?
                    }

                    let meta: Meta?
                    let timestamp: [Int]?
                    let indicators: Indicators?
                }

                struct ChartError: Decodable {
                    let description: String?
                }

                let result: [ChartResultItem]?
                let error: ChartError?
            }

            let chart: ChartNode
        }

        let response: ChartResponse = try await fetchDecodable(from: url)
        if let apiError = response.chart.error?.description, !apiError.isEmpty {
            throw YahooFinanceServiceError.apiError(apiError)
        }

        guard let item = response.chart.result?.first else {
            throw YahooFinanceServiceError.invalidResponse
        }

        let timestamps = item.timestamp ?? []
        let quote = item.indicators?.quote?.first
        var points: [YahooFinanceChartPoint] = []
        points.reserveCapacity(timestamps.count)

        // Align OHLCV arrays by index with timestamp to keep each candle complete.
        for (index, ts) in timestamps.enumerated() {
            points.append(YahooFinanceChartPoint(
                timestamp: ts,
                open: value(at: index, in: quote?.open),
                high: value(at: index, in: quote?.high),
                low: value(at: index, in: quote?.low),
                close: value(at: index, in: quote?.close),
                volume: value(at: index, in: quote?.volume)
            ))
        }

        return YahooFinanceChartResult(
            symbol: item.meta?.symbol ?? normalizedSymbol,
            range: range,
            interval: interval,
            timezone: item.meta?.exchangeTimezoneName,
            currency: item.meta?.currency,
            previousClose: item.meta?.chartPreviousClose,
            points: points,
            message: "Fetched \(points.count) chart point(s) from Yahoo Finance"
        )
    }

    func search(query: String, quotesCount: Int, newsCount: Int) async throws -> YahooFinanceSearchResult {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else {
            throw YahooFinanceServiceError.invalidRequest("query is required")
        }

        var components = URLComponents(string: "https://query1.finance.yahoo.com/v1/finance/search")
        components?.queryItems = [
            URLQueryItem(name: "q", value: normalizedQuery),
            URLQueryItem(name: "quotesCount", value: "\(max(1, min(quotesCount, 20)))"),
            URLQueryItem(name: "newsCount", value: "\(max(0, min(newsCount, 20)))"),
            URLQueryItem(name: "lang", value: "en-US"),
            URLQueryItem(name: "region", value: "US"),
        ]
        guard let url = components?.url else {
            throw YahooFinanceServiceError.invalidRequest("Failed to build search URL")
        }

        struct SearchResponse: Decodable {
            struct QuoteItem: Decodable {
                let symbol: String?
                let shortname: String?
                let longname: String?
                let exchDisp: String?
                let typeDisp: String?
            }

            struct NewsItem: Decodable {
                let uuid: String?
                let title: String?
                let publisher: String?
                let link: String?
                let providerPublishTime: Int?
            }

            let quotes: [QuoteItem]?
            let news: [NewsItem]?
        }

        let response: SearchResponse = try await fetchDecodable(from: url)
        let quotes = (response.quotes ?? []).map {
            YahooFinanceSearchQuote(
                symbol: $0.symbol,
                shortname: $0.shortname,
                longname: $0.longname,
                exchDisp: $0.exchDisp,
                typeDisp: $0.typeDisp
            )
        }
        let news = (response.news ?? []).map {
            YahooFinanceSearchNews(
                uuid: $0.uuid,
                title: $0.title,
                publisher: $0.publisher,
                link: $0.link,
                providerPublishTime: $0.providerPublishTime
            )
        }

        return YahooFinanceSearchResult(
            query: normalizedQuery,
            quotes: quotes,
            news: news,
            message: "Found \(quotes.count) quote match(es) and \(news.count) news item(s)"
        )
    }

    func fetchSummary(symbol: String, modules: [String]) async throws -> YahooFinanceSummaryResult {
        let normalizedSymbol = symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !normalizedSymbol.isEmpty else {
            throw YahooFinanceServiceError.invalidRequest("symbol is required")
        }

        let defaultModules = [
            "price", "summaryDetail", "defaultKeyStatistics", "financialData", "calendarEvents", "assetProfile",
        ]
        let normalizedModules = modules
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let resolvedModules = Array((normalizedModules.isEmpty ? defaultModules : normalizedModules).prefix(12))

        var components = URLComponents(string: "https://query1.finance.yahoo.com/v10/finance/quoteSummary/\(normalizedSymbol)")
        components?.queryItems = [
            URLQueryItem(name: "modules", value: resolvedModules.joined(separator: ",")),
            URLQueryItem(name: "lang", value: "en-US"),
            URLQueryItem(name: "region", value: "US"),
        ]
        guard let url = components?.url else {
            throw YahooFinanceServiceError.invalidRequest("Failed to build summary URL")
        }

        struct SummaryResponse: Decodable {
            struct SummaryNode: Decodable {
                struct SummaryError: Decodable {
                    let description: String?
                }

                let result: [AnyCodable]?
                let error: SummaryError?
            }

            let quoteSummary: SummaryNode
        }

        let response: SummaryResponse = try await fetchDecodable(from: url)
        if let apiError = response.quoteSummary.error?.description, !apiError.isEmpty {
            throw YahooFinanceServiceError.apiError(apiError)
        }
        guard let first = response.quoteSummary.result?.first else {
            throw YahooFinanceServiceError.invalidResponse
        }

        return YahooFinanceSummaryResult(
            symbol: normalizedSymbol,
            modules: resolvedModules,
            data: first,
            message: "Fetched summary modules for \(normalizedSymbol)"
        )
    }

    private func normalizeSymbols(_ symbols: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for symbol in symbols {
            let normalized = symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            guard !normalized.isEmpty, !seen.contains(normalized) else {
                continue
            }
            seen.insert(normalized)
            result.append(normalized)
            if result.count >= 20 {
                break
            }
        }
        return result
    }

    private func value(at index: Int, in values: [Double?]?) -> Double? {
        guard let values, values.indices.contains(index) else {
            return nil
        }
        return values[index]
    }

    private func fetchDecodable<T: Decodable>(from url: URL) async throws -> T {
        let request = URLRequest(url: url)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200 ... 299).contains(http.statusCode) else {
            throw YahooFinanceServiceError.invalidResponse
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
