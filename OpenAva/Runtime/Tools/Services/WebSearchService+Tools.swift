import Foundation
import OpenClawKit
import OpenClawProtocol

// MARK: - Tools

extension WebSearchService: ToolDefinitionProvider {
    nonisolated func toolDefinitions() -> [ToolDefinition] {
        [
            ToolDefinition(
                functionName: "web_search",
                command: "web.search",
                description: "Search the web without API keys using multiple public sources, then deduplicate and rerank results. Returns title, link, summary, domain, rank, and source.",
                parametersSchema: AnyCodable([
                    "type": "object",
                    "properties": [
                        "query": [
                            "type": "string",
                            "description": "Search query text",
                        ],
                        "topK": [
                            "type": "integer",
                            "minimum": 1,
                            "maximum": 20,
                            "description": "Maximum results to return (default: 8)",
                        ],
                        "fetchTopK": [
                            "type": "integer",
                            "minimum": 0,
                            "maximum": 10,
                            "description": "Fetch full page text for top K results for better reranking (default: 3)",
                        ],
                        "lang": [
                            "type": "string",
                            "description": "Preferred language, e.g. zh-CN, en-US (default: zh-CN)",
                        ],
                        "safeSearch": [
                            "type": "string",
                            "enum": ["off", "moderate", "strict"],
                            "description": "Safety filtering mode (default: moderate)",
                        ],
                    ],
                    "required": ["query"],
                    "additionalProperties": false,
                ] as [String: Any]),
                isReadOnly: true,
                isConcurrencySafe: true,
                maxResultSizeChars: 32 * 1024
            ),
        ]
    }

    func registerHandlers(into handlers: inout [String: ToolHandler]) {
        handlers["web.search"] = { [weak self] request in
            guard let self else { throw ToolHandlerError.handlerUnavailable }
            return try await self.handleWebSearchInvoke(request)
        }
    }

    private func handleWebSearchInvoke(_ request: BridgeInvokeRequest) async throws -> BridgeInvokeResponse {
        struct Params: Codable {
            let query: String
            let topK: Int?
            let fetchTopK: Int?
            let lang: String?
            let safeSearch: String?
        }

        let params = try ToolInvocationHelpers.decodeParams(Params.self, from: request.paramsJSON)
        let query = params.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return ToolInvocationHelpers.invalidRequest(id: request.id, "query is required")
        }

        let result = try await search(
            query: query,
            topK: params.topK ?? 8,
            fetchTopK: params.fetchTopK ?? 3,
            lang: params.lang ?? "zh-CN",
            safeSearch: params.safeSearch ?? "moderate"
        )
        let lines = result.results.map { item in
            "\(item.rank). [\(item.title)](\(item.link)) — \(item.summary)"
        }
        let sourceLine = result.sourceStatus.map { "\($0.source):\($0.count)" }.joined(separator: ", ")
        let text = "## Web Search\n- query: \(result.query)\n- total: \(result.total)\n- sources: \(sourceLine)\n\n\(lines.joined(separator: "\n"))"
        return ToolInvocationHelpers.successResponse(id: request.id, payload: text)
    }
}
