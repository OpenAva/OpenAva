import XCTest
@testable import OpenAva

final class ImageSearchServiceTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

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

    func testSearchKeepsWikimediaResultsWhenExtMetadataContainsNumbers() async throws {
        let openverseJSON = #"{"results":[]}"#
        let wikimediaJSON = #"""
        {
          "query": {
            "pages": {
              "123": {
                "title": "File:Test cat photo.jpg",
                "imageinfo": [
                  {
                    "url": "https://upload.wikimedia.org/wikipedia/commons/7/72/Test_cat_photo.jpg",
                    "descriptionurl": "https://commons.wikimedia.org/wiki/File:Test_cat_photo.jpg",
                    "thumburl": "https://upload.wikimedia.org/wikipedia/commons/thumb/7/72/Test_cat_photo.jpg/720px-Test_cat_photo.jpg",
                    "width": 2400,
                    "height": 1600,
                    "extmetadata": {
                      "CommonsMetadataExtension": { "value": 1.2 },
                      "LicenseShortName": { "value": "CC BY-SA 4.0" },
                      "LicenseUrl": { "value": "https://creativecommons.org/licenses/by-sa/4.0" },
                      "Artist": { "value": "<span>Tester</span>" },
                      "AttributionRequired": { "value": true }
                    }
                  }
                ]
              }
            }
          }
        }
        """#

        MockURLProtocol.requestHandler = { request in
            let url = try XCTUnwrap(request.url)
            let response = try HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!

            switch url.host {
            case "api.openverse.org":
                return (response, Data(openverseJSON.utf8))
            case "commons.wikimedia.org":
                return (response, Data(wikimediaJSON.utf8))
            default:
                let unexpectedHost = url.host ?? "nil"
                XCTFail("Unexpected host: \(unexpectedHost)")
                return (response, Data("{}".utf8))
            }
        }

        let service = ImageSearchService(session: makeMockSession())
        let result = try await service.search(query: "cat", topK: 8, minWidth: 1024, minHeight: 720, orientation: "any", safeSearch: true)

        XCTAssertEqual(result.total, 1)
        XCTAssertEqual(result.results.first?.title, "File:Test cat photo.jpg")
        XCTAssertEqual(result.results.first?.license, "CC BY-SA 4.0")
        XCTAssertEqual(result.results.first?.creator, "Tester")
        XCTAssertEqual(result.results.first?.imageURL, "https://upload.wikimedia.org/wikipedia/commons/7/72/Test_cat_photo.jpg")
        XCTAssertTrue(result.sourceStatus.contains(where: { $0.source == "wikimedia" && $0.succeeded && $0.count == 1 }))
    }

    func testSearchKeepsOpenverseResultsWhenLicenseUsesShortCode() async throws {
        let openverseJSON = #"""
        {
          "results": [
            {
              "title": "Cat on sofa",
              "url": "https://images.example.com/cat-on-sofa.jpg",
              "thumbnail": "https://images.example.com/thumb-cat-on-sofa.jpg",
              "foreign_landing_url": "https://example.com/cat-on-sofa",
              "creator": "Jane Doe",
              "license": "by",
              "license_version": "4.0",
              "license_url": "https://creativecommons.org/licenses/by/4.0",
              "provider": "flickr",
              "source": "flickr",
              "width": 2400,
              "height": 1600,
              "tags": [
                { "name": "cat" },
                { "name": "sofa" }
              ],
              "mature": false
            }
          ]
        }
        """#
        let wikimediaJSON = #"{"query":{"pages":{}}}"#

        MockURLProtocol.requestHandler = { request in
            let url = try XCTUnwrap(request.url)
            let response = try HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!

            switch url.host {
            case "api.openverse.org":
                return (response, Data(openverseJSON.utf8))
            case "commons.wikimedia.org":
                return (response, Data(wikimediaJSON.utf8))
            default:
                let unexpectedHost = url.host ?? "nil"
                XCTFail("Unexpected host: \(unexpectedHost)")
                return (response, Data("{}".utf8))
            }
        }

        let service = ImageSearchService(session: makeMockSession())
        let result = try await service.search(query: "cat", topK: 8, minWidth: 1024, minHeight: 720, orientation: "any", safeSearch: true)

        XCTAssertEqual(result.total, 1)
        XCTAssertEqual(result.results.first?.title, "Cat on sofa")
        XCTAssertEqual(result.results.first?.license, "CC BY 4.0")
        XCTAssertEqual(result.results.first?.provider, "flickr")
        XCTAssertEqual(result.results.first?.creator, "Jane Doe")
        XCTAssertTrue(result.results.first?.requiresAttribution == true)
        XCTAssertTrue(result.sourceStatus.contains(where: { $0.source == "openverse" && $0.succeeded && $0.count == 1 }))
    }

    private func makeMockSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private final class MockURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        request.url != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: NSError(domain: "MockURLProtocol", code: 0))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
