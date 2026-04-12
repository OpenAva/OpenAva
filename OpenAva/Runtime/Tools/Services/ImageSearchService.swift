import Foundation
import OpenClawKit

enum ImageSearchServiceError: Error, LocalizedError {
    case invalidQuery

    var errorDescription: String? {
        switch self {
        case .invalidQuery:
            return "Search query is empty"
        }
    }
}

struct ImageSearchSourceStatus: Codable {
    let source: String
    let succeeded: Bool
    let count: Int
    let error: String?
}

struct ImageSearchItem: Codable {
    let title: String
    let imageURL: String
    let thumbnailURL: String?
    let sourcePageURL: String?
    let width: Int
    let height: Int
    let provider: String
    let license: String
    let licenseURL: String?
    let creator: String?
    let requiresAttribution: Bool
    let qualityScore: Double
}

struct ImageSearchResult: Codable {
    let query: String
    let total: Int
    let topK: Int
    let minWidth: Int
    let minHeight: Int
    let orientation: String
    let results: [ImageSearchItem]
    let sourceStatus: [ImageSearchSourceStatus]
    let message: String
}

actor ImageSearchService {
    private enum OrientationFilter: String {
        case any
        case landscape
        case portrait
        case square
    }

    private struct RawImageCandidate {
        let title: String
        let imageURL: String
        let thumbnailURL: String?
        let sourcePageURL: String?
        let width: Int
        let height: Int
        let provider: String
        let source: String
        let license: String
        let licenseURL: String?
        let creator: String?
        let requiresAttribution: Bool
        let tags: [String]
    }

    private struct SearchBatch {
        let source: String
        let items: [RawImageCandidate]
        let error: String?
    }

    private struct RankedImage {
        let title: String
        let imageURL: String
        let thumbnailURL: String?
        let sourcePageURL: String?
        let width: Int
        let height: Int
        let provider: String
        let source: String
        let license: String
        let licenseURL: String?
        let creator: String?
        let requiresAttribution: Bool
        let score: Double
    }

    private static let defaultTimeoutSeconds: TimeInterval = 15
    private static let defaultUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_7_2) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36"

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
        query: String,
        topK: Int = 8,
        minWidth: Int = 1024,
        minHeight: Int = 720,
        orientation: String = "any",
        safeSearch: Bool = true
    ) async throws -> ImageSearchResult {
        let normalizedQuery = Self.normalizeWhitespace(query)
        guard !normalizedQuery.isEmpty else {
            throw ImageSearchServiceError.invalidQuery
        }

        let resolvedTopK = max(1, min(topK, 20))
        let resolvedMinWidth = max(320, min(minWidth, 10000))
        let resolvedMinHeight = max(320, min(minHeight, 10000))
        let resolvedOrientation = OrientationFilter(rawValue: orientation.lowercased()) ?? .any
        let fetchLimit = max(24, resolvedTopK * 4)

        async let openverseBatch = searchOpenverse(
            query: normalizedQuery,
            limit: fetchLimit,
            minWidth: resolvedMinWidth,
            minHeight: resolvedMinHeight,
            orientation: resolvedOrientation,
            safeSearch: safeSearch
        )
        async let wikimediaBatch = searchWikimedia(
            query: normalizedQuery,
            limit: fetchLimit,
            minWidth: resolvedMinWidth,
            minHeight: resolvedMinHeight,
            orientation: resolvedOrientation
        )

        let batches = await[openverseBatch, wikimediaBatch]
        let sourceStatus = batches.map {
            ImageSearchSourceStatus(
                source: $0.source,
                succeeded: $0.error == nil,
                count: $0.items.count,
                error: $0.error
            )
        }

        var candidates: [RawImageCandidate] = []
        for batch in batches {
            candidates.append(contentsOf: batch.items)
        }

        let ranked = rankAndDeduplicate(
            candidates: candidates,
            query: normalizedQuery,
            minWidth: resolvedMinWidth,
            minHeight: resolvedMinHeight,
            orientation: resolvedOrientation
        )

        let finalItems = Array(ranked.prefix(resolvedTopK)).map {
            ImageSearchItem(
                title: $0.title,
                imageURL: $0.imageURL,
                thumbnailURL: $0.thumbnailURL,
                sourcePageURL: $0.sourcePageURL,
                width: $0.width,
                height: $0.height,
                provider: $0.provider,
                license: $0.license,
                licenseURL: $0.licenseURL,
                creator: $0.creator,
                requiresAttribution: $0.requiresAttribution,
                qualityScore: $0.score
            )
        }

        let message = "Found \(finalItems.count) free-to-use image(s) from \(sourceStatus.filter { $0.succeeded }.count)/\(sourceStatus.count) sources"
        return ImageSearchResult(
            query: normalizedQuery,
            total: finalItems.count,
            topK: resolvedTopK,
            minWidth: resolvedMinWidth,
            minHeight: resolvedMinHeight,
            orientation: resolvedOrientation.rawValue,
            results: finalItems,
            sourceStatus: sourceStatus,
            message: message
        )
    }

    private func searchOpenverse(
        query: String,
        limit: Int,
        minWidth: Int,
        minHeight: Int,
        orientation: OrientationFilter,
        safeSearch: Bool
    ) async -> SearchBatch {
        struct Response: Decodable {
            struct TagNode: Decodable {
                let name: String?
            }

            struct Item: Decodable {
                let title: String?
                let url: String?
                let thumbnail: String?
                let foreign_landing_url: String?
                let creator: String?
                let license: String?
                let license_version: String?
                let license_url: String?
                let provider: String?
                let source: String?
                let width: Int?
                let height: Int?
                let tags: [TagNode]?
                let mature: Bool?
            }

            let results: [Item]
        }

        var components = URLComponents(string: "https://api.openverse.org/v1/images/")
        components?.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "page_size", value: "\(max(10, min(limit, 80)))"),
            URLQueryItem(name: "license_type", value: "all"),
            URLQueryItem(name: "extension", value: "jpg,jpeg,png,webp"),
        ]

        guard let url = components?.url else {
            return SearchBatch(source: "openverse", items: [], error: "Invalid URL")
        }

        do {
            let decoded: Response = try await fetchDecodable(from: url)
            var items: [RawImageCandidate] = []

            for item in decoded.results {
                guard let rawURL = item.url,
                      let imageURL = Self.normalizeImageURL(rawURL),
                      let width = item.width,
                      let height = item.height
                else {
                    continue
                }

                if safeSearch, item.mature == true {
                    continue
                }

                guard Self.meetsQualityThreshold(width: width, height: height, minWidth: minWidth, minHeight: minHeight) else {
                    continue
                }

                guard Self.matchesOrientation(width: width, height: height, orientation: orientation) else {
                    continue
                }

                let licenseName = Self.composeLicenseName(license: item.license, version: item.license_version)
                guard Self.isLikelyFreeLicense(licenseName) else {
                    continue
                }

                let tags = (item.tags ?? []).compactMap { Self.normalizeWhitespace($0.name ?? "") }
                let provider = Self.normalizeWhitespace(item.provider ?? item.source ?? "openverse")
                let creator = Self.optionalText(item.creator)
                let title = Self.fallbackTitle(primary: item.title, url: imageURL)
                let requiresAttribution = Self.requiresAttribution(license: licenseName, explicitValue: nil)

                items.append(RawImageCandidate(
                    title: title,
                    imageURL: imageURL,
                    thumbnailURL: Self.normalizeImageURL(item.thumbnail),
                    sourcePageURL: Self.normalizeImageURL(item.foreign_landing_url),
                    width: width,
                    height: height,
                    provider: provider,
                    source: "openverse",
                    license: licenseName,
                    licenseURL: Self.normalizeImageURL(item.license_url),
                    creator: creator,
                    requiresAttribution: requiresAttribution,
                    tags: tags
                ))
            }

            return SearchBatch(source: "openverse", items: items, error: nil)
        } catch {
            return SearchBatch(source: "openverse", items: [], error: error.localizedDescription)
        }
    }

    private func searchWikimedia(
        query: String,
        limit: Int,
        minWidth: Int,
        minHeight: Int,
        orientation: OrientationFilter
    ) async -> SearchBatch {
        struct Response: Decodable {
            struct QueryNode: Decodable {
                struct Page: Decodable {
                    struct ImageInfo: Decodable {
                        struct MetaValue: Decodable {
                            let value: String?

                            private enum CodingKeys: String, CodingKey {
                                case value
                            }

                            init(from decoder: Decoder) throws {
                                let container = try decoder.container(keyedBy: CodingKeys.self)
                                if try container.decodeNil(forKey: .value) {
                                    value = nil
                                } else if let string = try? container.decode(String.self, forKey: .value) {
                                    value = string
                                } else if let int = try? container.decode(Int.self, forKey: .value) {
                                    value = String(int)
                                } else if let double = try? container.decode(Double.self, forKey: .value) {
                                    value = String(double)
                                } else if let bool = try? container.decode(Bool.self, forKey: .value) {
                                    value = bool ? "true" : "false"
                                } else {
                                    value = nil
                                }
                            }
                        }

                        let url: String?
                        let descriptionurl: String?
                        let thumburl: String?
                        let width: Int?
                        let height: Int?
                        let extmetadata: [String: MetaValue]?
                    }

                    let title: String?
                    let imageinfo: [ImageInfo]?
                }

                let pages: [String: Page]
            }

            let query: QueryNode?
        }

        var components = URLComponents(string: "https://commons.wikimedia.org/w/api.php")
        components?.queryItems = [
            URLQueryItem(name: "action", value: "query"),
            URLQueryItem(name: "generator", value: "search"),
            URLQueryItem(name: "gsrsearch", value: query),
            URLQueryItem(name: "gsrnamespace", value: "6"),
            URLQueryItem(name: "gsrlimit", value: "\(max(10, min(limit, 50)))"),
            URLQueryItem(name: "prop", value: "imageinfo"),
            URLQueryItem(name: "iiprop", value: "url|size|extmetadata"),
            URLQueryItem(name: "iiurlwidth", value: "720"),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "origin", value: "*"),
        ]

        guard let url = components?.url else {
            return SearchBatch(source: "wikimedia", items: [], error: "Invalid URL")
        }

        do {
            let decoded: Response = try await fetchDecodable(from: url)
            let pages = decoded.query.map { Array($0.pages.values) } ?? []
            var items: [RawImageCandidate] = []

            for page in pages {
                guard let imageInfo = page.imageinfo?.first,
                      let rawURL = imageInfo.url,
                      let imageURL = Self.normalizeImageURL(rawURL),
                      let width = imageInfo.width,
                      let height = imageInfo.height
                else {
                    continue
                }

                guard Self.meetsQualityThreshold(width: width, height: height, minWidth: minWidth, minHeight: minHeight) else {
                    continue
                }

                guard Self.matchesOrientation(width: width, height: height, orientation: orientation) else {
                    continue
                }

                let metadata = imageInfo.extmetadata ?? [:]
                let license = Self.optionalMetaValue(metadata["LicenseShortName"]?.value)
                    ?? Self.optionalMetaValue(metadata["UsageTerms"]?.value)
                    ?? "Wikimedia Commons"
                guard Self.isLikelyFreeLicense(license) else {
                    continue
                }

                let title = Self.fallbackTitle(primary: page.title, url: imageURL)
                let creator = Self.optionalMetaValue(metadata["Artist"]?.value)
                let licenseURL = Self.normalizeImageURL(metadata["LicenseUrl"]?.value)
                let attributionValue = Self.optionalMetaValue(metadata["AttributionRequired"]?.value)
                let requiresAttribution = Self.requiresAttribution(license: license, explicitValue: attributionValue)

                items.append(RawImageCandidate(
                    title: title,
                    imageURL: imageURL,
                    thumbnailURL: Self.normalizeImageURL(imageInfo.thumburl),
                    sourcePageURL: Self.normalizeImageURL(imageInfo.descriptionurl),
                    width: width,
                    height: height,
                    provider: "wikimedia",
                    source: "wikimedia",
                    license: license,
                    licenseURL: licenseURL,
                    creator: creator,
                    requiresAttribution: requiresAttribution,
                    tags: []
                ))
            }

            return SearchBatch(source: "wikimedia", items: items, error: nil)
        } catch {
            return SearchBatch(source: "wikimedia", items: [], error: error.localizedDescription)
        }
    }

    private func rankAndDeduplicate(
        candidates: [RawImageCandidate],
        query: String,
        minWidth: Int,
        minHeight: Int,
        orientation: OrientationFilter
    ) -> [RankedImage] {
        let queryTokens = Set(Self.tokenize(query))
        var merged: [String: RankedImage] = [:]

        for candidate in candidates {
            let key = Self.dedupKey(url: candidate.imageURL)
            let score = Self.score(
                candidate: candidate,
                queryTokens: queryTokens,
                minWidth: minWidth,
                minHeight: minHeight,
                orientation: orientation
            )

            let ranked = RankedImage(
                title: candidate.title,
                imageURL: candidate.imageURL,
                thumbnailURL: candidate.thumbnailURL,
                sourcePageURL: candidate.sourcePageURL,
                width: candidate.width,
                height: candidate.height,
                provider: candidate.provider,
                source: candidate.source,
                license: candidate.license,
                licenseURL: candidate.licenseURL,
                creator: candidate.creator,
                requiresAttribution: candidate.requiresAttribution,
                score: score
            )

            if let existing = merged[key] {
                if ranked.score > existing.score {
                    merged[key] = ranked
                }
            } else {
                merged[key] = ranked
            }
        }

        return merged.values.sorted {
            if abs($0.score - $1.score) < 0.001 {
                return $0.title < $1.title
            }
            return $0.score > $1.score
        }
    }

    private func fetchDecodable<T: Decodable>(from url: URL) async throws -> T {
        guard let host = url.host, !LoopbackHost.isLocalNetworkHost(host) else {
            throw WebFetchService.WebFetchError.privateNetworkBlocked
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = Self.defaultTimeoutSeconds
        request.setValue("application/json,text/plain;q=0.9,*/*;q=0.5", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue(Self.defaultUserAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200 ... 299).contains(httpResponse.statusCode)
        else {
            throw WebFetchService.WebFetchError.invalidResponse
        }

        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Score images by quality, query relevance, and license usability.
    private static func score(
        candidate: RawImageCandidate,
        queryTokens: Set<String>,
        minWidth: Int,
        minHeight: Int,
        orientation: OrientationFilter
    ) -> Double {
        let area = Double(candidate.width * candidate.height)
        let areaFloor = Double(minWidth * minHeight)
        let resolutionScore = min(60.0, area / max(1.0, areaFloor) * 22.0)

        let longEdge = Double(max(candidate.width, candidate.height))
        let shortEdge = Double(min(candidate.width, candidate.height))
        let edgeScore = min(24.0, (longEdge / 220.0) + (shortEdge / 320.0))

        let sourceScore: Double = candidate.source == "openverse" ? 12.0 : 11.0
        let attributionPenalty: Double = candidate.requiresAttribution ? -1.0 : 2.5

        let textCorpus = (candidate.title + " " + candidate.tags.joined(separator: " ")).lowercased()
        let matchCount = queryTokens.filter { textCorpus.contains($0) }.count
        let relevanceScore = min(14.0, Double(matchCount) * 4.0)

        let orientationBonus: Double
        switch orientation {
        case .any:
            orientationBonus = 0
        case .landscape, .portrait, .square:
            orientationBonus = 1.8
        }

        return resolutionScore + edgeScore + sourceScore + attributionPenalty + relevanceScore + orientationBonus
    }

    private static func dedupKey(url: String) -> String {
        normalizeImageURL(url)?.lowercased() ?? url.lowercased()
    }

    private static func normalizeImageURL(_ raw: String?) -> String? {
        guard let raw else { return nil }
        guard let parsed = URL(string: raw),
              let scheme = parsed.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = parsed.host,
              !LoopbackHost.isLocalNetworkHost(host)
        else {
            return nil
        }

        guard var components = URLComponents(url: parsed, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.fragment = nil
        if let queryItems = components.queryItems {
            let filtered = queryItems.filter { item in
                let key = item.name.lowercased()
                return !(key.hasPrefix("utm_") || key == "fbclid" || key == "gclid")
            }
            components.queryItems = filtered.isEmpty ? nil : filtered
        }
        return components.url?.absoluteString
    }

    private static func meetsQualityThreshold(width: Int, height: Int, minWidth: Int, minHeight: Int) -> Bool {
        guard width > 0, height > 0 else {
            return false
        }

        let requiredLongEdge = max(minWidth, minHeight)
        let requiredShortEdge = min(minWidth, minHeight)
        let longEdge = max(width, height)
        let shortEdge = min(width, height)
        return longEdge >= requiredLongEdge && shortEdge >= requiredShortEdge
    }

    private static func matchesOrientation(width: Int, height: Int, orientation: OrientationFilter) -> Bool {
        switch orientation {
        case .any:
            return true
        case .landscape:
            return width >= height
        case .portrait:
            return height >= width
        case .square:
            let maxSide = max(width, height)
            guard maxSide > 0 else { return false }
            return abs(width - height) * 100 <= maxSide * 12
        }
    }

    private static func composeLicenseName(license: String?, version: String?) -> String {
        let base = normalizeWhitespace(license ?? "")
        let normalizedBase = normalizedLicenseDisplayName(base)
        let versionText = normalizeWhitespace(version ?? "")
        if versionText.isEmpty {
            return normalizedBase
        }
        return "\(normalizedBase) \(versionText)"
    }

    private static func normalizedLicenseDisplayName(_ base: String) -> String {
        let normalized = normalizeWhitespace(base)
        guard !normalized.isEmpty else {
            return "unknown"
        }

        switch normalized.lowercased() {
        case "by":
            return "CC BY"
        case "by-sa":
            return "CC BY-SA"
        case "cc0":
            return "CC0"
        case "pdm", "public domain", "publicdomain":
            return "Public Domain"
        default:
            return normalized.uppercased()
        }
    }

    private static func requiresAttribution(license: String, explicitValue: String?) -> Bool {
        let normalizedExplicit = normalizeWhitespace(explicitValue ?? "").lowercased()
        if ["true", "yes", "required", "1"].contains(normalizedExplicit) {
            return true
        }
        if ["false", "no", "0"].contains(normalizedExplicit) {
            return false
        }

        let normalizedLicense = license.lowercased()
        if normalizedLicense.contains("cc0") || normalizedLicense.contains("public domain") {
            return false
        }
        return true
    }

    private static func isLikelyFreeLicense(_ license: String) -> Bool {
        let normalized = normalizeWhitespace(stripTags(license)).lowercased()
        if normalized.isEmpty || normalized == "unknown" {
            return false
        }

        if normalized.contains("all rights reserved") {
            return false
        }

        let allowList = [
            "creative commons", "cc0", "cc by", "cc-by", "cc by-sa", "cc-by-sa", "public domain",
            "pdm", "gfdl", "free art license", "unsplash license",
        ]
        return allowList.contains { normalized.contains($0) }
    }

    private static func fallbackTitle(primary: String?, url: String) -> String {
        let text = normalizeWhitespace(stripTags(primary ?? ""))
        if !text.isEmpty {
            return text
        }
        let lastPath = URL(string: url)?.lastPathComponent ?? "image"
        return normalizeWhitespace(lastPath.replacingOccurrences(of: "_", with: " "))
    }

    private static func optionalText(_ value: String?) -> String? {
        let cleaned = normalizeWhitespace(stripTags(value ?? ""))
        return cleaned.isEmpty ? nil : cleaned
    }

    private static func optionalMetaValue(_ value: String?) -> String? {
        optionalText(decodeHTMLEntities(value ?? ""))
    }

    private static func tokenize(_ query: String) -> [String] {
        let parts = query.lowercased().split(whereSeparator: { $0.isWhitespace || $0.isPunctuation })
        return parts.map(String.init).filter { $0.count >= 2 }
    }

    private static func stripTags(_ value: String) -> String {
        value.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
    }

    private static func decodeHTMLEntities(_ value: String) -> String {
        var text = value
        text = text.replacingOccurrences(of: "&nbsp;", with: " ", options: .caseInsensitive)
        text = text.replacingOccurrences(of: "&amp;", with: "&", options: .caseInsensitive)
        text = text.replacingOccurrences(of: "&quot;", with: "\"", options: .caseInsensitive)
        text = text.replacingOccurrences(of: "&#39;", with: "'", options: .caseInsensitive)
        text = text.replacingOccurrences(of: "&lt;", with: "<", options: .caseInsensitive)
        text = text.replacingOccurrences(of: "&gt;", with: ">", options: .caseInsensitive)
        return text
    }

    private static func normalizeWhitespace(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "[ \t]{2,}", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\n{2,}", with: "\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Exposed for deterministic unit tests.
    static func normalizeImageURLForTesting(_ raw: String) -> String? {
        normalizeImageURL(raw)
    }

    /// Exposed for deterministic unit tests.
    static func isLikelyFreeLicenseForTesting(_ license: String) -> Bool {
        isLikelyFreeLicense(license)
    }

    /// Exposed for deterministic unit tests.
    static func meetsQualityThresholdForTesting(width: Int, height: Int, minWidth: Int, minHeight: Int) -> Bool {
        meetsQualityThreshold(width: width, height: height, minWidth: minWidth, minHeight: minHeight)
    }
}
