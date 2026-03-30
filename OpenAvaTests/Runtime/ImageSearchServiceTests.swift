import XCTest
@testable import OpenAva

final class ImageSearchServiceTests: XCTestCase {
    func testNormalizeImageURLRemovesTrackingParams() {
        let raw = "https://images.example.com/photo.jpg?utm_source=test&width=1400&gclid=abc#fragment"

        let normalized = ImageSearchService.normalizeImageURLForTesting(raw)

        XCTAssertEqual(normalized, "https://images.example.com/photo.jpg?width=1400")
    }

    func testIsLikelyFreeLicenseRecognizesCreativeCommons() {
        XCTAssertTrue(ImageSearchService.isLikelyFreeLicenseForTesting("CC BY-SA 4.0"))
        XCTAssertTrue(ImageSearchService.isLikelyFreeLicenseForTesting("Public Domain"))
        XCTAssertFalse(ImageSearchService.isLikelyFreeLicenseForTesting("All Rights Reserved"))
    }

    func testMeetsQualityThresholdUsesLongAndShortEdges() {
        XCTAssertTrue(ImageSearchService.meetsQualityThresholdForTesting(width: 900, height: 1600, minWidth: 1024, minHeight: 720))
        XCTAssertFalse(ImageSearchService.meetsQualityThresholdForTesting(width: 700, height: 1200, minWidth: 1024, minHeight: 720))
    }
}
