import Foundation

enum ArxivSearchServiceError: Error, LocalizedError {
    case invalidRequest(String)
    case invalidResponse
    case parseFailed

    var errorDescription: String? {
        switch self {
        case let .invalidRequest(message):
            return "Invalid request: \(message)"
        case .invalidResponse:
            return "Invalid response from arXiv"
        case .parseFailed:
            return "Failed to parse arXiv feed"
        }
    }
}

struct ArxivSearchQuerySummary: Codable, Equatable {
    let query: String?
    let author: String?
    let category: String?
    let ids: [String]?
    let sort: String
}

struct ArxivPaperEntry: Codable, Equatable {
    let id: String
    let versionedID: String
    let title: String
    let authors: [String]
    let published: String
    let updated: String
    let categories: [String]
    let primaryCategory: String?
    let abstract: String
    let absURL: String
    let pdfURL: String
    let baseAbsURL: String
    let basePDFURL: String
    let isWithdrawn: Bool
}

struct ArxivSearchResult: Codable, Equatable {
    let totalResults: Int
    let returnedResults: Int
    let querySummary: ArxivSearchQuerySummary
    let entries: [ArxivPaperEntry]
    let message: String
}

actor ArxivSearchService {
    fileprivate struct RawFeedEntry {
        let rawID: String
        let title: String
        let authors: [String]
        let published: String
        let updated: String
        let summary: String
        let categories: [String]
        let primaryCategory: String?
    }

    fileprivate struct ParsedFeed {
        let totalResults: Int
        let entries: [RawFeedEntry]
    }

    private static let defaultTimeoutSeconds: TimeInterval = 15
    private static let endpoint = URL(string: "https://export.arxiv.org/api/query")!
    private static let userAgent = "OpenAva/1.0"

    private let session: URLSession

    init(timeoutSeconds: TimeInterval = defaultTimeoutSeconds) {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = timeoutSeconds
        config.timeoutIntervalForResource = timeoutSeconds
        session = URLSession(configuration: config)
    }

    init(session: URLSession) {
        self.session = session
    }

    func search(
        query: String?,
        author: String?,
        category: String?,
        ids: [String]?,
        maxResults: Int = 5,
        sort: String = "relevance"
    ) async throws -> ArxivSearchResult {
        let normalizedQuery = Self.normalizeWhitespace(query)
        let normalizedAuthor = Self.normalizeWhitespace(author)
        let normalizedCategory = Self.normalizeWhitespace(category)
        let normalizedIDs = Self.normalizeIDs(ids)
        let resolvedSort = try Self.resolveSort(sort)
        let resolvedMaxResults = max(1, min(maxResults, 20))

        guard normalizedIDs != nil || normalizedQuery != nil || normalizedAuthor != nil || normalizedCategory != nil else {
            throw ArxivSearchServiceError.invalidRequest("at least one of query, author, category, or ids is required")
        }

        let url = try Self.buildURL(
            query: normalizedQuery,
            author: normalizedAuthor,
            category: normalizedCategory,
            ids: normalizedIDs,
            maxResults: resolvedMaxResults,
            sort: resolvedSort
        )
        let data = try await fetchData(from: url)
        let parsedFeed = try Self.parseFeed(from: data)
        let entries = parsedFeed.entries.map(Self.makePaperEntry(from:))
        let querySummary = ArxivSearchQuerySummary(
            query: normalizedIDs == nil ? normalizedQuery : nil,
            author: normalizedIDs == nil ? normalizedAuthor : nil,
            category: normalizedIDs == nil ? normalizedCategory : nil,
            ids: normalizedIDs,
            sort: resolvedSort
        )
        let message = parsedFeed.totalResults == 0
            ? "No arXiv results found."
            : "Found \(parsedFeed.totalResults) arXiv result(s), returning \(entries.count)."

        return ArxivSearchResult(
            totalResults: parsedFeed.totalResults,
            returnedResults: entries.count,
            querySummary: querySummary,
            entries: entries,
            message: message
        )
    }

    private func fetchData(from url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/atom+xml, application/xml;q=0.9, text/xml;q=0.8", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200 ... 299).contains(http.statusCode) else {
            throw ArxivSearchServiceError.invalidResponse
        }
        return data
    }

    private static func buildURL(
        query: String?,
        author: String?,
        category: String?,
        ids: [String]?,
        maxResults: Int,
        sort: String
    ) throws -> URL {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)

        if let ids, !ids.isEmpty {
            components?.queryItems = [
                URLQueryItem(name: "id_list", value: ids.joined(separator: ",")),
                URLQueryItem(name: "max_results", value: String(maxResults)),
                URLQueryItem(name: "sortBy", value: sort),
                URLQueryItem(name: "sortOrder", value: "descending"),
            ]
        } else {
            var parts: [String] = []
            if let query {
                parts.append("all:\(query)")
            }
            if let author {
                parts.append("au:\(author)")
            }
            if let category {
                parts.append("cat:\(category)")
            }
            guard !parts.isEmpty else {
                throw ArxivSearchServiceError.invalidRequest("search_query is empty")
            }

            components?.queryItems = [
                URLQueryItem(name: "search_query", value: parts.joined(separator: " AND ")),
                URLQueryItem(name: "max_results", value: String(maxResults)),
                URLQueryItem(name: "sortBy", value: sort),
                URLQueryItem(name: "sortOrder", value: "descending"),
            ]
        }

        guard let url = components?.url else {
            throw ArxivSearchServiceError.invalidRequest("failed to build arXiv query URL")
        }
        return url
    }

    private static func makePaperEntry(from raw: RawFeedEntry) -> ArxivPaperEntry {
        let (baseID, versionedID) = parseIdentifier(raw.rawID)
        let normalizedSummary = normalizeWhitespace(raw.summary) ?? ""
        let normalizedCategories = Array(NSOrderedSet(array: raw.categories.compactMap(normalizeWhitespace))) as? [String] ?? []
        let absURL = "https://arxiv.org/abs/\(versionedID)"
        let pdfURL = "https://arxiv.org/pdf/\(versionedID)"
        let baseAbsURL = "https://arxiv.org/abs/\(baseID)"
        let basePDFURL = "https://arxiv.org/pdf/\(baseID)"
        let loweredSummary = normalizedSummary.lowercased()

        return ArxivPaperEntry(
            id: baseID,
            versionedID: versionedID,
            title: normalizeWhitespace(raw.title) ?? raw.title,
            authors: raw.authors.compactMap(normalizeWhitespace),
            published: raw.published,
            updated: raw.updated,
            categories: normalizedCategories,
            primaryCategory: normalizeWhitespace(raw.primaryCategory),
            abstract: normalizedSummary,
            absURL: absURL,
            pdfURL: pdfURL,
            baseAbsURL: baseAbsURL,
            basePDFURL: basePDFURL,
            isWithdrawn: loweredSummary.contains("withdrawn") || loweredSummary.contains("retracted")
        )
    }

    private static func resolveSort(_ raw: String) throws -> String {
        switch normalizeWhitespace(raw)?.lowercased() {
        case nil, "relevance":
            return "relevance"
        case "submitteddate", "date":
            return "submittedDate"
        case "lastupdateddate", "updated":
            return "lastUpdatedDate"
        default:
            throw ArxivSearchServiceError.invalidRequest("sort must be one of relevance, submittedDate, or lastUpdatedDate")
        }
    }

    fileprivate static func normalizeWhitespace(_ value: String?) -> String? {
        guard let value else { return nil }
        let collapsed = value
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return collapsed.isEmpty ? nil : collapsed
    }

    private static func normalizeIDs(_ ids: [String]?) -> [String]? {
        let cleaned = (ids ?? []).compactMap { normalizeWhitespace($0) }
        return cleaned.isEmpty ? nil : cleaned
    }

    fileprivate static func parseFeed(from data: Data) throws -> ParsedFeed {
        let parserDelegate = ArxivAtomFeedParser()
        let parser = XMLParser(data: data)
        parser.delegate = parserDelegate
        guard parser.parse() else {
            throw ArxivSearchServiceError.parseFailed
        }
        return parserDelegate.makeParsedFeed()
    }

    nonisolated static func parseIdentifier(_ raw: String) -> (String, String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let identifier: String
        if let range = trimmed.range(of: "/abs/") {
            identifier = String(trimmed[range.upperBound...])
        } else {
            identifier = trimmed
        }

        guard let versionRange = identifier.range(of: #"v\d+$"#, options: .regularExpression) else {
            return (identifier, identifier)
        }
        return (String(identifier[..<versionRange.lowerBound]), identifier)
    }

    nonisolated static func parseIdentifierForTesting(_ raw: String) -> (String, String) {
        parseIdentifier(raw)
    }
}

private final class ArxivAtomFeedParser: NSObject, XMLParserDelegate {
    private struct EntryBuilder {
        var rawID = ""
        var title = ""
        var authors: [String] = []
        var published = ""
        var updated = ""
        var summary = ""
        var categories: [String] = []
        var primaryCategory: String?

        func build() -> ArxivSearchService.RawFeedEntry {
            ArxivSearchService.RawFeedEntry(
                rawID: rawID,
                title: title,
                authors: authors,
                published: published,
                updated: updated,
                summary: summary,
                categories: categories,
                primaryCategory: primaryCategory
            )
        }
    }

    private var totalResults = 0
    private var entries: [ArxivSearchService.RawFeedEntry] = []
    private var currentEntry: EntryBuilder?
    private var currentText = ""
    private var insideAuthor = false

    func parser(
        _: XMLParser,
        didStartElement elementName: String,
        namespaceURI _: String?,
        qualifiedName _: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        currentText = ""
        switch Self.localName(from: elementName) {
        case "entry":
            currentEntry = EntryBuilder()
        case "author":
            insideAuthor = true
        case "category":
            if let term = ArxivSearchService.normalizeWhitespace(attributeDict["term"]), currentEntry != nil {
                currentEntry?.categories.append(term)
            }
        case "primary_category":
            if let term = ArxivSearchService.normalizeWhitespace(attributeDict["term"]), currentEntry != nil {
                currentEntry?.primaryCategory = term
            }
        default:
            break
        }
    }

    func parser(_: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(
        _: XMLParser,
        didEndElement elementName: String,
        namespaceURI _: String?,
        qualifiedName _: String?
    ) {
        let name = Self.localName(from: elementName)
        let normalizedText = ArxivSearchService.normalizeWhitespace(currentText) ?? ""

        switch name {
        case "totalresults":
            totalResults = Int(normalizedText) ?? 0
        case "title":
            if currentEntry != nil {
                currentEntry?.title = normalizedText
            }
        case "id":
            if currentEntry != nil {
                currentEntry?.rawID = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        case "published":
            if currentEntry != nil {
                currentEntry?.published = String(normalizedText.prefix(10))
            }
        case "updated":
            if currentEntry != nil {
                currentEntry?.updated = String(normalizedText.prefix(10))
            }
        case "summary":
            if currentEntry != nil {
                currentEntry?.summary = normalizedText
            }
        case "name":
            if insideAuthor, currentEntry != nil, !normalizedText.isEmpty {
                currentEntry?.authors.append(normalizedText)
            }
        case "author":
            insideAuthor = false
        case "entry":
            if let currentEntry {
                entries.append(currentEntry.build())
            }
            self.currentEntry = nil
        default:
            break
        }

        currentText = ""
    }

    func makeParsedFeed() -> ArxivSearchService.ParsedFeed {
        ArxivSearchService.ParsedFeed(totalResults: totalResults, entries: entries)
    }

    private static func localName(from elementName: String) -> String {
        elementName.split(separator: ":").last?.lowercased() ?? elementName.lowercased()
    }
}
