import Foundation
import OpenClawKit
import OpenClawProtocol

/// Tool definition provider for web fetch service
// MARK: - Tools

extension WebFetchService: ToolDefinitionProvider {
    nonisolated func toolDefinitions() -> [ToolDefinition] {
        [
            ToolDefinition(
                functionName: "web_fetch",
                command: "web.fetch",
                description: "Fetch web content and apply a task-specific prompt to the extracted page text. Returns AI-friendly plain text with metadata and the processed result.",
                parametersSchema: AnyCodable([
                    "type": "object",
                    "properties": [
                        "url": [
                            "type": "string",
                            "description": "The URL to fetch content from",
                        ],
                        "prompt": [
                            "type": "string",
                            "description": "The task or question to apply to the fetched content",
                        ],
                    ],
                    "required": ["url", "prompt"],
                    "additionalProperties": false,
                ] as [String: Any]),
                isReadOnly: true,
                isConcurrencySafe: true,
                maxResultSizeChars: 48 * 1024
            ),
        ]
    }

    func registerHandlers(into handlers: inout [String: ToolHandler]) {
        handlers["web.fetch"] = { [weak self] request in
            guard let self else { throw ToolHandlerError.handlerUnavailable }
            return try await self.handleWebFetchInvoke(request)
        }
    }

    private func handleWebFetchInvoke(_ request: BridgeInvokeRequest) async throws -> BridgeInvokeResponse {
        struct Params: Codable {
            let url: String
            let prompt: String
        }

        let params = try ToolInvocationHelpers.decodeParams(Params.self, from: request.paramsJSON)
        guard let prompt = AppConfig.nonEmpty(params.prompt) else {
            return ToolInvocationHelpers.invalidRequest(id: request.id, "prompt is required")
        }

        guard let url = URL(string: params.url)
        else {
            return ToolInvocationHelpers.invalidRequest(id: request.id, "invalid URL")
        }

        let result = try await fetch(url: url)
        let processedResult: String
        if let processor = promptProcessor {
            processedResult = try await processor(result, prompt)
        } else {
            processedResult = "The fetched content did not produce a response for the requested prompt."
        }
        return BridgeInvokeResponse(id: request.id, ok: true, payload: result.asPromptResultText(prompt: prompt, processedResult: processedResult))
    }
}
