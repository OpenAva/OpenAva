import Foundation
import OpenClawKit
import OpenClawProtocol

extension JavaScriptService: ToolDefinitionProvider {
    func toolDefinitions() -> [ToolDefinition] {
        [
            ToolDefinition(
                functionName: "javascript_execute",
                command: "javascript.execute",
                description: "Execute JavaScript with Apple system JavaScriptCore. The code runs as the body of an async function and can use openava.input, openava.session, and await openava.tools.call(functionName, args) for allowed tools.",
                parametersSchema: AnyCodable([
                    "type": "object",
                    "properties": [
                        "code": [
                            "type": "string",
                            "description": "JavaScript source code executed as the body of an async function. Use return to produce the final result.",
                        ],
                        "input": [
                            "description": "Optional JSON-serializable value exposed as openava.input in the JavaScript runtime.",
                        ],
                        "allowed_tools": [
                            "type": "array",
                            "description": "Optional allowlist of tool function names callable from JavaScript. Defaults to built-in read-only tools.",
                            "items": [
                                "type": "string",
                            ],
                        ],
                        "session_id": [
                            "type": "string",
                            "description": "Optional persistent JavaScript session id. When provided, later calls with the same id reuse the same JS context, preserving variables, functions, and openava.session state.",
                        ],
                        "timeout_ms": [
                            "type": "integer",
                            "description": "Best-effort execution timeout in milliseconds (default: 15000, max: 120000).",
                        ],
                    ],
                    "required": ["code"],
                    "additionalProperties": false,
                ] as [String: Any])
            ),
        ]
    }

    func registerHandlers(into handlers: inout [String: ToolHandler]) {
        handlers["javascript.execute"] = { [weak self] request in
            guard let self else { throw ToolHandlerError.handlerUnavailable }
            return try await self.handleJavaScriptInvoke(request)
        }
    }

    private func handleJavaScriptInvoke(_ request: BridgeInvokeRequest) async throws -> BridgeInvokeResponse {
        struct Params: Decodable {
            let code: String
            let input: AnyCodable?
            let allowedTools: [String]?
            let sessionID: String?
            let timeoutMs: Int?

            enum CodingKeys: String, CodingKey {
                case code
                case input
                case allowedTools = "allowed_tools"
                case sessionID = "session_id"
                case timeoutMs = "timeout_ms"
            }
        }

        let params = try ToolInvocationHelpers.decodeParams(Params.self, from: request.paramsJSON)
        let sessionID = ToolRuntime.InvocationContext.sessionID
        let allowedTools = Self.normalizedAllowedTools(from: params.allowedTools)
        let timeoutMs = Self.clampedTimeoutMs(params.timeoutMs)

        let payload = try await execute(
            request: .init(
                code: params.code,
                input: params.input,
                allowedTools: allowedTools,
                sessionID: params.sessionID,
                timeoutMs: timeoutMs
            )
        ) { [weak self] functionName, argumentsJSON in
            // Use the injected tool invoker if available, otherwise return an error
            guard let invoker = await self?.toolInvoker else {
                return BridgeInvokeResponse(
                    id: UUID().uuidString,
                    ok: false,
                    error: OpenClawNodeError(code: .unavailable, message: "UNAVAILABLE: local tool handler unavailable")
                )
            }

            guard let nestedRequest = await ToolRegistry.shared.request(
                id: UUID().uuidString,
                forFunctionName: functionName,
                argumentsJSON: argumentsJSON
            ) else {
                return BridgeInvokeResponse(
                    id: UUID().uuidString,
                    ok: false,
                    error: OpenClawNodeError(code: .invalidRequest, message: "INVALID_REQUEST: unknown tool function '\(functionName)'")
                )
            }

            return await invoker(nestedRequest)
        }

        return try BridgeInvokeResponse(
            id: request.id,
            ok: true,
            payload: ToolInvocationHelpers.encodePayload(payload)
        )
    }
}
