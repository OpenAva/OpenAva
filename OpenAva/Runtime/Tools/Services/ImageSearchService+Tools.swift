import Foundation
import OpenClawKit
import OpenClawProtocol

// MARK: - Tools

extension ImageSearchService: ToolDefinitionProvider {
    nonisolated func toolDefinitions() -> [ToolDefinition] {
        [
            ToolDefinition(
                functionName: "image_search",
                command: "image.search",
                description: "Find high-quality, free-to-use images related to a topic. Returns direct image URL, source page URL, size, provider, and license metadata.",
                parametersSchema: AnyCodable([
                    "type": "object",
                    "properties": [
                        "query": [
                            "type": "string",
                            "description": "Topic or keywords to search images for.",
                        ],
                        "topK": [
                            "type": "integer",
                            "minimum": 1,
                            "maximum": 20,
                            "description": "Maximum image results to return (default: 8).",
                        ],
                        "minWidth": [
                            "type": "integer",
                            "minimum": 320,
                            "maximum": 10000,
                            "description": "Minimum width threshold used for quality filtering (default: 1024).",
                        ],
                        "minHeight": [
                            "type": "integer",
                            "minimum": 320,
                            "maximum": 10000,
                            "description": "Minimum height threshold used for quality filtering (default: 720).",
                        ],
                        "orientation": [
                            "type": "string",
                            "enum": ["any", "landscape", "portrait", "square"],
                            "description": "Preferred orientation filter (default: any).",
                        ],
                        "safeSearch": [
                            "type": "boolean",
                            "description": "Enable safer filtering when the source supports it (default: true).",
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
        handlers["image.search"] = { [weak self] request in
            guard let self else { throw ToolHandlerError.handlerUnavailable }
            return try await self.handleImageSearchInvoke(request)
        }
    }

    private func handleImageSearchInvoke(_ request: BridgeInvokeRequest) async throws -> BridgeInvokeResponse {
        struct Params: Codable {
            let query: String
            let topK: Int?
            let minWidth: Int?
            let minHeight: Int?
            let orientation: String?
            let safeSearch: Bool?
        }

        let params = try ToolInvocationHelpers.decodeParams(Params.self, from: request.paramsJSON)
        let query = params.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return ToolInvocationHelpers.invalidRequest(id: request.id, "query is required")
        }

        let result = try await search(
            query: query,
            topK: params.topK ?? 8,
            minWidth: params.minWidth ?? 1024,
            minHeight: params.minHeight ?? 720,
            orientation: params.orientation ?? "any",
            safeSearch: params.safeSearch ?? true
        )
        let lines = result.results.enumerated().map { index, item in
            "\(index + 1). \(item.title)\n   - image: \(item.imageURL)\n   - size: \(item.width)x\(item.height)\n   - provider: \(item.provider), license: \(item.license)"
        }
        let text = "## Image Search\n- query: \(result.query)\n- total: \(result.total)\n- filters: min=\(result.minWidth)x\(result.minHeight), orientation=\(result.orientation)\n\n\(lines.joined(separator: "\n"))"
        return ToolInvocationHelpers.successResponse(id: request.id, payload: text)
    }
}
