import Foundation

enum AShareMarketServiceError: Error, LocalizedError {
    case invalidRequest(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case let .invalidRequest(message):
            return "Invalid request: \(message)"
        case .invalidResponse:
            return "Invalid response from Sina Finance"
        }
    }
}

struct AShareRealtimeQuote: Codable {
    let code: String
    let symbol: String
    let name: String
    let price: Double
    let open: Double?
    let preClose: Double?
    let high: Double?
    let low: Double?
    let volumeLots: Int
    let amount: Double
    let changeAmount: Double
    let changePercent: Double
}

struct AShareMinutePoint: Codable {
    let time: String
    let open: Double
    let high: Double
    let low: Double
    let close: Double
    let volume: Int
    let amount: Double
}

struct AShareMinuteDistributionBucket: Codable {
    let volumeLots: Int
    let percent: Double
}

struct AShareMinuteDistribution: Codable {
    let open30min: AShareMinuteDistributionBucket
    let midAM: AShareMinuteDistributionBucket
    let midPM: AShareMinuteDistributionBucket
    let close30min: AShareMinuteDistributionBucket
}

struct AShareTopVolumePoint: Codable {
    let time: String
    let price: Double
    let volumeLots: Int
    let amount: Double
}

struct AShareMinuteAnalysis: Codable {
    let totalVolumeLots: Int
    let totalAmount: Double
    let distribution: AShareMinuteDistribution
    let topVolumes: [AShareTopVolumePoint]
    let signals: [String]
}

struct AShareAnalyzeResult: Codable {
    let code: String
    let name: String?
    let realtime: AShareRealtimeQuote?
    let updatedAt: String
    let minuteAnalysis: AShareMinuteAnalysis?
    let minuteError: String?
    let error: String?
}

actor AShareMarketService {
    private static let timeoutSeconds: TimeInterval = 12
    private static let realtimeURL = "https://hq.sinajs.cn/list="
    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_7_2) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36"

    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = Self.timeoutSeconds
        config.timeoutIntervalForResource = Self.timeoutSeconds
        session = URLSession(configuration: config)
    }

    func analyzeStocks(codes: [String], includeMinute: Bool) async throws -> [AShareAnalyzeResult] {
        let normalizedSymbols = codes.map(Self.sinaSymbol(from:))
        let realtimeCache = try await fetchRealtime(symbols: normalizedSymbols)
        let formatter = ISO8601DateFormatter()

        var results: [AShareAnalyzeResult] = []
        results.reserveCapacity(codes.count)

        for code in codes {
            let symbol = Self.sinaSymbol(from: code)
            guard let realtime = realtimeCache[symbol] else {
                results.append(AShareAnalyzeResult(
                    code: Self.cleanCode(code),
                    name: nil,
                    realtime: nil,
                    updatedAt: formatter.string(from: Date()),
                    minuteAnalysis: nil,
                    minuteError: nil,
                    error: "Failed to fetch market data for \(Self.cleanCode(code))"
                ))
                continue
            }

            var minuteAnalysis: AShareMinuteAnalysis?
            var minuteError: String?
            if includeMinute {
                let minuteData = try await fetchMinuteData(symbol: symbol, count: 250)
                if let analyzed = Self.analyzeMinuteVolume(minuteData) {
                    minuteAnalysis = analyzed
                } else {
                    minuteError = "No valid trading data"
                }
            }

            results.append(AShareAnalyzeResult(
                code: realtime.code,
                name: realtime.name,
                realtime: realtime,
                updatedAt: formatter.string(from: Date()),
                minuteAnalysis: minuteAnalysis,
                minuteError: minuteError,
                error: nil
            ))
        }

        return results
    }

    func fetchRealtime(symbols: [String]) async throws -> [String: AShareRealtimeQuote] {
        let normalizedSymbols = symbols
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }

        guard !normalizedSymbols.isEmpty else {
            throw AShareMarketServiceError.invalidRequest("At least one symbol is required")
        }

        guard let url = URL(string: Self.realtimeURL + normalizedSymbols.joined(separator: ",")) else {
            throw AShareMarketServiceError.invalidRequest("Failed to build realtime URL")
        }

        var request = URLRequest(url: url)
        request.setValue("https://finance.sina.com.cn", forHTTPHeaderField: "Referer")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200 ... 299).contains(httpResponse.statusCode)
        else {
            throw AShareMarketServiceError.invalidResponse
        }

        guard let text = Self.decodeGBK(data: data) else {
            throw AShareMarketServiceError.invalidResponse
        }

        var result: [String: AShareRealtimeQuote] = [:]

        // Parse each var hq_str_xxx="..." line from Sina unified quote response.
        for line in text.split(separator: "\n") {
            guard let parsed = Self.parseRealtimeLine(String(line)) else {
                continue
            }
            result[parsed.symbol] = parsed.quote
        }

        return result
    }

    func fetchMinuteData(symbol: String, count: Int = 250) async throws -> [AShareMinutePoint] {
        let normalizedSymbol = symbol.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedSymbol.isEmpty else {
            throw AShareMarketServiceError.invalidRequest("symbol is required")
        }

        let urlString = "https://quotes.sina.cn/cn/api/jsonp_v2.php/var%20_\(normalizedSymbol)=/CN_MarketDataService.getKLineData?symbol=\(normalizedSymbol)&scale=1&ma=no&datalen=\(max(10, min(count, 500)))"
        guard let url = URL(string: urlString) else {
            throw AShareMarketServiceError.invalidRequest("Failed to build minute data URL")
        }

        var request = URLRequest(url: url)
        request.setValue("https://finance.sina.com.cn", forHTTPHeaderField: "Referer")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200 ... 299).contains(httpResponse.statusCode)
        else {
            throw AShareMarketServiceError.invalidResponse
        }

        let text = String(decoding: data, as: UTF8.self)
        guard let jsonArrayString = Self.extractJSONPArray(from: text),
              let jsonData = jsonArrayString.data(using: .utf8)
        else {
            return []
        }

        struct RawMinuteItem: Decodable {
            let day: String
            let open: String
            let high: String
            let low: String
            let close: String
            let volume: String
            let amount: String
        }

        let rawItems = (try? JSONDecoder().decode([RawMinuteItem].self, from: jsonData)) ?? []
        return rawItems.compactMap { item in
            guard let open = Double(item.open),
                  let high = Double(item.high),
                  let low = Double(item.low),
                  let close = Double(item.close),
                  let volume = Int(item.volume),
                  let amount = Double(item.amount)
            else {
                return nil
            }

            return AShareMinutePoint(
                time: item.day,
                open: open,
                high: high,
                low: low,
                close: close,
                volume: volume,
                amount: amount
            )
        }
    }

    nonisolated static func formatRealtime(_ data: AShareRealtimeQuote) -> String {
        let changeSymbol = data.changePercent >= 0 ? "+" : ""
        let openText = data.open.map { String(format: "%.2f", $0) } ?? "-"
        let highText = data.high.map { String(format: "%.2f", $0) } ?? "-"
        let lowText = data.low.map { String(format: "%.2f", $0) } ?? "-"
        let preCloseText = data.preClose.map { String(format: "%.2f", $0) } ?? "-"

        return """
        === \(data.name) (\(data.code)) ===
        Price: \(String(format: "%.2f", data.price))  Change: \(changeSymbol)\(String(format: "%.2f", data.changePercent))%
        Open: \(openText)  High: \(highText)  Low: \(lowText)  Prev Close: \(preCloseText)
        Volume: \(String(format: "%.1f", Double(data.volumeLots) / 10000.0)) x10k lots  Amount: \(String(format: "%.2f", data.amount / 100_000_000.0)) x100M CNY
        """
    }

    nonisolated static func formatMinuteAnalysis(_ analysis: AShareMinuteAnalysis) -> String {
        var text = """

        [Minute Volume Analysis]
        Total: \(analysis.totalVolumeLots) lots (\(String(format: "%.1f", analysis.totalAmount / 10000.0)) x10k CNY)
        Dist 09:30-10:00: \(analysis.distribution.open30min.volumeLots) lots (\(analysis.distribution.open30min.percent)%)
        Dist 10:00-11:30: \(analysis.distribution.midAM.volumeLots) lots (\(analysis.distribution.midAM.percent)%)
        Dist 13:00-14:30: \(analysis.distribution.midPM.volumeLots) lots (\(analysis.distribution.midPM.percent)%)
        Dist 14:30-15:00: \(analysis.distribution.close30min.volumeLots) lots (\(analysis.distribution.close30min.percent)%)
        Top Volume Minutes:
        """

        for item in analysis.topVolumes {
            text += "\n- \(item.time)  price \(String(format: "%.2f", item.price))  vol \(item.volumeLots) lots  amt \(String(format: "%.1f", item.amount / 10000.0)) x10k"
        }

        if !analysis.signals.isEmpty {
            text += "\nSignals:"
            for signal in analysis.signals {
                text += "\n- \(signal)"
            }
        }

        return text
    }

    private nonisolated static func parseRealtimeLine(_ line: String) -> (symbol: String, quote: AShareRealtimeQuote)? {
        guard let regex = try? NSRegularExpression(pattern: #"var hq_str_(\w+)="([^"]*)";?"#),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let symbolRange = Range(match.range(at: 1), in: line),
              let dataRange = Range(match.range(at: 2), in: line)
        else {
            return nil
        }

        let symbol = String(line[symbolRange]).lowercased()
        let data = String(line[dataRange])
        guard !data.isEmpty else {
            return nil
        }

        let fields = data.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard fields.count >= 10 else {
            return nil
        }

        let name = fields[0]
        let openPrice = Double(fields[1])
        let preClose = Double(fields[2])
        guard let price = Double(fields[3]), price > 0 else {
            return nil
        }

        let high = Double(fields[4])
        let low = Double(fields[5])
        let volumeShares = Int((Double(fields[8]) ?? 0).rounded())
        let amount = Double(fields[9]) ?? 0

        let changeAmount = preClose.map { price - $0 } ?? 0
        let changePercent = (preClose ?? 0) > 0 ? (changeAmount / (preClose ?? 1) * 100) : 0
        let code = symbol.count > 2 ? String(symbol.dropFirst(2)) : symbol

        let quote = AShareRealtimeQuote(
            code: code,
            symbol: symbol,
            name: name,
            price: price,
            open: openPrice,
            preClose: preClose,
            high: high,
            low: low,
            volumeLots: volumeShares / 100,
            amount: amount,
            changeAmount: Self.round2(changeAmount),
            changePercent: Self.round2(changePercent)
        )
        return (symbol, quote)
    }

    private nonisolated static func analyzeMinuteVolume(_ minuteData: [AShareMinutePoint]) -> AShareMinuteAnalysis? {
        let tradingData = minuteData.filter { point in
            guard point.volume > 0,
                  let hhmm = minuteHHmm(from: point.time)
            else {
                return false
            }
            return hhmm >= "09:25" && hhmm <= "15:00"
        }

        guard !tradingData.isEmpty else {
            return nil
        }

        let totalVolume = tradingData.reduce(0) { $0 + $1.volume }
        if totalVolume <= 0 {
            return nil
        }

        func periodVolume(start: String, endExclusive: String) -> Int {
            tradingData.reduce(0) { partial, item in
                guard let hhmm = minuteHHmm(from: item.time),
                      hhmm >= start, hhmm < endExclusive
                else {
                    return partial
                }
                return partial + item.volume
            }
        }

        let open30 = periodVolume(start: "09:30", endExclusive: "10:00")
        let midAM = periodVolume(start: "10:00", endExclusive: "11:30")
        let midPM = periodVolume(start: "13:00", endExclusive: "14:30")
        let close30 = periodVolume(start: "14:30", endExclusive: "15:01")

        let sortedByVolume = tradingData.sorted { $0.volume > $1.volume }
        let topVolumes = Array(sortedByVolume.prefix(10)).map { point in
            AShareTopVolumePoint(
                time: String(point.time.suffix(8)),
                price: point.close,
                volumeLots: point.volume / 100,
                amount: point.amount
            )
        }

        var signals: [String] = []
        let closeRatio = Double(close30) / Double(totalVolume)
        let openRatio = Double(open30) / Double(totalVolume)

        if closeRatio > 0.25 {
            signals.append("Heavy volume into the close, which may indicate aggressive accumulation or distribution")
        } else if closeRatio > 0.15 {
            signals.append("Noticeable volume expansion into the close")
        }
        if openRatio > 0.40 {
            signals.append("Abnormally high early-session volume, suggesting strong institutional participation")
        } else if openRatio > 0.30 {
            signals.append("Strong early-session buying pressure is evident")
        }

        if let lastPrice = tradingData.last?.close,
           let highestVolPrice = sortedByVolume.first?.close,
           abs(lastPrice - highestVolPrice) < 0.01
        {
            signals.append("Price appears pinned near the limit-up level; monitor order-book support")
        }

        return AShareMinuteAnalysis(
            totalVolumeLots: totalVolume / 100,
            totalAmount: tradingData.reduce(0) { $0 + $1.amount },
            distribution: AShareMinuteDistribution(
                open30min: AShareMinuteDistributionBucket(
                    volumeLots: open30 / 100,
                    percent: round1(Double(open30) / Double(totalVolume) * 100)
                ),
                midAM: AShareMinuteDistributionBucket(
                    volumeLots: midAM / 100,
                    percent: round1(Double(midAM) / Double(totalVolume) * 100)
                ),
                midPM: AShareMinuteDistributionBucket(
                    volumeLots: midPM / 100,
                    percent: round1(Double(midPM) / Double(totalVolume) * 100)
                ),
                close30min: AShareMinuteDistributionBucket(
                    volumeLots: close30 / 100,
                    percent: round1(Double(close30) / Double(totalVolume) * 100)
                )
            ),
            topVolumes: topVolumes,
            signals: signals
        )
    }

    /// Sina quote endpoint returns GBK/GB18030 encoded text.
    private nonisolated static func decodeGBK(data: Data) -> String? {
        let gb18030 = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        return String(data: data, encoding: String.Encoding(rawValue: gb18030))
    }

    private nonisolated static func extractJSONPArray(from text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"\(\[(.*)\]\)"#, options: [.dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text)
        else {
            return nil
        }
        return "[\(text[range])]"
    }

    nonisolated static func sinaSymbol(from code: String) -> String {
        let cleaned = cleanCode(code)
        if cleaned.hasPrefix("6") {
            return "sh\(cleaned)"
        }
        if cleaned.hasPrefix("0") || cleaned.hasPrefix("3") {
            return "sz\(cleaned)"
        }
        if cleaned.hasPrefix("8") || cleaned.hasPrefix("4") {
            return "bj\(cleaned)"
        }
        return "sh\(cleaned)"
    }

    nonisolated static func cleanCode(_ code: String) -> String {
        code
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            .replacingOccurrences(of: "SH", with: "")
            .replacingOccurrences(of: "SZ", with: "")
            .replacingOccurrences(of: "BJ", with: "")
            .replacingOccurrences(of: ".", with: "")
    }

    private nonisolated static func minuteHHmm(from time: String) -> String? {
        guard time.count >= 16 else {
            return nil
        }
        let start = time.index(time.endIndex, offsetBy: -8)
        let end = time.index(start, offsetBy: 5)
        return String(time[start ..< end])
    }

    private nonisolated static func round1(_ value: Double) -> Double {
        (value * 10).rounded() / 10
    }

    private nonisolated static func round2(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }
}
