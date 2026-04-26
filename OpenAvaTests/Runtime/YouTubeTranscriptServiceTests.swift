import XCTest
@testable import OpenAva

final class YouTubeTranscriptServiceTests: XCTestCase {
    func testExtractVideoIDSupportsCommonFormats() throws {
        let watchURL = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
        let shortURL = "https://youtu.be/dQw4w9WgXcQ?t=43"
        let shortsURL = "https://www.youtube.com/shorts/dQw4w9WgXcQ"
        let embedURL = "https://www.youtube.com/embed/dQw4w9WgXcQ"

        XCTAssertEqual(try YouTubeTranscriptService.extractVideoIDForTesting(watchURL), "dQw4w9WgXcQ")
        XCTAssertEqual(try YouTubeTranscriptService.extractVideoIDForTesting(shortURL), "dQw4w9WgXcQ")
        XCTAssertEqual(try YouTubeTranscriptService.extractVideoIDForTesting(shortsURL), "dQw4w9WgXcQ")
        XCTAssertEqual(try YouTubeTranscriptService.extractVideoIDForTesting(embedURL), "dQw4w9WgXcQ")
    }

    func testExtractVideoIDRejectsInvalidInput() {
        XCTAssertThrowsError(try YouTubeTranscriptService.extractVideoIDForTesting("https://example.com/video"))
        XCTAssertThrowsError(try YouTubeTranscriptService.extractVideoIDForTesting("not-a-youtube-url"))
    }

    func testParseTranscriptXMLDecodesEntitiesAndStripsTags() {
        let xml = """
        <transcript>
          <text start="0.5" dur="1.2">Hello &amp; welcome</text>
          <text start="2.0" dur="1.0">Use &lt;b&gt;Swift&lt;/b&gt; &#x1F600;</text>
          <text start="3.5" dur="0.8">&#65;&#66;&#67; done</text>
          <text start="4.0" dur="0.5">   </text>
        </transcript>
        """

        let segments = YouTubeTranscriptService.parseTranscriptXMLForTesting(xml)

        XCTAssertEqual(segments.count, 3)
        XCTAssertEqual(segments[0].startSeconds, 0.5, accuracy: 0.0001)
        XCTAssertEqual(segments[0].durationSeconds, 1.2, accuracy: 0.0001)
        XCTAssertEqual(segments[0].text, "Hello & welcome")
        XCTAssertEqual(segments[1].text, "Use Swift 😀")
        XCTAssertEqual(segments[2].text, "ABC done")
    }

    func testParseTranscriptXMLSupportsSrv3Format() {
        let xml = """
        <timedtext>
          <body>
            <p t="500" d="1200">Hello &amp; welcome</p>
            <p t="2000" d="1000"><s t="0">Use</s><s t="350">Swift</s> &#x1F600;</p>
            <p t="3500" d="800">&#65;&#66;&#67; done</p>
            <p t="4000" d="500">   </p>
          </body>
        </timedtext>
        """

        let segments = YouTubeTranscriptService.parseTranscriptXMLForTesting(xml)

        XCTAssertEqual(segments.count, 3)
        XCTAssertEqual(segments[0].startSeconds, 0.5, accuracy: 0.0001)
        XCTAssertEqual(segments[0].durationSeconds, 1.2, accuracy: 0.0001)
        XCTAssertEqual(segments[0].text, "Hello & welcome")
        XCTAssertEqual(segments[1].startSeconds, 2.0, accuracy: 0.0001)
        XCTAssertEqual(segments[1].durationSeconds, 1.0, accuracy: 0.0001)
        XCTAssertEqual(segments[1].text, "Use Swift 😀")
        XCTAssertEqual(segments[2].text, "ABC done")
    }

    func testExtractPlayerResponseSupportsWindowAssignment() {
        let html = #"""
        <script>
        window["ytInitialPlayerResponse"] = {"captions":{"playerCaptionsTracklistRenderer":{"captionTracks":[{"baseUrl":"https://www.youtube.com/api/timedtext?v=dQw4w9WgXcQ","name":{"simpleText":"English"},"languageCode":"en"}]}}};
        </script>
        """#

        XCTAssertTrue(YouTubeTranscriptService.hasCaptionTracksInWatchHTMLForTesting(html))
    }

    func testExtractPlayerResponseSupportsJSONParseAssignment() {
        let html = #"""
        <script>
        ytInitialPlayerResponse = JSON.parse('{\"captions\":{\"playerCaptionsTracklistRenderer\":{\"captionTracks\":[{\"baseUrl\":\"https://www.youtube.com/api/timedtext?v=dQw4w9WgXcQ\",\"name\":{\"simpleText\":\"English\"},\"languageCode\":\"en\"}]}}}');
        </script>
        """#

        XCTAssertTrue(YouTubeTranscriptService.hasCaptionTracksInWatchHTMLForTesting(html))
    }

    func testParseTimedtextTrackListFallbackFormat() {
        let xml = #"""
        <transcript_list>
          <track id="0" name="" lang_code="en" lang_original="English" lang_translated="English"/>
          <track id="1" name="" lang_code="zh-Hans" lang_original="中文（简体）" lang_translated="Chinese (Simplified)"/>
          <track id="2" name="" lang_code="ja" kind="asr" lang_original="日本語" lang_translated="Japanese"/>
        </transcript_list>
        """#

        let languages = YouTubeTranscriptService.parseTimedtextTrackListXMLForTesting(xml, videoID: "dQw4w9WgXcQ")
        XCTAssertEqual(languages, ["en", "zh-Hans", "ja"])
    }

    func testSelectTrackFallsBackToDefaultWhenPreferredLanguageUnavailable() {
        let xml = #"""
        <transcript_list>
          <track id="0" name="" lang_code="en" lang_original="English" lang_translated="English"/>
          <track id="1" name="" lang_code="zh-Hans" lang_original="中文（简体）" lang_translated="Chinese (Simplified)"/>
        </transcript_list>
        """#

        let selected = YouTubeTranscriptService.selectTrackLanguageCodeForTesting(
            xml,
            videoID: "dQw4w9WgXcQ",
            preferredLanguage: "fr"
        )
        XCTAssertEqual(selected, "en")
    }

    func testSelectTrackUsesPreferredLanguageWhenAvailable() {
        let xml = #"""
        <transcript_list>
          <track id="0" name="" lang_code="en" lang_original="English" lang_translated="English"/>
          <track id="1" name="" lang_code="zh-Hans" lang_original="中文（简体）" lang_translated="Chinese (Simplified)"/>
        </transcript_list>
        """#

        let selected = YouTubeTranscriptService.selectTrackLanguageCodeForTesting(
            xml,
            videoID: "dQw4w9WgXcQ",
            preferredLanguage: "zh"
        )
        XCTAssertEqual(selected, "zh-Hans")
    }

    func testVisibleSegmentsPagesCreateStablePageSequence() {
        let document = YouTubeTranscriptDocument(
            videoID: "video1234567",
            input: "video1234567",
            title: "Long Video",
            language: "en",
            trackName: "English",
            totalSegmentCount: 3,
            transcript: "",
            segments: [
                YouTubeTranscriptSegment(startSeconds: 5, durationSeconds: 1, text: "Alpha"),
                YouTubeTranscriptSegment(startSeconds: 6, durationSeconds: 1, text: "Beta"),
                YouTubeTranscriptSegment(startSeconds: 7, durationSeconds: 1, text: "Gamma"),
            ],
            message: ""
        )

        let pages = YouTubeTranscriptService.makeVisibleSegmentsPages(
            from: document,
            maxPayloadChars: 110,
            preferredBodyChars: 60,
            reservedHeaderChars: 40
        )

        XCTAssertEqual(pages.count, 2)
        XCTAssertEqual(pages[0].startSegmentIndex, 0)
        XCTAssertEqual(pages[0].returnedSegmentCount, 2)
        XCTAssertTrue(pages[0].body.contains("1. [5.00s +1.00s] Alpha"))
        XCTAssertTrue(pages[0].body.contains("2. [6.00s +1.00s] Beta"))
        XCTAssertEqual(pages[1].startSegmentIndex, 2)
        XCTAssertEqual(pages[1].returnedSegmentCount, 1)
        XCTAssertTrue(pages[1].body.contains("3. [7.00s +1.00s] Gamma"))
    }

    func testVisibleTranscriptPagesCreateStablePageSequence() {
        let document = YouTubeTranscriptDocument(
            videoID: "video1234567",
            input: "video1234567",
            title: "Long Video",
            language: "zh-Hans",
            trackName: "Chinese",
            totalSegmentCount: 3,
            transcript: "",
            segments: [
                YouTubeTranscriptSegment(startSeconds: 20, durationSeconds: 1, text: "AAAA"),
                YouTubeTranscriptSegment(startSeconds: 21, durationSeconds: 1, text: "BBBB"),
                YouTubeTranscriptSegment(startSeconds: 22, durationSeconds: 1, text: "CCCC"),
            ],
            message: ""
        )

        let pages = YouTubeTranscriptService.makeVisibleTranscriptPages(
            from: document,
            maxPayloadChars: 80,
            preferredBodyChars: 10,
            reservedHeaderChars: 40
        )

        XCTAssertEqual(pages.count, 2)
        XCTAssertEqual(pages[0].startSegmentIndex, 0)
        XCTAssertEqual(pages[0].returnedSegmentCount, 2)
        XCTAssertEqual(pages[0].body, "AAAA\nBBBB")
        XCTAssertEqual(pages[1].startSegmentIndex, 2)
        XCTAssertEqual(pages[1].returnedSegmentCount, 1)
        XCTAssertEqual(pages[1].body, "CCCC")
    }

    func testDefaultTranscriptPagingFitsLargerTranscriptInSinglePage() {
        let repeated = String(repeating: "字", count: 14_000)
        let document = YouTubeTranscriptDocument(
            videoID: "video1234567",
            input: "video1234567",
            title: "Long Video",
            language: "zh-Hans",
            trackName: "Chinese",
            totalSegmentCount: 4,
            transcript: "",
            segments: [
                YouTubeTranscriptSegment(startSeconds: 20, durationSeconds: 1, text: repeated),
                YouTubeTranscriptSegment(startSeconds: 21, durationSeconds: 1, text: repeated),
                YouTubeTranscriptSegment(startSeconds: 22, durationSeconds: 1, text: repeated),
                YouTubeTranscriptSegment(startSeconds: 23, durationSeconds: 1, text: repeated),
            ],
            message: ""
        )

        let pages = YouTubeTranscriptService.makeVisibleTranscriptPages(from: document)

        XCTAssertEqual(pages.count, 1)
        XCTAssertEqual(pages[0].startSegmentIndex, 0)
        XCTAssertEqual(pages[0].returnedSegmentCount, 4)
    }

    func testToolDefinitionExposesPageParameterInsteadOfSizeParameters() throws {
        let definitions = YouTubeTranscriptService().toolDefinitions()
        let definition = try XCTUnwrap(definitions.first { $0.functionName == "youtube_transcript" })
        let schema = try XCTUnwrap(definition.parametersSchema.value as? [String: Any])
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        let page = try XCTUnwrap(properties["page"] as? [String: Any])

        XCTAssertEqual(page["type"] as? String, "integer")
        XCTAssertEqual(page["minimum"] as? Int, 1)
        XCTAssertNil(properties["startIndex"])
        XCTAssertNil(properties["maxSegments"])
        XCTAssertEqual(definition.maxResultSizeChars, 64 * 1024)
    }

    func testRenderedTranscriptPageTextNeverExceedsMaxPayloadChars() {
        let document = YouTubeTranscriptDocument(
            videoID: "video1234567",
            input: "video1234567",
            title: String(repeating: "Very Long Title ", count: 10),
            language: "en",
            trackName: String(repeating: "English Track ", count: 6),
            totalSegmentCount: 2,
            transcript: "",
            segments: [
                YouTubeTranscriptSegment(startSeconds: 5, durationSeconds: 1, text: String(repeating: "A", count: 32)),
                YouTubeTranscriptSegment(startSeconds: 6, durationSeconds: 1, text: String(repeating: "B", count: 32)),
            ],
            message: ""
        )

        let text = YouTubeTranscriptService.renderVisibleTranscriptPageText(
            from: document,
            requestedPage: 1,
            maxPayloadChars: 120,
            preferredBodyChars: 70,
            reservedHeaderChars: 45
        )

        XCTAssertLessThanOrEqual(text.count, 120)
    }

    func testRenderedSegmentsPageTextNeverExceedsMaxPayloadChars() {
        let document = YouTubeTranscriptDocument(
            videoID: "video1234567",
            input: "video1234567",
            title: String(repeating: "Segmented Video ", count: 8),
            language: "zh-Hans",
            trackName: String(repeating: "Auto Caption ", count: 6),
            totalSegmentCount: 1,
            transcript: "",
            segments: [
                YouTubeTranscriptSegment(startSeconds: 12.34, durationSeconds: 5.67, text: String(repeating: "字幕", count: 30)),
            ],
            message: ""
        )

        let text = YouTubeTranscriptService.renderVisibleSegmentsPageText(
            from: document,
            requestedPage: 1,
            maxPayloadChars: 110,
            preferredBodyChars: 80,
            reservedHeaderChars: 40
        )

        XCTAssertLessThanOrEqual(text.count, 110)
    }
}
