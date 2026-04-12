import Foundation
import OpenClawKit
import XCTest
@testable import OpenAva

@MainActor
final class ArxivSearchServiceTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testParseIdentifierPreservesBaseAndVersionedIDs() {
        let newFormat = ArxivSearchService.parseIdentifierForTesting("http://arxiv.org/abs/2402.03300v7")
        XCTAssertEqual(newFormat.0, "2402.03300")
        XCTAssertEqual(newFormat.1, "2402.03300v7")

        let oldFormat = ArxivSearchService.parseIdentifierForTesting("http://arxiv.org/abs/hep-th/0601001v2")
        XCTAssertEqual(oldFormat.0, "hep-th/0601001")
        XCTAssertEqual(oldFormat.1, "hep-th/0601001v2")
    }

    func testSearchParsesFeedAndBuildsVersionedLinks() async throws {
        let xml = #"""
        <?xml version="1.0" encoding="UTF-8"?>
        <feed xmlns="http://www.w3.org/2005/Atom"
              xmlns:opensearch="http://a9.com/-/spec/opensearch/1.1/"
              xmlns:arxiv="http://arxiv.org/schemas/atom">
          <title>arXiv Query Results</title>
          <opensearch:totalResults>2</opensearch:totalResults>
          <entry>
            <id>http://arxiv.org/abs/2402.03300v7</id>
            <updated>2024-03-10T12:00:00Z</updated>
            <published>2024-02-05T10:00:00Z</published>
            <title>
              Test Paper One
            </title>
            <summary>
              A concise abstract about reinforcement learning.
            </summary>
            <author><name>Alice Smith</name></author>
            <author><name>Bob Lee</name></author>
            <category term="cs.AI"/>
            <category term="cs.LG"/>
            <arxiv:primary_category term="cs.LG"/>
          </entry>
          <entry>
            <id>http://arxiv.org/abs/hep-th/0601001v2</id>
            <updated>2006-02-01T08:00:00Z</updated>
            <published>2006-01-10T08:00:00Z</published>
            <title>Old Format Paper</title>
            <summary>This paper has been withdrawn by the authors.</summary>
            <author><name>Jane Doe</name></author>
            <category term="hep-th"/>
          </entry>
        </feed>
        """#

        MockURLProtocol.requestHandler = { request in
            let components = try XCTUnwrap(try URLComponents(url: XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
            let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "OpenAva/1.0")
            XCTAssertEqual(components.host, "export.arxiv.org")
            XCTAssertEqual(components.path, "/api/query")
            XCTAssertEqual(items["max_results"], "2")
            XCTAssertEqual(items["sortBy"], "submittedDate")
            XCTAssertEqual(items["search_query"], "all:transformer attention AND au:Yann LeCun AND cat:cs.AI")

            let response = try HTTPURLResponse(
                url: XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/atom+xml"]
            )!
            return (response, Data(xml.utf8))
        }

        let service = ArxivSearchService(session: makeMockSession())
        let result = try await service.search(
            query: "transformer attention",
            author: "Yann LeCun",
            category: "cs.AI",
            ids: nil,
            maxResults: 2,
            sort: "submittedDate"
        )

        XCTAssertEqual(result.totalResults, 2)
        XCTAssertEqual(result.returnedResults, 2)
        XCTAssertEqual(result.querySummary.sort, "submittedDate")
        XCTAssertEqual(result.entries.count, 2)

        let first = result.entries[0]
        XCTAssertEqual(first.id, "2402.03300")
        XCTAssertEqual(first.versionedID, "2402.03300v7")
        XCTAssertEqual(first.title, "Test Paper One")
        XCTAssertEqual(first.authors, ["Alice Smith", "Bob Lee"])
        XCTAssertEqual(first.published, "2024-02-05")
        XCTAssertEqual(first.updated, "2024-03-10")
        XCTAssertEqual(first.primaryCategory, "cs.LG")
        XCTAssertEqual(first.categories, ["cs.AI", "cs.LG"])
        XCTAssertEqual(first.absURL, "https://arxiv.org/abs/2402.03300v7")
        XCTAssertEqual(first.basePDFURL, "https://arxiv.org/pdf/2402.03300")
        XCTAssertFalse(first.isWithdrawn)

        let second = result.entries[1]
        XCTAssertEqual(second.id, "hep-th/0601001")
        XCTAssertEqual(second.versionedID, "hep-th/0601001v2")
        XCTAssertTrue(second.isWithdrawn)
    }

    func testSearchByIDsBuildsIDListQueryWithoutSearchQuery() async throws {
        let xml = #"""
        <?xml version="1.0" encoding="UTF-8"?>
        <feed xmlns="http://www.w3.org/2005/Atom"
              xmlns:opensearch="http://a9.com/-/spec/opensearch/1.1/">
          <opensearch:totalResults>0</opensearch:totalResults>
        </feed>
        """#

        MockURLProtocol.requestHandler = { request in
            let components = try XCTUnwrap(try URLComponents(url: XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
            let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            XCTAssertEqual(items["id_list"], "2402.03300v2,hep-th/0601001")
            XCTAssertNil(items["search_query"])

            let response = try HTTPURLResponse(url: XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(xml.utf8))
        }

        let service = ArxivSearchService(session: makeMockSession())
        let result = try await service.search(
            query: "ignored",
            author: "ignored",
            category: "ignored",
            ids: ["2402.03300v2", "hep-th/0601001"],
            maxResults: 5,
            sort: "relevance"
        )

        XCTAssertEqual(result.totalResults, 0)
        XCTAssertEqual(result.entries, [])
        XCTAssertEqual(result.querySummary.ids, ["2402.03300v2", "hep-th/0601001"])
        XCTAssertNil(result.querySummary.query)
    }

    func testToolHandlerReturnsJSONPayload() async throws {
        let xml = #"""
        <?xml version="1.0" encoding="UTF-8"?>
        <feed xmlns="http://www.w3.org/2005/Atom"
              xmlns:opensearch="http://a9.com/-/spec/opensearch/1.1/">
          <opensearch:totalResults>1</opensearch:totalResults>
          <entry>
            <id>http://arxiv.org/abs/2402.03300v1</id>
            <updated>2024-02-06T12:00:00Z</updated>
            <published>2024-02-05T10:00:00Z</published>
            <title>Handler Test Paper</title>
            <summary>Abstract text.</summary>
            <author><name>Alice Smith</name></author>
            <category term="cs.AI"/>
          </entry>
        </feed>
        """#

        MockURLProtocol.requestHandler = { request in
            let response = try HTTPURLResponse(url: XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(xml.utf8))
        }

        let service = ArxivSearchService(session: makeMockSession())
        var handlers: [String: ToolHandler] = [:]
        await service.registerHandlers(into: &handlers)

        guard let handler = handlers["research.arxiv_search"] else {
            XCTFail("Expected research.arxiv_search handler")
            return
        }

        let response = try await handler(
            BridgeInvokeRequest(
                id: UUID().uuidString,
                command: "research.arxiv_search",
                paramsJSON: #"{"query":"GRPO","maxResults":1}"#
            )
        )

        XCTAssertTrue(response.ok)
        let data = try XCTUnwrap(response.payload?.data(using: String.Encoding.utf8))
        let decoded = try JSONDecoder().decode(ArxivSearchResult.self, from: data)
        XCTAssertEqual(decoded.returnedResults, 1)
        XCTAssertEqual(decoded.entries.first?.title, "Handler Test Paper")
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
