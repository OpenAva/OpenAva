import XCTest
@testable import OpenAva

final class WebFetchServiceTests: XCTestCase {
    func testExtractReadableContentFiltersCommonNoiseBlocks() {
        let html = """
        <!doctype html>
        <html>
        <head>
          <title>Example Article</title>
          <style>.hero { color: red; }</style>
          <script>window.analytics = true;</script>
        </head>
        <body>
          <nav>
            <a href="/home">Home</a>
            <a href="/pricing">Pricing</a>
          </nav>
          <div class="cookie-banner">Accept cookies</div>
          <main>
            <article>
              <h1>Example Article</h1>
              <p>The launch plan focuses on reliability, rollout safety, and measurable user value.</p>
              <p>Teams should stage the migration, watch regressions, and publish a concise status update.</p>
            </article>
          </main>
          <footer>
            <a href="/privacy">Privacy Policy</a>
            <a href="/terms">Terms of Service</a>
          </footer>
        </body>
        </html>
        """

        let result = WebFetchService.extractReadableContentForTesting(from: html)

        XCTAssertEqual(result.title, "Example Article")
        XCTAssertTrue(result.text.contains("launch plan focuses on reliability"))
        XCTAssertTrue(result.text.contains("publish a concise status update"))
        XCTAssertFalse(result.text.localizedCaseInsensitiveContains("pricing"))
        XCTAssertFalse(result.text.localizedCaseInsensitiveContains("accept cookies"))
        XCTAssertFalse(result.text.localizedCaseInsensitiveContains("privacy policy"))
        XCTAssertFalse(result.text.localizedCaseInsensitiveContains("analytics"))
    }

    func testExtractReadableContentPrefersPrimaryContentOverSidebarNoise() {
        let html = """
        <html>
        <head><title>Deep Dive</title></head>
        <body>
          <div class="layout">
            <aside class="sidebar related-links">
              <a href="/a">Related Articles</a>
              <a href="/b">Read More</a>
              <a href="/c">Sponsored</a>
            </aside>
            <section class="post-content">
              <h1>System Design Notes</h1>
              <p>This document explains the queue handoff model and the recovery logic around network failures.</p>
              <p>It also covers retry budgets, tracing boundaries, and how to reduce operator toil during incidents.</p>
              <p>Finally, it outlines success metrics and rollout checkpoints for the next release.</p>
            </section>
          </div>
        </body>
        </html>
        """

        let result = WebFetchService.extractReadableContentForTesting(from: html)

        XCTAssertEqual(result.title, "Deep Dive")
        XCTAssertTrue(result.markdown.contains("System Design Notes"))
        XCTAssertTrue(result.text.contains("queue handoff model"))
        XCTAssertTrue(result.text.contains("retry budgets"))
        XCTAssertFalse(result.text.localizedCaseInsensitiveContains("sponsored"))
        XCTAssertFalse(result.text.localizedCaseInsensitiveContains("related articles"))
        XCTAssertFalse(result.text.localizedCaseInsensitiveContains("read more"))
    }

    func testExtractReadableContentDropsJavascriptStyleLinkTargets() {
        let html = """
        <html>
        <head><title>Link Filtering</title></head>
        <body>
          <article>
            <p>See <a href="javascript:void(0)">details</a> and
            <a href="https://example.com/report">full report</a>.</p>
            <p><a href="#comments">Jump to comments</a></p>
          </article>
        </body>
        </html>
        """

        let result = WebFetchService.extractReadableContentForTesting(from: html)

        XCTAssertTrue(result.markdown.contains("details"))
        XCTAssertFalse(result.markdown.localizedCaseInsensitiveContains("javascript:void(0)"))
    }
}
