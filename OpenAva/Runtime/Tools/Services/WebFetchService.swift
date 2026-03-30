import Foundation
import OpenClawKit

/// Web fetch service for accessing web content
actor WebFetchService {
    private static let defaultMaxChars = 50000
    private static let minMaxChars = 100
    private static let defaultMaxResponseBytes = 2_000_000
    private static let defaultTimeoutSeconds: TimeInterval = 30
    private static let defaultMaxRedirects = 3
    private static let defaultUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_7_2) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36"
    private static let removableBlockTags = [
        "script", "style", "noscript", "template", "svg", "canvas", "iframe", "object", "embed",
        "picture", "video", "audio", "source", "form", "button", "select", "option", "textarea",
    ]
    private static let removableVoidTags = ["input", "meta", "link", "source"]
    private static let noiseAttributeKeywords = [
        "nav", "menu", "footer", "header", "sidebar", "aside", "breadcrumb", "share", "social",
        "related", "recommend", "comment", "promo", "advert", "ads", "cookie", "consent", "banner",
        "subscribe", "newsletter", "popup", "modal", "captcha", "pagination", "toolbar", "outbrain",
    ]
    private static let primaryContentAttributeKeywords = [
        "article", "content", "post", "entry", "main", "body", "markdown", "document", "page",
    ]
    private static let noiseLinePatterns = [
        "(?i)^\\s*(menu|navigation|search|skip to content|open menu|close menu)\\s*$",
        "(?i)^\\s*(sign in|log in|sign up|register|subscribe|newsletter)\\s*$",
        "(?i)^\\s*(privacy policy|terms of service|cookie policy|all rights reserved)\\s*$",
        "(?i)^\\s*(share( this)?|follow us|advertisement|sponsored|related articles?|read more)\\b.*$",
        "(?i)^\\s*(accept|reject|manage) cookies\\b.*$",
        "(?i)^\\s*copyright\\b.*$",
    ]

    private let session: URLSession
    private let redirectLimiter: RedirectLimiter
    private let maxResponseBytes: Int
    private let timeoutSeconds: TimeInterval
    private let userAgent: String

    init(
        maxResponseBytes: Int = WebFetchService.defaultMaxResponseBytes,
        timeoutSeconds: TimeInterval = WebFetchService.defaultTimeoutSeconds,
        maxRedirects: Int = WebFetchService.defaultMaxRedirects,
        userAgent: String = WebFetchService.defaultUserAgent
    ) {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = timeoutSeconds
        config.timeoutIntervalForResource = timeoutSeconds
        redirectLimiter = RedirectLimiter(maxRedirects: maxRedirects)
        session = URLSession(configuration: config, delegate: redirectLimiter, delegateQueue: nil)
        self.maxResponseBytes = maxResponseBytes
        self.timeoutSeconds = timeoutSeconds
        self.userAgent = userAgent
    }

    /// Fetch web content and extract readable text
    func fetch(
        url: URL,
        extractMode: ExtractMode = .markdown,
        maxChars: Int = WebFetchService.defaultMaxChars
    ) async throws -> WebFetchResult {
        guard Self.isValidHTTPURL(url) else {
            throw WebFetchError.invalidURL
        }
        guard let host = url.host, !LoopbackHost.isLocalNetworkHost(host) else {
            // Block local/private network targets to reduce SSRF-style abuse.
            throw WebFetchError.privateNetworkBlocked
        }

        let request = Self.makeRequest(url: url, timeoutSeconds: timeoutSeconds, userAgent: userAgent)
        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw WebFetchError.invalidResponse
        }

        guard (200 ... 299).contains(httpResponse.statusCode) else {
            throw WebFetchError.httpError(statusCode: httpResponse.statusCode)
        }

        let limitedData = data.prefix(maxResponseBytes)
        let responseTruncated = data.count > maxResponseBytes

        let contentTypeHeader = httpResponse.value(forHTTPHeaderField: "Content-Type")
        let normalizedContentType = Self.normalizeContentType(contentTypeHeader)
        let fallbackContentType = httpResponse.mimeType ?? "application/octet-stream"
        let contentType = normalizedContentType ?? fallbackContentType

        let body = String(decoding: limitedData, as: UTF8.self)
        let isHtmlFallback = Self.looksLikeHtml(body)

        let extractor: String
        let title: String?
        let rawText: String
        if contentType.contains("text/html") || isHtmlFallback {
            let extracted = Self.extractReadableContent(from: body, url: url)
            rawText = extractMode == .text ? extracted.text : extracted.markdown
            title = extracted.title
            extractor = "readability"
        } else if contentType.contains("text/plain") || contentType.contains("text/markdown") {
            rawText = body
            title = nil
            extractor = "raw"
        } else if contentType.contains("application/json") {
            if let json = try? JSONSerialization.jsonObject(with: limitedData),
               let prettyData = try? JSONSerialization.data(withJSONObject: json, options: .prettyPrinted)
            {
                rawText = String(decoding: prettyData, as: UTF8.self)
                extractor = "json"
            } else {
                rawText = body
                extractor = "raw"
            }
            title = nil
        } else {
            throw WebFetchError.unsupportedContentType(contentType)
        }

        let resolvedMaxChars = max(Self.minMaxChars, maxChars)
        let truncation = Self.truncate(rawText, maxChars: resolvedMaxChars)
        let warning = responseTruncated ? "Response body truncated after \(maxResponseBytes) bytes." : nil

        // Generate human-readable message
        let domain = url.host ?? "unknown"
        let sizeKB = Double(truncation.text.count) / 1024.0
        let message: String
        if let title {
            message = String(format: "Fetched \"%@\" from %@ (%.1f KB)", title, domain, sizeKB)
        } else {
            message = String(format: "Fetched content from %@ (%.1f KB)", domain, sizeKB)
        }

        return WebFetchResult(
            url: url.absoluteString,
            finalUrl: httpResponse.url?.absoluteString ?? url.absoluteString,
            status: httpResponse.statusCode,
            contentType: contentType,
            title: title,
            text: truncation.text,
            extractMode: extractMode.rawValue,
            extractor: extractor,
            truncated: truncation.truncated || responseTruncated,
            rawLength: truncation.rawLength,
            length: truncation.text.count,
            warning: warning,
            message: message
        )
    }

    /// Extract readable content from HTML
    private static func extractReadableContent(from html: String, url _: URL) -> (text: String, markdown: String, title: String?) {
        let title = Self.extractTitle(from: html)
        let sanitized = Self.sanitizeHTML(html)
        let primary = Self.extractPrimaryHTML(from: sanitized)
        let markdown = Self.htmlToMarkdown(primary, fallbackTitle: title)
        let text = Self.markdownToText(markdown.text)
        return (text: text, markdown: markdown.text, title: markdown.title)
    }

    /// Exposed for parser unit tests.
    static func extractReadableContentForTesting(from html: String) -> (text: String, markdown: String, title: String?) {
        extractReadableContent(from: html, url: URL(string: "https://example.com")!)
    }

    private static func isValidHTTPURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else {
            return false
        }
        guard scheme == "http" || scheme == "https" else {
            return false
        }
        return url.host?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    private static func makeRequest(url: URL, timeoutSeconds: TimeInterval, userAgent: String) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadRevalidatingCacheData, timeoutInterval: timeoutSeconds)
        request.setValue("text/markdown, text/html;q=0.9, */*;q=0.1", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    private static func normalizeContentType(_ value: String?) -> String? {
        guard let value, !value.isEmpty else {
            return nil
        }
        let raw = value.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true).first
        return raw?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func looksLikeHtml(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return false
        }
        let head = trimmed.prefix(256).lowercased()
        return head.hasPrefix("<!doctype html") || head.hasPrefix("<html")
    }

    private static func sanitizeHTML(_ html: String) -> String {
        var cleaned = html
        cleaned = cleaned.replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: "", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: "<head\\b[^>]*>[\\s\\S]*?</head>", with: "", options: [.regularExpression, .caseInsensitive])
        cleaned = Self.removeBlockElements(named: removableBlockTags, from: cleaned)
        cleaned = Self.removeVoidElements(named: removableVoidTags, from: cleaned)
        cleaned = Self.removeHiddenElements(from: cleaned)
        cleaned = Self.removeNoiseAttributedElements(from: cleaned)
        return cleaned
    }

    private static func extractPrimaryHTML(from html: String) -> String {
        let body = Self.extractBodyHTML(from: html)
        let candidates = Self.candidateContentFragments(in: body)
        guard let best = candidates.max(by: { Self.contentScore(for: $0) < Self.contentScore(for: $1) }),
              Self.contentScore(for: best) > 120
        else {
            return body
        }
        return best
    }

    private static func htmlToMarkdown(_ html: String, fallbackTitle: String?) -> (text: String, title: String?) {
        var text = html
        text = Self.convertAnchorsToMarkdown(in: text)
        text = text.replacingOccurrences(of: "<h([1-6])[^>]*>([\\s\\S]*?)</h\\1>", with: "\n$2\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "<li[^>]*>([\\s\\S]*?)</li>", with: "\n- $1", options: .regularExpression)
        text = text.replacingOccurrences(of: "</(p|div|section|article|header|footer|table|tr|ul|ol|main|blockquote)>", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "<(td|th)[^>]*>", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "<(br|hr)\\s*/?>", with: "\n", options: .regularExpression)
        text = Self.stripTags(text)
        text = Self.filterNoiseLines(from: text)
        text = Self.normalizeWhitespace(text)
        return (text: text, title: fallbackTitle)
    }

    private static func convertAnchorsToMarkdown(in html: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: "<a\\b[^>]*href=[\"']([^\"']+)[\"'][^>]*>([\\s\\S]*?)</a>",
            options: [.caseInsensitive]
        ) else {
            return html
        }

        var output = html
        let range = NSRange(output.startIndex..., in: output)
        let matches = regex.matches(in: output, range: range)
        guard !matches.isEmpty else {
            return output
        }

        for match in matches.reversed() {
            guard let fullRange = Range(match.range(at: 0), in: output),
                  let hrefRange = Range(match.range(at: 1), in: output),
                  let labelRange = Range(match.range(at: 2), in: output)
            else {
                continue
            }

            let href = Self.normalizeWhitespace(Self.decodeHTMLEntities(String(output[hrefRange])))
            let label = Self.normalizeWhitespace(Self.stripTags(String(output[labelRange])))

            let replacement: String
            // Drop executable/non-navigational URLs to avoid useless markdown links.
            if Self.shouldDropMarkdownLinkDestination(href) {
                replacement = label
            } else {
                replacement = label.isEmpty ? href : "[\(label)](\(href))"
            }
            output.replaceSubrange(fullRange, with: replacement)
        }

        return output
    }

    private static func shouldDropMarkdownLinkDestination(_ destination: String) -> Bool {
        let normalized = destination.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else {
            return true
        }
        return normalized.hasPrefix("javascript:")
            || normalized.hasPrefix("vbscript:")
            || normalized.hasPrefix("data:")
            || normalized == "#"
            || normalized.hasPrefix("#")
    }

    private static func extractTitle(from html: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "<title[^>]*>([\\s\\S]*?)</title>", options: .caseInsensitive) else {
            return nil
        }
        let range = NSRange(html.startIndex..., in: html)
        guard let match = regex.firstMatch(in: html, range: range),
              let matchRange = Range(match.range(at: 1), in: html)
        else {
            return nil
        }
        let title = html[matchRange]
        return Self.normalizeWhitespace(Self.decodeHTMLEntities(String(title)))
    }

    private static func stripTags(_ value: String) -> String {
        let stripped = value.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        return Self.decodeHTMLEntities(stripped)
    }

    private static func extractBodyHTML(from html: String) -> String {
        guard let body = firstCapture(in: html, pattern: "<body\\b[^>]*>([\\s\\S]*?)</body>", options: [.caseInsensitive]) else {
            return html
        }
        return body
    }

    private static func candidateContentFragments(in html: String) -> [String] {
        var candidates: [String] = [html]
        candidates += Self.captures(in: html, pattern: "<(article|main)\\b[^>]*>([\\s\\S]*?)</\\1>", group: 2, options: [.caseInsensitive])

        let keywordPattern = Self.joinAlternation(primaryContentAttributeKeywords)
        let sectionPattern = "<(section|div)\\b(?=[^>]*(?:id|class)=['\"][^'\"]*(?:\(keywordPattern))[^'\"]*['\"])[^>]*>([\\s\\S]*?)</\\1>"
        candidates += Self.captures(
            in: html,
            pattern: sectionPattern.replacingOccurrences(of: "\(keywordPattern)", with: keywordPattern),
            group: 2,
            options: [.caseInsensitive]
        )
        return candidates.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private static func contentScore(for fragment: String) -> Double {
        let text = Self.normalizeWhitespace(Self.stripTags(fragment))
        guard text.count >= 120 else {
            return Double(text.count) - 400
        }

        let sentenceCount = Self.countMatches(in: text, pattern: "[.!?。！？]")
        let paragraphCount = Self.countMatches(in: fragment, pattern: "</p>|<br")
        let linkCount = Self.countMatches(in: fragment, pattern: "<a\\b")
        let headingCount = Self.countMatches(in: fragment, pattern: "<h[1-6]\\b")
        let noiseHits = Self.keywordHitCount(in: text.lowercased(), keywords: noiseAttributeKeywords)
        let contentHits = Self.keywordHitCount(in: fragment.lowercased(), keywords: primaryContentAttributeKeywords)
        let textDensity = Double(text.count) / Double(max(fragment.count, 1))

        return Double(text.count)
            + Double(sentenceCount * 18)
            + Double(paragraphCount * 35)
            + Double(headingCount * 12)
            + Double(contentHits * 40)
            + (textDensity * 220)
            - Double(linkCount * 30)
            - Double(noiseHits * 70)
    }

    private static func removeBlockElements(named tagNames: [String], from html: String) -> String {
        guard !tagNames.isEmpty else {
            return html
        }
        let pattern = "<(" + Self.joinAlternation(tagNames) + ")\\b[^>]*>[\\s\\S]*?</\\1>"
        return html.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
    }

    private static func removeVoidElements(named tagNames: [String], from html: String) -> String {
        guard !tagNames.isEmpty else {
            return html
        }
        let pattern = "<(?:" + Self.joinAlternation(tagNames) + ")\\b[^>]*?/?>"
        return html.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
    }

    private static func removeHiddenElements(from html: String) -> String {
        let pattern = "<([a-z0-9:-]+)\\b(?=[^>]*(?:\\bhidden\\b|aria-hidden\\s*=\\s*['\"]?true['\"]?|style\\s*=\\s*['\"][^'\"]*(?:display\\s*:\\s*none|visibility\\s*:\\s*hidden)[^'\"]*['\"])).*?>[\\s\\S]*?</\\1>"
        return html.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
    }

    private static func removeNoiseAttributedElements(from html: String) -> String {
        let keywordPattern = Self.joinAlternation(noiseAttributeKeywords)
        let pattern = "<([a-z0-9:-]+)\\b(?=[^>]*(?:id|class|role|aria-label|data-testid)\\s*=\\s*['\"][^'\"]*(?:" + keywordPattern + ")[^'\"]*['\"]).*?>[\\s\\S]*?</\\1>"
        return html.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
    }

    private static func filterNoiseLines(from value: String) -> String {
        let lines = value.components(separatedBy: .newlines)
        var filtered: [String] = []

        for rawLine in lines {
            let line = Self.normalizeWhitespace(rawLine)
            guard !line.isEmpty else {
                if filtered.last?.isEmpty == false {
                    filtered.append("")
                }
                continue
            }
            if Self.matchesAnyNoisePattern(line) || Self.isBoilerplateLine(line) {
                continue
            }
            filtered.append(line)
        }

        return filtered.joined(separator: "\n")
    }

    private static func matchesAnyNoisePattern(_ line: String) -> Bool {
        for pattern in noiseLinePatterns {
            if countMatches(in: line, pattern: pattern) > 0 {
                return true
            }
        }
        return false
    }

    private static func isBoilerplateLine(_ line: String) -> Bool {
        let lowercase = line.lowercased()
        let wordCount = lowercase.split(whereSeparator: \.isWhitespace).count
        let urlLikeCount = Self.countMatches(in: lowercase, pattern: "https?://|www\\.")
        let separatorCount = Self.countMatches(in: line, pattern: "[|·•/]")
        let uppercaseCount = line.unicodeScalars.filter { CharacterSet.uppercaseLetters.contains($0) }.count

        if urlLikeCount > 0 && line.count < 120 {
            return true
        }
        if separatorCount >= 3 && line.count < 100 {
            return true
        }
        if wordCount <= 4 && uppercaseCount == line.count && line.count > 1 {
            return true
        }

        return false
    }

    private static func normalizeWhitespace(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "[ \t]+\n", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .replacingOccurrences(of: "[ \t]{2,}", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeHTMLEntities(_ value: String) -> String {
        var text = value
        text = text.replacingOccurrences(of: "&nbsp;", with: " ", options: .caseInsensitive)
        text = text.replacingOccurrences(of: "&amp;", with: "&", options: .caseInsensitive)
        text = text.replacingOccurrences(of: "&quot;", with: "\"", options: .caseInsensitive)
        text = text.replacingOccurrences(of: "&#39;", with: "'", options: .caseInsensitive)
        text = text.replacingOccurrences(of: "&lt;", with: "<", options: .caseInsensitive)
        text = text.replacingOccurrences(of: "&gt;", with: ">", options: .caseInsensitive)
        return text
    }

    private static func markdownToText(_ markdown: String) -> String {
        var text = markdown
        text = text.replacingOccurrences(of: "!\\[[^\\]]*]\\([^)]+\\)", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\[([^\\]]+)]\\([^)]+\\)", with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: "```[\\s\\S]*?```", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "`([^`]+)`", with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?m)^#{1,6}\\s+", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?m)^\\s*[-*+]\\s+", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?m)^\\s*\\d+\\.\\s+", with: "", options: .regularExpression)
        text = Self.filterNoiseLines(from: text)
        return Self.normalizeWhitespace(text)
    }

    private static func firstCapture(
        in value: String,
        pattern: String,
        options: NSRegularExpression.Options = []
    ) -> String? {
        captures(in: value, pattern: pattern, group: 1, options: options).first
    }

    private static func captures(
        in value: String,
        pattern: String,
        group: Int,
        options: NSRegularExpression.Options = []
    ) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            return []
        }
        let range = NSRange(value.startIndex..., in: value)
        return regex.matches(in: value, range: range).compactMap { match in
            guard let captureRange = Range(match.range(at: group), in: value) else {
                return nil
            }
            return String(value[captureRange])
        }
    }

    private static func countMatches(in value: String, pattern: String) -> Int {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return 0
        }
        let range = NSRange(value.startIndex..., in: value)
        return regex.numberOfMatches(in: value, range: range)
    }

    private static func keywordHitCount(in value: String, keywords: [String]) -> Int {
        keywords.reduce(into: 0) { partialResult, keyword in
            if value.contains(keyword) {
                partialResult += 1
            }
        }
    }

    private static func joinAlternation(_ fragments: [String]) -> String {
        fragments.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
    }

    private static func truncate(_ value: String, maxChars: Int) -> (text: String, truncated: Bool, rawLength: Int) {
        let rawLength = value.count
        guard rawLength > maxChars else {
            return (text: value, truncated: false, rawLength: rawLength)
        }
        let endIndex = value.index(value.startIndex, offsetBy: maxChars)
        return (text: String(value[..<endIndex]), truncated: true, rawLength: rawLength)
    }

    enum ExtractMode: String, Codable {
        case markdown
        case text
    }

    enum WebFetchError: Error, LocalizedError {
        case invalidURL
        case privateNetworkBlocked
        case invalidResponse
        case httpError(statusCode: Int)
        case unknownContentType
        case unsupportedContentType(String)

        var errorDescription: String? {
            switch self {
            case .invalidURL:
                return "Invalid URL"
            case .privateNetworkBlocked:
                return "Blocked URL: local/private network addresses are not allowed"
            case .invalidResponse:
                return "Invalid HTTP response"
            case let .httpError(code):
                return "HTTP error: \(code)"
            case .unknownContentType:
                return "Unknown content type"
            case let .unsupportedContentType(type):
                return "Unsupported content type: \(type)"
            }
        }
    }
}

struct WebFetchResult: Codable {
    let url: String
    let finalUrl: String
    let status: Int
    let contentType: String
    let title: String?
    let text: String
    let extractMode: String
    let extractor: String
    let truncated: Bool
    let rawLength: Int
    let length: Int
    let warning: String?
    let message: String // Human-readable summary for UI display

    /// Render result as plain text sections that are easier for LLMs to consume than JSON.
    func asAIFriendlyText() -> String {
        var metadataAttributes: [String] = [
            "status=\"\(status)\"",
            "url=\"\(Self.xmlEscaped(url))\"",
            "length=\"\(length)\"",
            "truncated=\"\(truncated ? 1 : 0)\"",
        ]
        if finalUrl != url {
            metadataAttributes.append("final-url=\"\(Self.xmlEscaped(finalUrl))\"")
        }
        metadataAttributes.append("content-type=\"\(Self.xmlEscaped(contentType))\"")
        if let title, !title.isEmpty {
            metadataAttributes.append("title=\"\(Self.xmlEscaped(title))\"")
        }
        if let warning, !warning.isEmpty {
            metadataAttributes.append("warning=\"\(Self.xmlEscaped(warning))\"")
        }

        let metaLine = "<metadata \(metadataAttributes.joined(separator: " "))/>"
        let contentText = Self.xmlEscaped(text)
        return "\(metaLine)\n<content>\n\(contentText)\n</content>"
    }

    /// Escape special characters to keep XML output valid and machine-readable.
    private static func xmlEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}

private final class RedirectLimiter: NSObject, URLSessionTaskDelegate {
    private let maxRedirects: Int
    private let lock = NSLock()
    private var redirectCounts: [Int: Int] = [:]

    init(maxRedirects: Int) {
        self.maxRedirects = max(0, maxRedirects)
    }

    func urlSession(
        _: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        let nextCount = incrementRedirectCount(for: task)
        if nextCount > maxRedirects {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    func urlSession(_: URLSession, task: URLSessionTask, didCompleteWithError _: Error?) {
        clearRedirectCount(for: task)
    }

    private func incrementRedirectCount(for task: URLSessionTask) -> Int {
        lock.lock()
        defer { self.lock.unlock() }
        let count = (redirectCounts[task.taskIdentifier] ?? 0) + 1
        redirectCounts[task.taskIdentifier] = count
        return count
    }

    private func clearRedirectCount(for task: URLSessionTask) {
        lock.lock()
        defer { self.lock.unlock() }
        redirectCounts[task.taskIdentifier] = nil
    }
}
