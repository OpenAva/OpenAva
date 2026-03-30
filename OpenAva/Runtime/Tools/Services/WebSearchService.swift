import Foundation
import OpenClawKit

enum WebSearchServiceError: Error, LocalizedError {
    case invalidQuery

    var errorDescription: String? {
        switch self {
        case .invalidQuery:
            return "Search query is empty"
        }
    }
}

struct WebSearchSourceStatus: Codable {
    let source: String
    let succeeded: Bool
    let count: Int
    let error: String?
}

struct WebSearchItem: Codable {
    let title: String
    let link: String
    let summary: String
    let domain: String
    let rank: Int
    let source: String
    let sources: [String]
}

struct WebSearchResult: Codable {
    let query: String
    let total: Int
    let topK: Int
    let fetchTopK: Int
    let results: [WebSearchItem]
    let sourceStatus: [WebSearchSourceStatus]
    let message: String
}

actor WebSearchService {
    private struct RawSearchItem {
        let title: String
        let link: String
        let summary: String
        let source: String
        let sourceRank: Int
    }

    private struct SearchBatch {
        let source: String
        let items: [RawSearchItem]
        let error: String?
    }

    private struct RankedItem {
        var title: String
        var link: String
        var summary: String
        var domain: String
        var score: Double
        var bestSource: String
        var sources: Set<String>
    }

    private static let defaultTimeoutSeconds: TimeInterval = 12
    private static let defaultUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_7_2) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36"

    private let session: URLSession
    private let webFetchService: WebFetchService

    init(webFetchService: WebFetchService = WebFetchService(), timeoutSeconds: TimeInterval = defaultTimeoutSeconds) {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = timeoutSeconds
        config.timeoutIntervalForResource = timeoutSeconds
        session = URLSession(configuration: config)
        self.webFetchService = webFetchService
    }

    func search(
        query: String,
        topK: Int = 8,
        fetchTopK: Int = 3,
        lang: String = "zh-CN",
        safeSearch: String = "moderate"
    ) async throws -> WebSearchResult {
        let normalizedQuery = Self.normalizeWhitespace(query)
        guard !normalizedQuery.isEmpty else {
            throw WebSearchServiceError.invalidQuery
        }

        let resolvedTopK = max(1, min(topK, 20))
        let resolvedFetchTopK = max(0, min(fetchTopK, resolvedTopK))

        // Aggregate both global and CN-oriented search providers for broader recall.
        async let baiduBatch = searchBaidu(query: normalizedQuery)
        async let bingCNBatch = searchBingCN(query: normalizedQuery)
        async let bingINTBatch = searchBingINT(query: normalizedQuery)
        async let so360Batch = searchSo360(query: normalizedQuery)
        async let sogouBatch = searchSogou(query: normalizedQuery)
        async let wechatBatch = searchWeChat(query: normalizedQuery)
        async let toutiaoBatch = searchToutiao(query: normalizedQuery)
        async let jisiluBatch = searchJisilu(query: normalizedQuery)

        async let ddgBatch = searchDuckDuckGo(query: normalizedQuery, lang: lang, safeSearch: safeSearch)
        async let wikiBatch = searchWikipedia(query: normalizedQuery, lang: lang)
        async let hnBatch = searchHNAlgolia(query: normalizedQuery)
        async let bingBatch = searchBing(query: normalizedQuery, lang: lang, safeSearch: safeSearch)
        async let googleBatch = searchGoogle(query: normalizedQuery, lang: lang, safeSearch: safeSearch)
        async let googleHKBatch = searchGoogleHK(query: normalizedQuery)
        async let yahooBatch = searchYahoo(query: normalizedQuery)
        async let startpageBatch = searchStartpage(query: normalizedQuery)
        async let braveBatch = searchBrave(query: normalizedQuery)
        async let ecosiaBatch = searchEcosia(query: normalizedQuery)
        async let qwantBatch = searchQwant(query: normalizedQuery)
        async let wolframAlphaBatch = searchWolframAlpha(query: normalizedQuery)

        let batches = await[
            baiduBatch,
            bingCNBatch,
            bingINTBatch,
            so360Batch,
            sogouBatch,
            wechatBatch,
            toutiaoBatch,
            jisiluBatch,
            ddgBatch,
            wikiBatch,
            hnBatch,
            bingBatch,
            googleBatch,
            googleHKBatch,
            yahooBatch,
            startpageBatch,
            braveBatch,
            ecosiaBatch,
            qwantBatch,
            wolframAlphaBatch,
        ]
        let sourceStatus = batches.map {
            WebSearchSourceStatus(
                source: $0.source,
                succeeded: $0.error == nil,
                count: $0.items.count,
                error: $0.error
            )
        }

        var allCandidates: [RawSearchItem] = []
        for batch in batches {
            allCandidates.append(contentsOf: batch.items)
        }

        let reranked = rerankAndDeduplicate(candidates: allCandidates, query: normalizedQuery)
        let enriched = await enrichTopResults(items: reranked, fetchTopK: resolvedFetchTopK)
        let finalItems = Array(enriched.prefix(resolvedTopK)).enumerated().map { index, item in
            WebSearchItem(
                title: item.title,
                link: item.link,
                summary: item.summary,
                domain: item.domain,
                rank: index + 1,
                source: item.bestSource,
                sources: item.sources.sorted()
            )
        }

        let message = "Found \(finalItems.count) results from \(sourceStatus.filter { $0.succeeded }.count)/\(sourceStatus.count) sources"
        return WebSearchResult(
            query: normalizedQuery,
            total: finalItems.count,
            topK: resolvedTopK,
            fetchTopK: resolvedFetchTopK,
            results: finalItems,
            sourceStatus: sourceStatus,
            message: message
        )
    }

    private func searchDuckDuckGo(query: String, lang: String, safeSearch: String) async -> SearchBatch {
        var components = URLComponents(string: "https://duckduckgo.com/html/")
        components?.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "kl", value: Self.duckDuckGoLang(from: lang)),
            URLQueryItem(name: "kp", value: Self.duckDuckGoSafeSearch(from: safeSearch)),
        ]

        guard let url = components?.url else {
            return SearchBatch(source: "duckduckgo", items: [], error: "Invalid URL")
        }

        do {
            let html = try await fetchText(url: url)
            let blocks = Self.extractBlocks(in: html, pattern: "<div[^>]*class=\"[^\\\"]*result[^\\\"]*\"[^>]*>[\\s\\S]*?<\\/div>")
            var items: [RawSearchItem] = []

            for block in blocks {
                guard let title = Self.firstCapture(in: block, pattern: "<a[^>]*class=\"[^\\\"]*result__a[^\\\"]*\"[^>]*>([\\s\\S]*?)<\\/a>"),
                      let href = Self.firstCapture(in: block, pattern: "<a[^>]*class=\"[^\\\"]*result__a[^\\\"]*\"[^>]*href=\"([^\\\"]+)\"")
                else {
                    continue
                }

                let resolvedURL = Self.resolveDuckDuckGoLink(href)
                guard let normalizedURL = Self.normalizeResultURL(resolvedURL) else {
                    continue
                }

                let snippet = Self.firstCapture(in: block, pattern: "<a[^>]*class=\"[^\\\"]*result__snippet[^\\\"]*\"[^>]*>([\\s\\S]*?)<\\/a>")
                    ?? Self.firstCapture(in: block, pattern: "<div[^>]*class=\"[^\\\"]*result__snippet[^\\\"]*\"[^>]*>([\\s\\S]*?)<\\/div>")
                    ?? ""

                items.append(RawSearchItem(
                    title: Self.cleanText(title),
                    link: normalizedURL,
                    summary: Self.cleanText(snippet),
                    source: "duckduckgo",
                    sourceRank: items.count + 1
                ))

                if items.count >= 15 {
                    break
                }
            }

            return SearchBatch(source: "duckduckgo", items: items, error: nil)
        } catch {
            return SearchBatch(source: "duckduckgo", items: [], error: error.localizedDescription)
        }
    }

    private func searchWikipedia(query: String, lang: String) async -> SearchBatch {
        let wikiLanguage = Self.wikipediaLanguage(from: lang)
        var components = URLComponents(string: "https://\(wikiLanguage).wikipedia.org/w/api.php")
        components?.queryItems = [
            URLQueryItem(name: "action", value: "query"),
            URLQueryItem(name: "list", value: "search"),
            URLQueryItem(name: "utf8", value: "1"),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "srlimit", value: "10"),
            URLQueryItem(name: "srsearch", value: query),
        ]

        guard let url = components?.url else {
            return SearchBatch(source: "wikipedia", items: [], error: "Invalid URL")
        }

        struct Response: Decodable {
            struct QueryNode: Decodable {
                struct Item: Decodable {
                    let title: String
                    let snippet: String
                    let pageid: Int
                }

                let search: [Item]
            }

            let query: QueryNode?
        }

        do {
            let data = try await fetchData(url: url)
            let decoded = try JSONDecoder().decode(Response.self, from: data)
            let items = (decoded.query?.search ?? []).enumerated().compactMap { index, item -> RawSearchItem? in
                let url = "https://\(wikiLanguage).wikipedia.org/?curid=\(item.pageid)"
                guard let normalizedURL = Self.normalizeResultURL(url) else {
                    return nil
                }
                return RawSearchItem(
                    title: Self.cleanText(item.title),
                    link: normalizedURL,
                    summary: Self.cleanText(item.snippet),
                    source: "wikipedia",
                    sourceRank: index + 1
                )
            }
            return SearchBatch(source: "wikipedia", items: items, error: nil)
        } catch {
            return SearchBatch(source: "wikipedia", items: [], error: error.localizedDescription)
        }
    }

    private func searchHNAlgolia(query: String) async -> SearchBatch {
        var components = URLComponents(string: "https://hn.algolia.com/api/v1/search")
        components?.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "tags", value: "story"),
            URLQueryItem(name: "hitsPerPage", value: "10"),
        ]

        guard let url = components?.url else {
            return SearchBatch(source: "hn", items: [], error: "Invalid URL")
        }

        struct Response: Decodable {
            struct Hit: Decodable {
                let title: String?
                let story_title: String?
                let url: String?
                let story_url: String?
                let _highlightResult: HighlightNode?

                struct HighlightNode: Decodable {
                    struct ValueNode: Decodable {
                        let value: String?
                    }

                    let title: ValueNode?
                    let story_title: ValueNode?
                }
            }

            let hits: [Hit]
        }

        do {
            let data = try await fetchData(url: url)
            let decoded = try JSONDecoder().decode(Response.self, from: data)
            var rank = 0
            let items = decoded.hits.compactMap { hit -> RawSearchItem? in
                let title = hit.title ?? hit.story_title
                let link = hit.url ?? hit.story_url
                guard let titleText = title, let linkText = link,
                      let normalizedURL = Self.normalizeResultURL(linkText)
                else {
                    return nil
                }
                rank += 1
                let highlight = hit._highlightResult?.title?.value
                    ?? hit._highlightResult?.story_title?.value
                    ?? ""
                return RawSearchItem(
                    title: Self.cleanText(titleText),
                    link: normalizedURL,
                    summary: Self.cleanText(highlight),
                    source: "hn",
                    sourceRank: rank
                )
            }
            return SearchBatch(source: "hn", items: items, error: nil)
        } catch {
            return SearchBatch(source: "hn", items: [], error: error.localizedDescription)
        }
    }

    private func searchBing(query: String, lang: String, safeSearch: String) async -> SearchBatch {
        var components = URLComponents(string: "https://www.bing.com/search")
        components?.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "setlang", value: Self.bingLanguage(from: lang)),
            URLQueryItem(name: "adlt", value: Self.bingSafeSearch(from: safeSearch)),
        ]

        guard let url = components?.url else {
            return SearchBatch(source: "bing", items: [], error: "Invalid URL")
        }

        do {
            let html = try await fetchText(url: url)
            let blocks = Self.extractBlocks(in: html, pattern: "<li[^>]*class=\"[^\\\"]*b_algo[^\\\"]*\"[^>]*>[\\s\\S]*?<\\/li>")
            var items: [RawSearchItem] = []

            for block in blocks {
                guard let title = Self.firstCapture(in: block, pattern: "<h2[^>]*><a[^>]*>([\\s\\S]*?)<\\/a><\\/h2>"),
                      let href = Self.firstCapture(in: block, pattern: "<h2[^>]*><a[^>]*href=\"([^\"]+)\"")
                else {
                    continue
                }

                guard let normalizedURL = Self.normalizeResultURL(href) else {
                    continue
                }

                let snippet = Self.firstCapture(in: block, pattern: "<p>([\\s\\S]*?)<\\/p>") ?? ""
                items.append(RawSearchItem(
                    title: Self.cleanText(title),
                    link: normalizedURL,
                    summary: Self.cleanText(snippet),
                    source: "bing",
                    sourceRank: items.count + 1
                ))

                if items.count >= 12 {
                    break
                }
            }

            return SearchBatch(source: "bing", items: items, error: nil)
        } catch {
            return SearchBatch(source: "bing", items: [], error: error.localizedDescription)
        }
    }

    private func searchGoogle(query: String, lang: String, safeSearch: String) async -> SearchBatch {
        var components = URLComponents(string: "https://www.google.com/search")
        components?.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "hl", value: Self.googleLanguage(from: lang)),
            URLQueryItem(name: "safe", value: safeSearch == "strict" ? "active" : "off"),
            URLQueryItem(name: "num", value: "10"),
        ]

        guard let url = components?.url else {
            return SearchBatch(source: "google", items: [], error: "Invalid URL")
        }

        do {
            let html = try await fetchText(url: url)
            let blocks = Self.extractBlocks(in: html, pattern: "<div[^>]*class=\"[^\\\"]*g[^\\\"]*\"[^>]*>[\\s\\S]*?<\\/div>")
            var items: [RawSearchItem] = []

            for block in blocks {
                guard let title = Self.firstCapture(in: block, pattern: "<h3[^>]*>([\\s\\S]*?)<\\/h3>"),
                      let href = Self.firstCapture(in: block, pattern: "<a[^>]*href=\"([^\"]+)\"")
                else {
                    continue
                }

                let resolvedHref = Self.resolveGoogleLink(href)
                guard let normalizedURL = Self.normalizeResultURL(resolvedHref) else {
                    continue
                }

                let snippet = Self.firstCapture(in: block, pattern: "<span[^>]*>([\\s\\S]*?)<\\/span>") ?? ""
                items.append(RawSearchItem(
                    title: Self.cleanText(title),
                    link: normalizedURL,
                    summary: Self.cleanText(snippet),
                    source: "google",
                    sourceRank: items.count + 1
                ))

                if items.count >= 10 {
                    break
                }
            }

            return SearchBatch(source: "google", items: items, error: nil)
        } catch {
            return SearchBatch(source: "google", items: [], error: error.localizedDescription)
        }
    }

    private func searchGoogleHK(query: String) async -> SearchBatch {
        var components = URLComponents(string: "https://www.google.com.hk/search")
        components?.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "num", value: "10"),
        ]
        return await searchHTMLSource(
            source: "google_hk",
            components: components,
            blockPattern: "<div[^>]*class=\\\"[^\\\"]*g[^\\\"]*\\\"[^>]*>[\\s\\S]*?<\\/div>",
            titlePatterns: ["<h3[^>]*>([\\s\\S]*?)<\\/h3>"],
            hrefPatterns: ["<a[^>]*href=\\\"([^\\\"]+)\\\""],
            snippetPatterns: ["<span[^>]*>([\\s\\S]*?)<\\/span>"],
            maxItems: 10,
            linkResolver: Self.resolveGoogleLink
        )
    }

    private func searchBaidu(query: String) async -> SearchBatch {
        var components = URLComponents(string: "https://www.baidu.com/s")
        components?.queryItems = [URLQueryItem(name: "wd", value: query)]
        return await searchHTMLSource(
            source: "baidu",
            components: components,
            blockPattern: "<div[^>]*class=\\\"[^\\\"]*result[^\\\"]*\\\"[^>]*>[\\s\\S]*?<\\/div>",
            titlePatterns: ["<h3[^>]*>([\\s\\S]*?)<\\/h3>"],
            hrefPatterns: ["<h3[^>]*><a[^>]*href=\\\"([^\\\"]+)\\\""],
            snippetPatterns: [
                "<div[^>]*class=\\\"[^\\\"]*c-abstract[^\\\"]*\\\"[^>]*>([\\s\\S]*?)<\\/div>",
                "<span[^>]*class=\\\"[^\\\"]*content-right_[^\\\"]*\\\"[^>]*>([\\s\\S]*?)<\\/span>",
            ],
            maxItems: 12,
            linkResolver: Self.resolveBaiduLink
        )
    }

    private func searchBingCN(query: String) async -> SearchBatch {
        await searchBingVariant(query: query, source: "bing_cn", ensearch: false)
    }

    private func searchBingINT(query: String) async -> SearchBatch {
        await searchBingVariant(query: query, source: "bing_int", ensearch: true)
    }

    private func searchBingVariant(query: String, source: String, ensearch: Bool) async -> SearchBatch {
        var components = URLComponents(string: "https://cn.bing.com/search")
        components?.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "ensearch", value: ensearch ? "1" : "0"),
        ]
        return await searchHTMLSource(
            source: source,
            components: components,
            blockPattern: "<li[^>]*class=\\\"[^\\\"]*b_algo[^\\\"]*\\\"[^>]*>[\\s\\S]*?<\\/li>",
            titlePatterns: ["<h2[^>]*><a[^>]*>([\\s\\S]*?)<\\/a><\\/h2>"],
            hrefPatterns: ["<h2[^>]*><a[^>]*href=\\\"([^\\\"]+)\\\""],
            snippetPatterns: ["<p>([\\s\\S]*?)<\\/p>"],
            maxItems: 12
        )
    }

    private func searchSo360(query: String) async -> SearchBatch {
        var components = URLComponents(string: "https://www.so.com/s")
        components?.queryItems = [URLQueryItem(name: "q", value: query)]
        return await searchHTMLSource(
            source: "360",
            components: components,
            blockPattern: "<li[^>]*class=\\\"[^\\\"]*res-list[^\\\"]*\\\"[^>]*>[\\s\\S]*?<\\/li>",
            titlePatterns: ["<h3[^>]*>([\\s\\S]*?)<\\/h3>"],
            hrefPatterns: ["<h3[^>]*><a[^>]*href=\\\"([^\\\"]+)\\\""],
            snippetPatterns: ["<p[^>]*class=\\\"[^\\\"]*res-desc[^\\\"]*\\\"[^>]*>([\\s\\S]*?)<\\/p>"],
            maxItems: 10
        )
    }

    private func searchSogou(query: String) async -> SearchBatch {
        var components = URLComponents(string: "https://sogou.com/web")
        components?.queryItems = [URLQueryItem(name: "query", value: query)]
        return await searchHTMLSource(
            source: "sogou",
            components: components,
            blockPattern: "<div[^>]*class=\\\"[^\\\"]*vrwrap[^\\\"]*\\\"[^>]*>[\\s\\S]*?<\\/div>",
            titlePatterns: ["<h3[^>]*>([\\s\\S]*?)<\\/h3>"],
            hrefPatterns: ["<h3[^>]*><a[^>]*href=\\\"([^\\\"]+)\\\""],
            snippetPatterns: ["<p[^>]*class=\\\"[^\\\"]*str-text-info[^\\\"]*\\\"[^>]*>([\\s\\S]*?)<\\/p>"],
            maxItems: 10,
            linkResolver: Self.resolveSogouLink
        )
    }

    private func searchWeChat(query: String) async -> SearchBatch {
        var components = URLComponents(string: "https://wx.sogou.com/weixin")
        components?.queryItems = [
            URLQueryItem(name: "type", value: "2"),
            URLQueryItem(name: "query", value: query),
        ]
        return await searchHTMLSource(
            source: "wechat",
            components: components,
            blockPattern: "<li[^>]*id=\\\"sogou_vr_[^\\\"]*\\\"[^>]*>[\\s\\S]*?<\\/li>",
            titlePatterns: ["<h3[^>]*>([\\s\\S]*?)<\\/h3>"],
            hrefPatterns: ["<h3[^>]*><a[^>]*href=\\\"([^\\\"]+)\\\""],
            snippetPatterns: ["<p[^>]*class=\\\"[^\\\"]*txt-info[^\\\"]*\\\"[^>]*>([\\s\\S]*?)<\\/p>"],
            maxItems: 10,
            linkResolver: Self.resolveSogouLink
        )
    }

    private func searchToutiao(query: String) async -> SearchBatch {
        var components = URLComponents(string: "https://so.toutiao.com/search")
        components?.queryItems = [URLQueryItem(name: "keyword", value: query)]
        return await searchHTMLSource(
            source: "toutiao",
            components: components,
            blockPattern: "<div[^>]*class=\\\"[^\\\"]*result-content[^\\\"]*\\\"[^>]*>[\\s\\S]*?<\\/div>",
            titlePatterns: ["<a[^>]*class=\\\"[^\\\"]*title[^\\\"]*\\\"[^>]*>([\\s\\S]*?)<\\/a>"],
            hrefPatterns: ["<a[^>]*class=\\\"[^\\\"]*title[^\\\"]*\\\"[^>]*href=\\\"([^\\\"]+)\\\""],
            snippetPatterns: ["<div[^>]*class=\\\"[^\\\"]*text-ellipsis[^\\\"]*\\\"[^>]*>([\\s\\S]*?)<\\/div>"],
            maxItems: 10
        )
    }

    private func searchJisilu(query: String) async -> SearchBatch {
        var components = URLComponents(string: "https://www.jisilu.cn/explore/")
        components?.queryItems = [URLQueryItem(name: "keyword", value: query)]
        return await searchHTMLSource(
            source: "jisilu",
            components: components,
            blockPattern: "<div[^>]*class=\\\"[^\\\"]*topic-item[^\\\"]*\\\"[^>]*>[\\s\\S]*?<\\/div>",
            titlePatterns: ["<a[^>]*class=\\\"[^\\\"]*title[^\\\"]*\\\"[^>]*>([\\s\\S]*?)<\\/a>"],
            hrefPatterns: ["<a[^>]*class=\\\"[^\\\"]*title[^\\\"]*\\\"[^>]*href=\\\"([^\\\"]+)\\\""],
            snippetPatterns: ["<div[^>]*class=\\\"[^\\\"]*topic-summary[^\\\"]*\\\"[^>]*>([\\s\\S]*?)<\\/div>"],
            maxItems: 8,
            linkResolver: Self.resolveJisiluLink
        )
    }

    private func searchYahoo(query: String) async -> SearchBatch {
        var components = URLComponents(string: "https://search.yahoo.com/search")
        components?.queryItems = [URLQueryItem(name: "p", value: query)]
        return await searchHTMLSource(
            source: "yahoo",
            components: components,
            blockPattern: "<div[^>]*class=\\\"[^\\\"]*algo[^\\\"]*\\\"[^>]*>[\\s\\S]*?<\\/div>",
            titlePatterns: ["<h3[^>]*>([\\s\\S]*?)<\\/h3>"],
            hrefPatterns: ["<h3[^>]*><a[^>]*href=\\\"([^\\\"]+)\\\""],
            snippetPatterns: ["<p[^>]*>([\\s\\S]*?)<\\/p>"],
            maxItems: 10,
            linkResolver: Self.resolveYahooLink
        )
    }

    private func searchStartpage(query: String) async -> SearchBatch {
        var components = URLComponents(string: "https://www.startpage.com/sp/search")
        components?.queryItems = [URLQueryItem(name: "query", value: query)]
        return await searchHTMLSource(
            source: "startpage",
            components: components,
            blockPattern: "<div[^>]*class=\\\"[^\\\"]*w-gl__result[^\\\"]*\\\"[^>]*>[\\s\\S]*?<\\/div>",
            titlePatterns: ["<a[^>]*class=\\\"[^\\\"]*w-gl__result-title[^\\\"]*\\\"[^>]*>([\\s\\S]*?)<\\/a>"],
            hrefPatterns: ["<a[^>]*class=\\\"[^\\\"]*w-gl__result-title[^\\\"]*\\\"[^>]*href=\\\"([^\\\"]+)\\\""],
            snippetPatterns: ["<p[^>]*class=\\\"[^\\\"]*w-gl__description[^\\\"]*\\\"[^>]*>([\\s\\S]*?)<\\/p>"],
            maxItems: 10,
            linkResolver: Self.resolveStartpageLink
        )
    }

    private func searchBrave(query: String) async -> SearchBatch {
        var components = URLComponents(string: "https://search.brave.com/search")
        components?.queryItems = [URLQueryItem(name: "q", value: query)]
        return await searchHTMLSource(
            source: "brave",
            components: components,
            blockPattern: "<div[^>]*class=\\\"[^\\\"]*snippet[^\\\"]*\\\"[^>]*>[\\s\\S]*?<\\/div>",
            titlePatterns: [
                "<a[^>]*data-testid=\\\"result-title-a\\\"[^>]*>([\\s\\S]*?)<\\/a>",
                "<h2[^>]*>([\\s\\S]*?)<\\/h2>",
            ],
            hrefPatterns: [
                "<a[^>]*data-testid=\\\"result-title-a\\\"[^>]*href=\\\"([^\\\"]+)\\\"",
                "<a[^>]*href=\\\"([^\\\"]+)\\\"",
            ],
            snippetPatterns: ["<div[^>]*class=\\\"[^\\\"]*snippet-description[^\\\"]*\\\"[^>]*>([\\s\\S]*?)<\\/div>"],
            maxItems: 10
        )
    }

    private func searchEcosia(query: String) async -> SearchBatch {
        var components = URLComponents(string: "https://www.ecosia.org/search")
        components?.queryItems = [URLQueryItem(name: "q", value: query)]
        return await searchHTMLSource(
            source: "ecosia",
            components: components,
            blockPattern: "<div[^>]*class=\\\"[^\\\"]*result[^\\\"]*\\\"[^>]*>[\\s\\S]*?<\\/div>",
            titlePatterns: ["<a[^>]*class=\\\"[^\\\"]*result-title[^\\\"]*\\\"[^>]*>([\\s\\S]*?)<\\/a>"],
            hrefPatterns: ["<a[^>]*class=\\\"[^\\\"]*result-title[^\\\"]*\\\"[^>]*href=\\\"([^\\\"]+)\\\""],
            snippetPatterns: ["<p[^>]*class=\\\"[^\\\"]*result-snippet[^\\\"]*\\\"[^>]*>([\\s\\S]*?)<\\/p>"],
            maxItems: 10
        )
    }

    private func searchQwant(query: String) async -> SearchBatch {
        var components = URLComponents(string: "https://www.qwant.com/")
        components?.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "t", value: "web"),
        ]
        return await searchHTMLSource(
            source: "qwant",
            components: components,
            blockPattern: "<article[^>]*>[\\s\\S]*?<\\/article>",
            titlePatterns: ["<a[^>]*class=\\\"[^\\\"]*result--web__link[^\\\"]*\\\"[^>]*>([\\s\\S]*?)<\\/a>"],
            hrefPatterns: ["<a[^>]*class=\\\"[^\\\"]*result--web__link[^\\\"]*\\\"[^>]*href=\\\"([^\\\"]+)\\\""],
            snippetPatterns: ["<p[^>]*>([\\s\\S]*?)<\\/p>"],
            maxItems: 10
        )
    }

    private func searchWolframAlpha(query: String) async -> SearchBatch {
        // WolframAlpha is query-page oriented, so provide a deterministic direct entry.
        var components = URLComponents(string: "https://www.wolframalpha.com/input")
        components?.queryItems = [URLQueryItem(name: "i", value: query)]
        guard let url = components?.url,
              let normalizedURL = Self.normalizeResultURL(url.absoluteString)
        else {
            return SearchBatch(source: "wolframalpha", items: [], error: "Invalid URL")
        }
        let item = RawSearchItem(
            title: "WolframAlpha: \(query)",
            link: normalizedURL,
            summary: "Computational knowledge result page",
            source: "wolframalpha",
            sourceRank: 1
        )
        return SearchBatch(source: "wolframalpha", items: [item], error: nil)
    }

    private func searchHTMLSource(
        source: String,
        components: URLComponents?,
        blockPattern: String,
        titlePatterns: [String],
        hrefPatterns: [String],
        snippetPatterns: [String],
        maxItems: Int,
        linkResolver: (String) -> String = { $0 }
    ) async -> SearchBatch {
        guard let url = components?.url else {
            return SearchBatch(source: source, items: [], error: "Invalid URL")
        }

        do {
            let html = try await fetchText(url: url)
            let blocks = Self.extractBlocks(in: html, pattern: blockPattern)
            // Fallback keeps engines with unstable markup still partially usable.
            let candidateBlocks = blocks.isEmpty
                ? Self.extractBlocks(in: html, pattern: "<a[^>]*href=\\\"[^\\\"]+\\\"[^>]*>[\\s\\S]*?<\\/a>")
                : blocks
            var items: [RawSearchItem] = []
            var seenLinks: Set<String> = []

            for block in candidateBlocks {
                guard let title = Self.firstCapture(in: block, patterns: titlePatterns)
                    ?? Self.firstCapture(in: block, pattern: "<a[^>]*>([\\s\\S]*?)<\\/a>"),
                    let href = Self.firstCapture(in: block, patterns: hrefPatterns)
                    ?? Self.firstCapture(in: block, pattern: "<a[^>]*href=\\\"([^\\\"]+)\\\"")
                else {
                    continue
                }

                let resolvedURL = linkResolver(href)
                guard let normalizedURL = Self.normalizeResultURL(resolvedURL), !seenLinks.contains(normalizedURL) else {
                    continue
                }

                let snippet = Self.firstCapture(in: block, patterns: snippetPatterns) ?? ""
                items.append(RawSearchItem(
                    title: Self.cleanText(title),
                    link: normalizedURL,
                    summary: Self.cleanText(snippet),
                    source: source,
                    sourceRank: items.count + 1
                ))
                seenLinks.insert(normalizedURL)

                if items.count >= maxItems {
                    break
                }
            }

            return SearchBatch(source: source, items: items, error: nil)
        } catch {
            return SearchBatch(source: source, items: [], error: error.localizedDescription)
        }
    }

    private func rerankAndDeduplicate(candidates: [RawSearchItem], query: String) -> [RankedItem] {
        let queryTokens = Set(Self.tokenize(query))
        var merged: [String: RankedItem] = [:]

        for candidate in candidates {
            let key = Self.dedupKey(link: candidate.link, title: candidate.title)
            let domain = Self.domain(from: candidate.link)
            let sourceWeight = Self.sourceWeight(for: candidate.source)
            let positionWeight = max(0.0, 18.0 - (Double(candidate.sourceRank) * 1.2))

            let corpus = (candidate.title + " " + candidate.summary).lowercased()
            let tokenHits = queryTokens.filter { corpus.contains($0) }.count
            let tokenWeight = Double(tokenHits) * 2.8
            let summaryWeight = min(6.0, Double(candidate.summary.count) / 50.0)
            let score = sourceWeight + positionWeight + tokenWeight + summaryWeight

            if var existing = merged[key] {
                if score > existing.score {
                    existing.title = candidate.title
                    existing.link = candidate.link
                    existing.summary = candidate.summary
                    existing.domain = domain
                    existing.bestSource = candidate.source
                    existing.score = score
                }
                existing.sources.insert(candidate.source)
                existing.score += 0.7
                merged[key] = existing
            } else {
                merged[key] = RankedItem(
                    title: candidate.title,
                    link: candidate.link,
                    summary: candidate.summary,
                    domain: domain,
                    score: score,
                    bestSource: candidate.source,
                    sources: [candidate.source]
                )
            }
        }

        return merged.values.sorted {
            if abs($0.score - $1.score) < 0.001 {
                return $0.title < $1.title
            }
            return $0.score > $1.score
        }
    }

    private func enrichTopResults(items: [RankedItem], fetchTopK: Int) async -> [RankedItem] {
        guard fetchTopK > 0, !items.isEmpty else {
            return items
        }

        var enriched = items
        let limit = min(fetchTopK, items.count)

        await withTaskGroup(of: (Int, String?, Double).self) { group in
            for index in 0 ..< limit {
                let link = items[index].link
                group.addTask { [webFetchService] in
                    guard let url = URL(string: link) else {
                        return (index, nil, 0)
                    }
                    do {
                        let fetched = try await webFetchService.fetch(url: url, extractMode: .text, maxChars: 1500)
                        let excerpt = Self.compactSummary(from: fetched.text)
                        let bonus = min(4.0, Double(excerpt.count) / 150.0)
                        return (index, excerpt.isEmpty ? nil : excerpt, bonus)
                    } catch {
                        return (index, nil, 0)
                    }
                }
            }

            for await result in group {
                let (index, excerpt, bonus) = result
                guard index < enriched.count else { continue }
                if let excerpt, excerpt.count > enriched[index].summary.count {
                    enriched[index].summary = excerpt
                }
                enriched[index].score += bonus
            }
        }

        return enriched.sorted {
            if abs($0.score - $1.score) < 0.001 {
                return $0.title < $1.title
            }
            return $0.score > $1.score
        }
    }

    private func fetchText(url: URL) async throws -> String {
        let data = try await fetchData(url: url)
        return String(decoding: data, as: UTF8.self)
    }

    private func fetchData(url: URL) async throws -> Data {
        guard let host = url.host, !LoopbackHost.isLocalNetworkHost(host) else {
            throw WebFetchService.WebFetchError.privateNetworkBlocked
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = Self.defaultTimeoutSeconds
        request.setValue("text/html,application/json;q=0.9,*/*;q=0.5", forHTTPHeaderField: "Accept")
        request.setValue("zh-CN,zh;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        request.setValue(Self.defaultUserAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200 ... 299).contains(httpResponse.statusCode)
        else {
            throw WebFetchService.WebFetchError.invalidResponse
        }
        return data
    }

    private static func dedupKey(link: String, title: String) -> String {
        if let normalizedURL = normalizeResultURL(link) {
            return normalizedURL.lowercased()
        }
        return normalizeWhitespace(title).lowercased()
    }

    private static func normalizeResultURL(_ raw: String) -> String? {
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
                let name = item.name.lowercased()
                return !(name.hasPrefix("utm_") || name == "fbclid" || name == "gclid")
            }
            components.queryItems = filtered.isEmpty ? nil : filtered
        }
        return components.url?.absoluteString
    }

    private static func domain(from link: String) -> String {
        guard let host = URL(string: link)?.host?.lowercased() else {
            return "unknown"
        }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    private static func cleanText(_ value: String) -> String {
        normalizeWhitespace(decodeHTMLEntities(stripTags(value)))
    }

    private static func compactSummary(from value: String) -> String {
        let normalized = normalizeWhitespace(value)
        guard normalized.count > 320 else { return normalized }
        let endIndex = normalized.index(normalized.startIndex, offsetBy: 320)
        return String(normalized[..<endIndex]) + "..."
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

    private static func tokenize(_ query: String) -> [String] {
        let raw = query.lowercased().split(whereSeparator: { $0.isWhitespace || $0.isPunctuation })
        return raw.map(String.init).filter { $0.count >= 2 }
    }

    private static func firstCapture(in value: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(value.startIndex..., in: value)
        guard let match = regex.firstMatch(in: value, range: range),
              let capture = Range(match.range(at: 1), in: value)
        else {
            return nil
        }
        return String(value[capture])
    }

    private static func firstCapture(in value: String, patterns: [String]) -> String? {
        for pattern in patterns {
            if let captured = firstCapture(in: value, pattern: pattern) {
                return captured
            }
        }
        return nil
    }

    private static func extractBlocks(in value: String, pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }
        let range = NSRange(value.startIndex..., in: value)
        return regex.matches(in: value, range: range).compactMap { match in
            guard let found = Range(match.range, in: value) else {
                return nil
            }
            return String(value[found])
        }
    }

    private static func resolveDuckDuckGoLink(_ raw: String) -> String {
        guard raw.contains("duckduckgo.com/l/") else {
            return raw
        }
        guard let components = URLComponents(string: raw),
              let encoded = components.queryItems?.first(where: { $0.name == "uddg" })?.value,
              let decoded = encoded.removingPercentEncoding
        else {
            return raw
        }
        return decoded
    }

    private static func resolveGoogleLink(_ raw: String) -> String {
        guard raw.hasPrefix("/url?") else {
            return raw
        }
        guard let components = URLComponents(string: "https://www.google.com" + raw),
              let target = components.queryItems?.first(where: { $0.name == "q" })?.value
        else {
            return raw
        }
        return target
    }

    private static func resolveBaiduLink(_ raw: String) -> String {
        if raw.hasPrefix("http://") || raw.hasPrefix("https://") {
            return raw
        }
        if raw.hasPrefix("/") {
            return "https://www.baidu.com" + raw
        }
        return raw
    }

    private static func resolveSogouLink(_ raw: String) -> String {
        if raw.hasPrefix("http://") || raw.hasPrefix("https://") {
            if let extracted = extractURLFromQuery(raw, keys: ["url", "u", "target"]) {
                return extracted
            }
            return raw
        }
        if raw.hasPrefix("/") {
            let absolute = "https://www.sogou.com" + raw
            if let extracted = extractURLFromQuery(absolute, keys: ["url", "u", "target"]) {
                return extracted
            }
            return absolute
        }
        return raw
    }

    private static func resolveJisiluLink(_ raw: String) -> String {
        if raw.hasPrefix("http://") || raw.hasPrefix("https://") {
            return raw
        }
        if raw.hasPrefix("/") {
            return "https://www.jisilu.cn" + raw
        }
        return raw
    }

    private static func resolveYahooLink(_ raw: String) -> String {
        if let extracted = extractURLFromQuery(raw, keys: ["RU", "u", "url"]) {
            return extracted
        }
        return raw
    }

    private static func resolveStartpageLink(_ raw: String) -> String {
        if let extracted = extractURLFromQuery(raw, keys: ["url", "u"]),
           extracted.hasPrefix("http://") || extracted.hasPrefix("https://")
        {
            return extracted
        }
        if raw.hasPrefix("/") {
            return "https://www.startpage.com" + raw
        }
        return raw
    }

    private static func extractURLFromQuery(_ raw: String, keys: [String]) -> String? {
        guard let components = URLComponents(string: raw) else {
            return nil
        }
        for key in keys {
            if let value = components.queryItems?.first(where: { $0.name.caseInsensitiveCompare(key) == .orderedSame })?.value,
               let decoded = value.removingPercentEncoding,
               decoded.hasPrefix("http://") || decoded.hasPrefix("https://")
            {
                return decoded
            }
        }
        return nil
    }

    private static func sourceWeight(for source: String) -> Double {
        switch source {
        case "wikipedia": return 18.0
        case "wolframalpha": return 17.5
        case "baidu": return 17.0
        case "bing_cn": return 16.8
        case "bing_int": return 16.4
        case "duckduckgo": return 16.0
        case "google_hk": return 15.5
        case "google": return 15.0
        case "bing": return 14.5
        case "startpage": return 14.3
        case "brave": return 14.1
        case "ecosia": return 13.9
        case "qwant": return 13.7
        case "yahoo": return 13.5
        case "hn": return 13.0
        case "sogou": return 12.8
        case "wechat": return 12.6
        case "360": return 12.4
        case "toutiao": return 12.2
        case "jisilu": return 12.0
        default: return 10.0
        }
    }

    private static func duckDuckGoLang(from lang: String) -> String {
        let lowered = lang.lowercased()
        if lowered.hasPrefix("zh") { return "cn-zh" }
        if lowered.hasPrefix("ja") { return "jp-jp" }
        return "us-en"
    }

    private static func wikipediaLanguage(from lang: String) -> String {
        let lowered = lang.lowercased()
        if lowered.hasPrefix("zh") { return "zh" }
        if lowered.hasPrefix("ja") { return "ja" }
        return "en"
    }

    private static func googleLanguage(from lang: String) -> String {
        let lowered = lang.lowercased()
        if lowered.hasPrefix("zh") { return "zh-CN" }
        if lowered.hasPrefix("ja") { return "ja" }
        return "en"
    }

    private static func bingLanguage(from lang: String) -> String {
        let lowered = lang.lowercased()
        if lowered.hasPrefix("zh") { return "zh-Hans" }
        if lowered.hasPrefix("ja") { return "ja" }
        return "en-US"
    }

    private static func duckDuckGoSafeSearch(from value: String) -> String {
        switch value.lowercased() {
        case "off": return "-2"
        case "strict": return "1"
        default: return "-1"
        }
    }

    private static func bingSafeSearch(from value: String) -> String {
        switch value.lowercased() {
        case "off": return "off"
        case "strict": return "strict"
        default: return "moderate"
        }
    }

    /// Exposed for deterministic unit tests.
    static func normalizeResultURLForTesting(_ raw: String) -> String? {
        normalizeResultURL(raw)
    }

    /// Exposed for deterministic unit tests.
    static func compactSummaryForTesting(_ value: String) -> String {
        compactSummary(from: value)
    }
}
