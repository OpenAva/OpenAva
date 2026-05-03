import ChatUI
import Foundation
import OpenClawKit
import OpenClawProtocol
import UserNotifications

final class BlogWatchTools: ToolDefinitionProvider {
    nonisolated func toolDefinitions() -> [ToolDefinition] {
        [
            ToolDefinition(
                functionName: "blog_watch",
                command: "blog.watch",
                description: "Scan blog feeds configured from HEARTBEAT.md input or explicit sources, detect newly published articles, persist state in the active agent context, and optionally send a local notification.",
                parametersSchema: AnyCodable([
                    "type": "object",
                    "properties": [
                        "action": [
                            "type": "string",
                            "enum": ["scan"],
                            "description": "Currently only supports scan",
                        ],
                        "sources": [
                            "type": "array",
                            "description": "Blogs to monitor. Usually copied from a Blog Watch block in HEARTBEAT.md.",
                            "items": [
                                "type": "object",
                                "properties": [
                                    "id": ["type": "string"],
                                    "name": ["type": "string"],
                                    "site_url": ["type": "string"],
                                    "feed_url": ["type": "string"],
                                    "notify": ["type": "boolean"],
                                ],
                                "required": ["name", "site_url"],
                                "additionalProperties": false,
                            ],
                        ],
                        "send_notification": [
                            "type": "boolean",
                            "description": "Whether the tool should send a local notification when new articles are found. Default true.",
                        ],
                        "skip_initial_baseline": [
                            "type": "boolean",
                            "description": "When true, the first successful scan seeds state without notifying. Default true.",
                        ],
                    ],
                    "required": ["action", "sources"],
                    "additionalProperties": false,
                ] as [String: Any]),
                isReadOnly: false,
                isDestructive: false,
                isConcurrencySafe: false,
                maxResultSizeChars: 32 * 1024
            ),
        ]
    }

    func registerHandlers(into handlers: inout [String: ToolHandler], context: ToolHandlerRegistrationContext) {
        handlers["blog.watch"] = { request in
            try await Self.handleBlogWatchInvoke(request, context: context)
        }
    }
}

extension BlogWatchTools {
    struct TestSourceInput {
        let id: String?
        let name: String
        let siteURL: String
        let feedURL: String?
        let notify: Bool?

        init(id: String? = nil, name: String, siteURL: String, feedURL: String? = nil, notify: Bool? = nil) {
            self.id = id
            self.name = name
            self.siteURL = siteURL
            self.feedURL = feedURL
            self.notify = notify
        }
    }

    struct TestNormalizedSource: Equatable {
        let id: String
        let name: String
        let siteURL: String
        let feedURL: String?
        let notify: Bool?
    }

    struct TestFeedItem: Equatable {
        let title: String
        let url: String
        let publishedAt: Date?

        init(title: String, url: String, publishedAt: Date?) {
            self.title = title
            self.url = url
            self.publishedAt = publishedAt
        }
    }

    struct TestScanResult: Equatable {
        struct SourceResult: Equatable {
            let id: String
            let newCount: Int
            let baselineSeeded: Bool
            let error: String?
        }

        let newArticleCount: Int
        let notified: Bool
        let statePath: String
        let sourceResults: [SourceResult]
    }

    static func testNormalizeSources(_ sources: [TestSourceInput]) -> [TestNormalizedSource] {
        normalizeSources(
            sources.map {
                Params.Source(id: $0.id, name: $0.name, site_url: $0.siteURL, feed_url: $0.feedURL, notify: $0.notify)
            }
        ).map {
            TestNormalizedSource(id: $0.id, name: $0.name, siteURL: $0.siteURL, feedURL: $0.feedURL, notify: $0.notify)
        }
    }

    static func testSlugify(_ text: String) -> String {
        slugify(text)
    }

    static func testDedupe(_ items: [TestFeedItem]) -> [TestFeedItem] {
        dedupe(items: items.map { FeedItem(title: $0.title, url: $0.url, publishedAt: $0.publishedAt) })
            .map { TestFeedItem(title: $0.title, url: $0.url, publishedAt: $0.publishedAt) }
    }

    static func testHeartbeatTemplate() -> String {
        heartbeatTemplate()
    }

    static func testHandleInvoke(_ request: BridgeInvokeRequest, context: ToolHandlerRegistrationContext) async throws -> BridgeInvokeResponse {
        try await handleBlogWatchInvoke(request, context: context)
    }

    static func testParseFeedItems(xml: String) throws -> [TestFeedItem] {
        try SimpleFeedParser(data: Data(xml.utf8)).parse().map {
            TestFeedItem(title: $0.title, url: $0.url, publishedAt: $0.publishedAt)
        }
    }

    static func testHandleInvoke(
        _ request: BridgeInvokeRequest,
        supportRootURL: URL,
        fetchedItemsByURL: [String: [TestFeedItem]],
        notificationResult: Bool = true
    ) async throws -> TestScanResult {
        fetchFeedItemsOverride = { feedURLString in
            if let items = fetchedItemsByURL[feedURLString] {
                return items.map { FeedItem(title: $0.title, url: $0.url, publishedAt: $0.publishedAt) }
            }
            throw NSError(domain: "BlogWatchTest", code: 404, userInfo: [NSLocalizedDescriptionKey: "missing test feed"])
        }
        sendLocalNotificationOverride = { _ in notificationResult }
        defer {
            fetchFeedItemsOverride = nil
            sendLocalNotificationOverride = nil
        }

        let response = try await handleBlogWatchInvoke(
            request,
            context: ToolHandlerRegistrationContext(activeSupportRootURLProvider: { supportRootURL })
        )
        guard response.ok, let payload = response.payload?.data(using: .utf8) else {
            throw NSError(domain: "BlogWatchTest", code: 500, userInfo: [NSLocalizedDescriptionKey: response.error?.message ?? "missing payload"])
        }
        let decoded = try JSONDecoder().decode(ScanResultPayload.self, from: payload)
        return TestScanResult(
            newArticleCount: decoded.newArticleCount,
            notified: decoded.notified,
            statePath: decoded.statePath,
            sourceResults: decoded.results.map {
                TestScanResult.SourceResult(id: $0.id, newCount: $0.newCount, baselineSeeded: $0.baselineSeeded, error: $0.error)
            }
        )
    }

    static func testPersistedState(supportRootURL: URL) -> (sourceCount: Int, articleCount: Int, notifiedCount: Int) {
        let state = loadState(supportRootURL: supportRootURL)
        return (
            sourceCount: state.sources.count,
            articleCount: state.articles.count,
            notifiedCount: state.articles.filter { $0.notifiedAt != nil }.count
        )
    }
}

private extension BlogWatchTools {
    static var fetchFeedItemsOverride: (@Sendable (String) async throws -> [FeedItem])?
    static var sendLocalNotificationOverride: (@Sendable ([ScanResultPayload.ArticleSummary]) async throws -> Bool)?

    struct Params: Codable {
        struct Source: Codable {
            let id: String?
            let name: String
            let site_url: String
            let feed_url: String?
            let notify: Bool?
        }

        let action: String
        let sources: [Source]
        let send_notification: Bool?
        let skip_initial_baseline: Bool?
    }

    struct PersistedState: Codable {
        struct SourceState: Codable {
            var id: String
            var name: String
            var siteURL: String
            var feedURL: String?
            var baselineEstablishedAt: Date?
            var lastScannedAt: Date?
            var lastError: String?
        }

        struct ArticleState: Codable {
            let sourceID: String
            let title: String
            let url: String
            let publishedAt: Date?
            let discoveredAt: Date
            var notifiedAt: Date?
        }

        var sources: [SourceState]
        var articles: [ArticleState]
    }

    struct ScanResultPayload: Codable {
        struct SourceResult: Codable {
            let id: String
            let name: String
            let siteURL: String
            let feedURL: String?
            let totalFound: Int
            let newCount: Int
            let baselineSeeded: Bool
            let error: String?
            let newArticles: [ArticleSummary]
        }

        struct ArticleSummary: Codable {
            let sourceID: String
            let title: String
            let url: String
            let publishedAt: String?
        }

        let newArticleCount: Int
        let notified: Bool
        let statePath: String
        let heartbeatTemplate: String
        let results: [SourceResult]
    }

    struct FeedItem {
        let title: String
        let url: String
        let publishedAt: Date?
    }

    static func handleBlogWatchInvoke(_ request: BridgeInvokeRequest, context: ToolHandlerRegistrationContext) async throws -> BridgeInvokeResponse {
        let params = try ToolInvocationHelpers.decodeParams(Params.self, from: request.paramsJSON)
        guard params.action == "scan" else {
            return ToolInvocationHelpers.invalidRequest(id: request.id, "unsupported action")
        }
        guard let supportRootURL = context.activeSupportRootURLProvider()?.standardizedFileURL else {
            return ToolInvocationHelpers.unavailableResponse(id: request.id, "UNAVAILABLE: active agent context root unavailable")
        }
        let normalizedSources = normalizeSources(params.sources)
        guard !normalizedSources.isEmpty else {
            return ToolInvocationHelpers.invalidRequest(id: request.id, "at least one valid source is required")
        }

        var state = loadState(supportRootURL: supportRootURL)
        var results: [ScanResultPayload.SourceResult] = []
        var notificationArticles: [ScanResultPayload.ArticleSummary] = []
        let sendNotification = params.send_notification ?? true
        let skipInitialBaseline = params.skip_initial_baseline ?? true
        let now = Date()

        for source in normalizedSources {
            let sourceID = source.id
            let feedURL = source.feedURL ?? source.siteURL
            do {
                let fetched = try await fetchFeedItems(feedURLString: feedURL)
                let deduped = dedupe(items: fetched)
                let totalFound = deduped.count

                var sourceState = state.sources.first(where: { $0.id == sourceID })
                    ?? PersistedState.SourceState(
                        id: sourceID,
                        name: source.name,
                        siteURL: source.siteURL,
                        feedURL: source.feedURL,
                        baselineEstablishedAt: nil,
                        lastScannedAt: nil,
                        lastError: nil
                    )

                sourceState.name = source.name
                sourceState.siteURL = source.siteURL
                sourceState.feedURL = source.feedURL ?? sourceState.feedURL
                sourceState.lastScannedAt = now
                sourceState.lastError = nil

                let knownURLs = Set(state.articles.filter { $0.sourceID == sourceID }.map(\.url))
                let isInitialSeed = sourceState.baselineEstablishedAt == nil && skipInitialBaseline

                var newArticles: [PersistedState.ArticleState] = []
                for item in deduped where !knownURLs.contains(item.url) {
                    newArticles.append(
                        PersistedState.ArticleState(
                            sourceID: sourceID,
                            title: item.title,
                            url: item.url,
                            publishedAt: item.publishedAt,
                            discoveredAt: now,
                            notifiedAt: nil
                        )
                    )
                }

                let baselineSeeded = isInitialSeed
                if sourceState.baselineEstablishedAt == nil {
                    sourceState.baselineEstablishedAt = now
                }

                if !newArticles.isEmpty {
                    state.articles.append(contentsOf: newArticles)
                }
                upsertSourceState(&state, sourceState)

                let notifyThisSource = sendNotification && (source.notify ?? true) && !baselineSeeded
                let visibleNewArticles = baselineSeeded ? [] : newArticles
                if notifyThisSource, !visibleNewArticles.isEmpty {
                    for article in visibleNewArticles {
                        if let index = state.articles.firstIndex(where: { $0.sourceID == article.sourceID && $0.url == article.url }) {
                            state.articles[index].notifiedAt = now
                        }
                    }
                }

                let summaries = visibleNewArticles.map {
                    ScanResultPayload.ArticleSummary(
                        sourceID: $0.sourceID,
                        title: $0.title,
                        url: $0.url,
                        publishedAt: isoString($0.publishedAt)
                    )
                }
                if notifyThisSource {
                    notificationArticles.append(contentsOf: summaries)
                }

                results.append(
                    ScanResultPayload.SourceResult(
                        id: sourceID,
                        name: source.name,
                        siteURL: source.siteURL,
                        feedURL: source.feedURL,
                        totalFound: totalFound,
                        newCount: summaries.count,
                        baselineSeeded: baselineSeeded,
                        error: nil,
                        newArticles: summaries
                    )
                )
            } catch {
                var sourceState = state.sources.first(where: { $0.id == sourceID })
                    ?? PersistedState.SourceState(
                        id: sourceID,
                        name: source.name,
                        siteURL: source.siteURL,
                        feedURL: source.feedURL,
                        baselineEstablishedAt: nil,
                        lastScannedAt: nil,
                        lastError: nil
                    )
                sourceState.lastScannedAt = now
                sourceState.lastError = error.localizedDescription
                upsertSourceState(&state, sourceState)

                results.append(
                    ScanResultPayload.SourceResult(
                        id: sourceID,
                        name: source.name,
                        siteURL: source.siteURL,
                        feedURL: source.feedURL,
                        totalFound: 0,
                        newCount: 0,
                        baselineSeeded: false,
                        error: error.localizedDescription,
                        newArticles: []
                    )
                )
            }
        }

        try persistState(state, supportRootURL: supportRootURL)

        var notified = false
        if sendNotification, !notificationArticles.isEmpty {
            notified = try await sendLocalNotification(notificationArticles)
        }

        let payload = ScanResultPayload(
            newArticleCount: notificationArticles.count,
            notified: notified,
            statePath: stateURL(supportRootURL: supportRootURL).path,
            heartbeatTemplate: heartbeatTemplate(),
            results: results
        )
        let json = try ToolInvocationHelpers.encodePayload(payload)
        return ToolInvocationHelpers.successResponse(id: request.id, payload: json)
    }

    struct NormalizedSource {
        let id: String
        let name: String
        let siteURL: String
        let feedURL: String?
        let notify: Bool?
    }

    static func normalizeSources(_ sources: [Params.Source]) -> [NormalizedSource] {
        sources.compactMap { source in
            let name = source.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let siteURL = source.site_url.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !siteURL.isEmpty, URL(string: siteURL) != nil else {
                return nil
            }
            let providedID = source.id?.trimmingCharacters(in: .whitespacesAndNewlines)
            let id = (providedID?.isEmpty == false ? providedID! : slugify(name))
            let feedURL = source.feed_url?.trimmingCharacters(in: .whitespacesAndNewlines)
            return NormalizedSource(id: id, name: name, siteURL: siteURL, feedURL: feedURL?.isEmpty == true ? nil : feedURL, notify: source.notify)
        }
    }

    static func slugify(_ text: String) -> String {
        let lowered = text.lowercased()
        let mapped = lowered.map { char -> Character in
            if char.isLetter || char.isNumber { return char }
            return "-"
        }
        let raw = String(mapped)
        let collapsed = raw.replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
        return collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    static func stateURL(supportRootURL: URL) -> URL {
        supportRootURL
            .appendingPathComponent("blog-watcher", isDirectory: true)
            .appendingPathComponent("state.json", isDirectory: false)
    }

    static func loadState(supportRootURL: URL) -> PersistedState {
        let url = stateURL(supportRootURL: supportRootURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url),
              let state = try? decoder.decode(PersistedState.self, from: data)
        else {
            return PersistedState(sources: [], articles: [])
        }
        return state
    }

    static func persistState(_ state: PersistedState, supportRootURL: URL) throws {
        let url = stateURL(supportRootURL: supportRootURL)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(state)
        try data.write(to: url, options: .atomic)
    }

    static func upsertSourceState(_ state: inout PersistedState, _ sourceState: PersistedState.SourceState) {
        if let index = state.sources.firstIndex(where: { $0.id == sourceState.id }) {
            state.sources[index] = sourceState
        } else {
            state.sources.append(sourceState)
        }
    }

    static func dedupe(items: [FeedItem]) -> [FeedItem] {
        var seen: Set<String> = []
        var result: [FeedItem] = []
        for item in items {
            guard !seen.contains(item.url) else { continue }
            seen.insert(item.url)
            result.append(item)
        }
        return result
    }

    static func fetchFeedItems(feedURLString: String) async throws -> [FeedItem] {
        if let fetchFeedItemsOverride {
            return try await fetchFeedItemsOverride(feedURLString)
        }
        guard let url = URL(string: feedURLString) else {
            throw NSError(domain: "BlogWatch", code: 1, userInfo: [NSLocalizedDescriptionKey: "invalid feed URL"])
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200 ... 299).contains(http.statusCode) else {
            throw NSError(domain: "BlogWatch", code: 2, userInfo: [NSLocalizedDescriptionKey: "failed to fetch feed"])
        }
        let parser = SimpleFeedParser(data: data)
        let items = try parser.parse()
        return items.filter { !$0.title.isEmpty && !$0.url.isEmpty }
    }

    static func sendLocalNotification(_ articles: [ScanResultPayload.ArticleSummary]) async throws -> Bool {
        if let sendLocalNotificationOverride {
            return try await sendLocalNotificationOverride(articles)
        }
        guard !articles.isEmpty else { return false }
        let center = LiveNotificationCenter()
        let status = await center.authorizationStatus()
        if status == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        }
        let refreshedStatus = await center.authorizationStatus()
        guard refreshedStatus == .authorized || refreshedStatus == .provisional || refreshedStatus == .ephemeral else {
            return false
        }

        let content = UNMutableNotificationContent()
        content.title = articles.count == 1
            ? L10n.tr("blogWatch.notification.title.single")
            : L10n.tr("blogWatch.notification.title.multiple", articles.count)
        let titles = articles.prefix(3).map(\.title).joined(separator: L10n.tr("blogWatch.notification.titleSeparator"))
        content.body = titles.isEmpty ? L10n.tr("blogWatch.notification.body.fallback") : titles
        content.sound = .default
        let request = UNNotificationRequest(identifier: "blog-watch.\(UUID().uuidString)", content: content, trigger: nil)
        try await center.add(request)
        return true
    }

    static func isoString(_ date: Date?) -> String? {
        guard let date else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    static func heartbeatTemplate() -> String {
        L10n.tr("blogWatch.heartbeat.template")
    }
}

private final class SimpleFeedParser: NSObject, XMLParserDelegate {
    private let parser: XMLParser
    private var items: [BlogWatchTools.FeedItem] = []
    private var currentElement = ""
    private var currentTitle = ""
    private var currentLink = ""
    private var currentPublished = ""
    private var inItem = false
    private var inEntry = false

    init(data: Data) {
        parser = XMLParser(data: data)
        super.init()
        parser.delegate = self
    }

    func parse() throws -> [BlogWatchTools.FeedItem] {
        guard parser.parse() else {
            throw parser.parserError ?? NSError(domain: "BlogWatch", code: 3, userInfo: [NSLocalizedDescriptionKey: "failed to parse feed"])
        }
        return items
    }

    func parser(_: XMLParser, didStartElement elementName: String, namespaceURI _: String?, qualifiedName _: String?, attributes attributeDict: [String: String] = [:]) {
        currentElement = elementName.lowercased()
        if currentElement == "item" {
            resetCurrentItem()
            inItem = true
        } else if currentElement == "entry" {
            resetCurrentItem()
            inEntry = true
        } else if inEntry, currentElement == "link", currentLink.isEmpty {
            let rel = attributeDict["rel"]?.lowercased()
            if rel == nil || rel == "alternate" {
                currentLink = attributeDict["href"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? currentLink
            }
        }
    }

    func parser(_: XMLParser, foundCharacters string: String) {
        guard inItem || inEntry else { return }
        switch currentElement {
        case "title": currentTitle += string
        case "link": if inItem { currentLink += string }
        case "pubdate", "published", "updated": currentPublished += string
        default: break
        }
    }

    func parser(_: XMLParser, didEndElement elementName: String, namespaceURI _: String?, qualifiedName _: String?) {
        let name = elementName.lowercased()
        if name == "item", inItem {
            appendCurrentItem()
            inItem = false
        } else if name == "entry", inEntry {
            appendCurrentItem()
            inEntry = false
        }
        currentElement = ""
    }

    private func resetCurrentItem() {
        currentTitle = ""
        currentLink = ""
        currentPublished = ""
    }

    private func appendCurrentItem() {
        let title = currentTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let link = currentLink.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !link.isEmpty else { return }
        items.append(.init(title: title, url: link, publishedAt: Self.parseDate(currentPublished)))
    }

    private static func parseDate(_ value: String) -> Date? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: trimmed) { return date }
        let fallbackISO = ISO8601DateFormatter()
        if let date = fallbackISO.date(from: trimmed) { return date }
        let rfc822 = DateFormatter()
        rfc822.locale = Locale(identifier: "en_US_POSIX")
        rfc822.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return rfc822.date(from: trimmed)
    }
}
