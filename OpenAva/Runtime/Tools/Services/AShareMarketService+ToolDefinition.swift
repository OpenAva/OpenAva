import Foundation
import OpenClawKit
import OpenClawProtocol

extension AShareMarketService: ToolDefinitionProvider {
    nonisolated func toolDefinitions() -> [ToolDefinition] {
        [
            ToolDefinition(
                functionName: "a_share_market",
                command: "finance.a_share",
                description: "Get China A-share realtime quotes from Sina, with optional minute-level volume analysis for SH/SZ stocks.",
                parametersSchema: AnyCodable([
                    "type": "object",
                    "properties": [
                        "codes": [
                            "type": "array",
                            "items": ["type": "string"],
                            "minItems": 1,
                            "maxItems": 20,
                            "description": "Stock codes like ['600789','002446'] or codes with SH/SZ prefix.",
                        ],
                        "minute": [
                            "type": "boolean",
                            "description": "Include minute-level volume analysis.",
                        ],
                        "json": [
                            "type": "boolean",
                            "description": "Return raw JSON instead of formatted text.",
                        ],
                    ],
                    "required": ["codes"],
                    "additionalProperties": false,
                ] as [String: Any]),
                isReadOnly: true,
                isConcurrencySafe: true,
                maxResultSizeChars: 24 * 1024
            ),
        ]
    }

    func registerHandlers(into handlers: inout [String: ToolHandler]) {
        handlers["finance.a_share"] = { [weak self] request in
            guard let self else { throw NodeCapabilityRouter.RouterError.handlerUnavailable }
            return try await self.handleAShareMarketInvoke(request)
        }
    }

    private func handleAShareMarketInvoke(_ request: BridgeInvokeRequest) async throws -> BridgeInvokeResponse {
        struct AShareMarketParams: Decodable {
            var codes: [String]
            var minute: Bool?
            var json: Bool?
        }

        let params = try ToolInvocationHelpers.decodeParams(AShareMarketParams.self, from: request.paramsJSON)
        let normalizedCodes = params.codes
            .map(Self.cleanCode(_:))
            .filter { !$0.isEmpty }
        guard !normalizedCodes.isEmpty else {
            return ToolInvocationHelpers.invalidRequest(id: request.id, "codes must contain at least one stock code")
        }

        let includeMinute = params.minute ?? false
        let results = try await analyzeStocks(codes: normalizedCodes, includeMinute: includeMinute)

        if params.json ?? false {
            return try BridgeInvokeResponse(id: request.id, ok: true, payload: ToolInvocationHelpers.encodePayload(results))
        }

        var blocks: [String] = []
        for result in results {
            if let error = result.error {
                blocks.append("Error: \(error)")
                continue
            }
            guard let realtime = result.realtime else {
                blocks.append("Error: Failed to fetch market data for \(result.code)")
                continue
            }

            var text = Self.formatRealtime(realtime)
            if includeMinute {
                if let analysis = result.minuteAnalysis {
                    text += Self.formatMinuteAnalysis(analysis)
                } else if let minuteError = result.minuteError {
                    text += "\n\n[Minute Volume Analysis]\n  Error: \(minuteError)"
                }
            }
            blocks.append(text)
        }

        return BridgeInvokeResponse(id: request.id, ok: true, payload: blocks.joined(separator: "\n\n"))
    }
}
