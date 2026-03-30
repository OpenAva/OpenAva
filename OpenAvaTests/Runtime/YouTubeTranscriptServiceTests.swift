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
}
