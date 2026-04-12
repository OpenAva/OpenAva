import Foundation
import OpenClawKit
import OpenClawProtocol

// MARK: - Tools

extension ArxivSearchService: ToolDefinitionProvider {
    nonisolated func toolDefinitions() -> [ToolDefinition] {
        [
            ToolDefinition(
                functionName: "arxiv_search",
                command: "research.arxiv_search",
                description: "Search arXiv papers or fetch specific arXiv IDs. Returns structured JSON with titles, authors, dates, categories, abstracts, and canonical arXiv links.",
                parametersSchema: AnyCodable([
                    "type": "object",
                    "properties": [
                        "query": [
                            "type": "string",
                            "description": "Keyword query searched across all arXiv fields.",
                        ],
                        "author": [
                            "type": "string",
                            "description": "Author name filter.",
                        ],
                        "category": [
                            "type": "string",
                            "description": "arXiv category such as cs.AI, cs.CL, cs.CV, or cs.LG.",
                        ],
                        "ids": [
                            "type": "array",
                            "items": ["type": "string"],
                            "description": "Specific arXiv IDs to fetch, such as ['2402.03300','1706.03762v7'].",
                        ],
                        "maxResults": [
                            "type": "integer",
                            "minimum": 1,
                            "maximum": 20,
                            "description": "Maximum papers to return (default: 5).",
                        ],
                        "sort": [
                            "type": "string",
                            "enum": ["relevance", "submittedDate", "lastUpdatedDate"],
                            "description": "Sort order for results (default: relevance).",
                        ],
                    ],
                    "additionalProperties": false,
                ] as [String: Any]),
                isReadOnly: true,
                isConcurrencySafe: true,
                maxResultSizeChars: 24 * 1024
            ),
        ]
    }

    func registerHandlers(into handlers: inout [String: ToolHandler]) {
        handlers["research.arxiv_search"] = { [weak self] request in
            guard let self else { throw ToolHandlerError.handlerUnavailable }
            return try await self.handleArxivSearchInvoke(request)
        }
    }

    private func handleArxivSearchInvoke(_ request: BridgeInvokeRequest) async throws -> BridgeInvokeResponse {
        struct Params: Decodable {
            let query: String?
            let author: String?
            let category: String?
            let ids: [String]?
            let maxResults: Int?
            let sort: String?
        }

        let params = try ToolInvocationHelpers.decodeParams(Params.self, from: request.paramsJSON)

        do {
            let result = try await search(
                query: params.query,
                author: params.author,
                category: params.category,
                ids: params.ids,
                maxResults: params.maxResults ?? 5,
                sort: params.sort ?? "relevance"
            )
            return try BridgeInvokeResponse(id: request.id, ok: true, payload: ToolInvocationHelpers.encodePayload(result))
        } catch let error as ArxivSearchServiceError {
            switch error {
            case let .invalidRequest(message):
                return ToolInvocationHelpers.invalidRequest(id: request.id, message)
            case .invalidResponse:
                return ToolInvocationHelpers.unavailableResponse(id: request.id, "UNAVAILABLE: invalid response from arXiv")
            case .parseFailed:
                return ToolInvocationHelpers.unavailableResponse(id: request.id, "UNAVAILABLE: failed to parse arXiv feed")
            }
        }
    }
}
