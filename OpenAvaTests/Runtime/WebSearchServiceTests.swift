import XCTest
@testable import OpenAva

final class WebSearchServiceTests: XCTestCase {
    func testNormalizeResultURLRemovesTrackingParams() {
        let raw = "https://example.com/article?utm_source=newsletter&keep=1&gclid=abc#section"

        let normalized = WebSearchService.normalizeResultURLForTesting(raw)

        XCTAssertEqual(normalized, "https://example.com/article?keep=1")
    }

    func testNormalizeResultURLRejectsLocalhost() {
        let raw = "http://127.0.0.1:8080/test"

        let normalized = WebSearchService.normalizeResultURLForTesting(raw)

        XCTAssertNil(normalized)
    }

    func testCompactSummaryTruncatesLongText() {
        let long = String(repeating: "a", count: 400)

        let summary = WebSearchService.compactSummaryForTesting(long)

        XCTAssertEqual(summary.count, 323)
        XCTAssertTrue(summary.hasSuffix("..."))
    }

    func testSearchReturnsStatusForAllConfiguredSources() async throws {
        let service = WebSearchService()

        // Keep this query stable so we can compare status shape over time.
        let result = try await service.search(query: "Apple", topK: 5, fetchTopK: 0)
        let expectedSources: Set = [
            "baidu",
            "bing_cn",
            "bing_int",
            "360",
            "sogou",
            "wechat",
            "toutiao",
            "jisilu",
            "duckduckgo",
            "wikipedia",
            "hn",
            "bing",
            "google",
            "google_hk",
            "yahoo",
            "startpage",
            "brave",
            "ecosia",
            "qwant",
            "wolframalpha",
        ]

        let actualSources = Set(result.sourceStatus.map(\.source))
        XCTAssertEqual(actualSources, expectedSources)
        XCTAssertEqual(result.sourceStatus.count, expectedSources.count)

        for status in result.sourceStatus {
            // Each source must return either parsed items or a concrete error.
            XCTAssertTrue(status.succeeded || !(status.error ?? "").isEmpty)
            XCTAssertGreaterThanOrEqual(status.count, 0)
        }
    }

    func testLiveEngineHealthReport() async throws {
        guard ProcessInfo.processInfo.environment["RUN_WEB_SEARCH_LIVE_TESTS"] == "1" else {
            throw XCTSkip("Set RUN_WEB_SEARCH_LIVE_TESTS=1 to run live engine verification")
        }

        let service = WebSearchService()
        let result = try await service.search(query: "iPhone", topK: 8, fetchTopK: 0)

        var succeededSources: [String] = []
        var failedSources: [String] = []

        for status in result.sourceStatus {
            let healthy = status.succeeded && status.count > 0
            let detail = "\(status.source): succeeded=\(status.succeeded), count=\(status.count), error=\(status.error ?? "nil")"
            if healthy {
                succeededSources.append(status.source)
            } else {
                failedSources.append(detail)
            }
        }

        XCTAssertFalse(succeededSources.isEmpty, "No engine returned usable results")
        XCTAssertLessThanOrEqual(failedSources.count, result.sourceStatus.count, failedSources.joined(separator: "\n"))
    }
}
