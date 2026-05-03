import Foundation
import OpenClawKit
import XCTest
@testable import OpenAva

final class BlogWatchToolsTests: XCTestCase {
    func testFirstScanSeedsBaselineWithoutNotification() async throws {
        let supportRoot = makeSupportRoot()
        defer { try? FileManager.default.removeItem(at: supportRoot) }

        let request = makeScanRequest(skipInitialBaseline: true)
        let result = try await BlogWatchTools.testHandleInvoke(
            request,
            supportRootURL: supportRoot,
            fetchedItemsByURL: [
                "https://example.com/feed.xml": [
                    .init(title: "Article A", url: "https://example.com/a", publishedAt: Date(timeIntervalSince1970: 100)),
                ],
            ]
        )

        XCTAssertEqual(result.newArticleCount, 0)
        XCTAssertFalse(result.notified)
        XCTAssertEqual(result.sourceResults.first?.baselineSeeded, true)

        let state = BlogWatchTools.testPersistedState(supportRootURL: supportRoot)
        XCTAssertEqual(state.sourceCount, 1)
        XCTAssertEqual(state.articleCount, 1)
        XCTAssertEqual(state.notifiedCount, 0)
    }

    func testSecondScanReportsOnlyNewArticlesAndMarksNotified() async throws {
        let supportRoot = makeSupportRoot()
        defer { try? FileManager.default.removeItem(at: supportRoot) }

        let request = makeScanRequest(skipInitialBaseline: true)
        _ = try await BlogWatchTools.testHandleInvoke(
            request,
            supportRootURL: supportRoot,
            fetchedItemsByURL: [
                "https://example.com/feed.xml": [
                    .init(title: "Article A", url: "https://example.com/a", publishedAt: Date(timeIntervalSince1970: 100)),
                ],
            ]
        )

        let second = try await BlogWatchTools.testHandleInvoke(
            request,
            supportRootURL: supportRoot,
            fetchedItemsByURL: [
                "https://example.com/feed.xml": [
                    .init(title: "Article A", url: "https://example.com/a", publishedAt: Date(timeIntervalSince1970: 100)),
                    .init(title: "Article B", url: "https://example.com/b", publishedAt: Date(timeIntervalSince1970: 200)),
                ],
            ],
            notificationResult: true
        )

        XCTAssertEqual(second.newArticleCount, 1)
        XCTAssertTrue(second.notified)
        XCTAssertEqual(second.sourceResults.first?.newCount, 1)
        XCTAssertEqual(second.sourceResults.first?.baselineSeeded, false)

        let state = BlogWatchTools.testPersistedState(supportRootURL: supportRoot)
        XCTAssertEqual(state.articleCount, 2)
        XCTAssertEqual(state.notifiedCount, 1)
    }

    func testPersistedStateSurvivesAcrossScans() async throws {
        let supportRoot = makeSupportRoot()
        defer { try? FileManager.default.removeItem(at: supportRoot) }

        let request = makeScanRequest(skipInitialBaseline: true)
        _ = try await BlogWatchTools.testHandleInvoke(
            request,
            supportRootURL: supportRoot,
            fetchedItemsByURL: [
                "https://example.com/feed.xml": [
                    .init(title: "Article A", url: "https://example.com/a", publishedAt: nil),
                    .init(title: "Article B", url: "https://example.com/b", publishedAt: nil),
                ],
            ]
        )

        let loaded = BlogWatchTools.testPersistedState(supportRootURL: supportRoot)
        XCTAssertEqual(loaded.sourceCount, 1)
        XCTAssertEqual(loaded.articleCount, 2)
    }

    func testParseRSSAndAtomFeeds() throws {
        let rss = """
        <rss><channel><item><title>RSS Title</title><link>https://example.com/rss</link><pubDate>Tue, 01 Apr 2025 12:00:00 +0000</pubDate></item></channel></rss>
        """
        let atom = """
        <feed xmlns="http://www.w3.org/2005/Atom"><entry><title>Atom Title</title><link href="https://example.com/atom" /><updated>2025-04-01T12:00:00Z</updated></entry></feed>
        """

        let rssItems = try BlogWatchTools.testParseFeedItems(xml: rss)
        let atomItems = try BlogWatchTools.testParseFeedItems(xml: atom)

        XCTAssertEqual(rssItems.first?.title, "RSS Title")
        XCTAssertEqual(rssItems.first?.url, "https://example.com/rss")
        XCTAssertEqual(atomItems.first?.title, "Atom Title")
        XCTAssertEqual(atomItems.first?.url, "https://example.com/atom")
    }

    func testSlugifyCollapsesSeparatorsAndLowercasesText() {
        XCTAssertEqual(BlogWatchTools.testSlugify("OpenAI   Blog!!!"), "openai-blog")
        XCTAssertEqual(BlogWatchTools.testSlugify(" Swift.org Updates "), "swift-org-updates")
    }

    func testDedupeKeepsFirstArticlePerURL() {
        let firstDate = Date(timeIntervalSince1970: 100)
        let secondDate = Date(timeIntervalSince1970: 200)
        let items = [
            BlogWatchTools.TestFeedItem(title: "First", url: "https://example.com/a", publishedAt: firstDate),
            BlogWatchTools.TestFeedItem(title: "Duplicate", url: "https://example.com/a", publishedAt: secondDate),
            BlogWatchTools.TestFeedItem(title: "Second", url: "https://example.com/b", publishedAt: nil),
        ]

        let deduped = BlogWatchTools.testDedupe(items)

        XCTAssertEqual(deduped.count, 2)
        XCTAssertEqual(deduped[0].title, "First")
        XCTAssertEqual(deduped[0].publishedAt, firstDate)
        XCTAssertEqual(deduped[1].url, "https://example.com/b")
    }

    func testHeartbeatTemplateContainsToolInstructions() {
        let template = BlogWatchTools.testHeartbeatTemplate()

        XCTAssertTrue(template.contains("blog_watch"))
        XCTAssertTrue(template.contains("Blog Watch"))
        XCTAssertTrue(template.contains("HEARTBEAT_OK"))
    }

    func testHandleInvokeReturnsUnavailableWhenSupportRootMissing() async throws {
        let request = try BridgeInvokeRequest(
            id: UUID().uuidString,
            command: "blog.watch",
            paramsJSON: """
            {"action":"scan","sources":[{"name":"OpenAI Blog","site_url":"https://openai.com/blog"}]}
            """
        )

        let response = try await BlogWatchTools.testHandleInvoke(
            request,
            context: ToolHandlerRegistrationContext(activeSupportRootURLProvider: { nil })
        )

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error?.code, .unavailable)
        XCTAssertEqual(response.error?.message, "UNAVAILABLE: active agent context root unavailable")
    }

    func testHandleInvokeRejectsWhenAllSourcesAreStructurallyInvalid() async throws {
        let request = try BridgeInvokeRequest(
            id: UUID().uuidString,
            command: "blog.watch",
            paramsJSON: """
            {"action":"scan","sources":[{"name":"","site_url":"https://example.com"},{"name":"Bad","site_url":""}]}
            """
        )

        let supportRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let response = try await BlogWatchTools.testHandleInvoke(
            request,
            context: ToolHandlerRegistrationContext(activeSupportRootURLProvider: { supportRoot })
        )

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error?.code, .invalidRequest)
        XCTAssertEqual(response.error?.message, "INVALID_REQUEST: at least one valid source is required")
    }

    func testNormalizeSourcesKeepsStructurallyValidRowsAndNormalizesIDs() {
        let normalized = BlogWatchTools.testNormalizeSources([
            .init(name: "OpenAI Blog", siteURL: "https://openai.com/blog", feedURL: "https://openai.com/blog/rss.xml"),
            .init(name: "", siteURL: "https://example.com"),
            .init(name: "Bad URL", siteURL: "not-a-url"),
            .init(id: " custom-id ", name: "Swift Blog", siteURL: "https://www.swift.org/blog/"),
        ])

        XCTAssertEqual(normalized.count, 3)
        XCTAssertEqual(normalized[0].id, "openai-blog")
        XCTAssertEqual(normalized[0].feedURL, "https://openai.com/blog/rss.xml")
        XCTAssertEqual(normalized[1].id, "bad-url")
        XCTAssertEqual(normalized[2].id, "custom-id")
    }

    private func makeSupportRoot() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeScanRequest(skipInitialBaseline: Bool) -> BridgeInvokeRequest {
        BridgeInvokeRequest(
            id: UUID().uuidString,
            command: "blog.watch",
            paramsJSON: """
            {"action":"scan","sources":[{"name":"Example Blog","site_url":"https://example.com","feed_url":"https://example.com/feed.xml"}],"skip_initial_baseline":\(
                skipInitialBaseline ? "true" : "false"
            )}
            """
        )
    }
}
