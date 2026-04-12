import Foundation
import OpenClawKit
import OpenClawProtocol

private struct JavaScriptExecuteParams: Decodable {
    let code: String?
    let scriptPath: String?
    let input: AnyCodable?
    let allowedTools: [String]?
    let sessionID: String?
    let timeoutMs: Int?

    enum CodingKeys: String, CodingKey {
        case code
        case scriptPath = "script_path"
        case input
        case allowedTools = "allowed_tools"
        case sessionID = "session_id"
        case timeoutMs = "timeout_ms"
    }
}

extension JavaScriptService: ToolDefinitionProvider {
    func toolDefinitions() -> [ToolDefinition] {
        [
            ToolDefinition(
                functionName: "javascript_execute",
                command: "javascript.execute",
                description: "Execute JavaScript with Apple system JavaScriptCore. Provide either inline code or a script path. The code runs as the body of an async function and can use openava.input, openava.session, and await openava.tools.call(functionName, args) for allowed tools.",
                parametersSchema: AnyCodable([
                    "type": "object",
                    "properties": [
                        "code": [
                            "type": "string",
                            "description": "Optional JavaScript source code executed as the body of an async function. Use return to produce the final result. Mutually exclusive with script_path.",
                        ],
                        "script_path": [
                            "type": "string",
                            "description": "Optional workspace-relative or absolute script file path to execute. Mutually exclusive with code.",
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
                    "oneOf": [
                        ["required": ["code"]],
                        ["required": ["script_path"]],
                    ],
                    "additionalProperties": false,
                ] as [String: Any])
            ),
        ]
    }

    func registerHandlers(
        into handlers: inout [String: ToolHandler],
        context: ToolHandlerRegistrationContext
    ) {
        let workspaceRootURL = context.workspaceRootURL?.standardizedFileURL
        handlers["javascript.execute"] = { [weak self] request in
            guard let self else { throw ToolHandlerError.handlerUnavailable }
            return try await self.handleJavaScriptInvoke(request, workspaceRootURL: workspaceRootURL)
        }
    }

    private func handleJavaScriptInvoke(
        _ request: BridgeInvokeRequest,
        workspaceRootURL: URL?
    ) async throws -> BridgeInvokeResponse {
        let params = try ToolInvocationHelpers.decodeParams(JavaScriptExecuteParams.self, from: request.paramsJSON)
        let source: ResolvedJavaScriptSource
        do {
            source = try Self.resolveSource(for: params, workspaceRootURL: workspaceRootURL)
        } catch let error as JavaScriptSourceRequestError {
            switch error {
            case let .invalidRequest(message):
                return ToolInvocationHelpers.invalidRequest(id: request.id, message)
            case let .unavailable(message):
                return ToolInvocationHelpers.unavailableResponse(id: request.id, "UNAVAILABLE: \(message)")
            }
        }

        let allowedTools = Self.normalizedAllowedTools(from: params.allowedTools)
        let timeoutMs = Self.clampedTimeoutMs(params.timeoutMs)

        let payload = try await execute(
            request: .init(
                code: source.code,
                sourceURL: source.sourceURL,
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

    private struct ResolvedJavaScriptSource {
        let code: String
        let sourceURL: URL?
    }

    private static func resolveSource(
        for params: JavaScriptExecuteParams,
        workspaceRootURL: URL?
    ) throws -> ResolvedJavaScriptSource {
        let inlineCode = params.code
        let trimmedScriptPath = params.scriptPath?.trimmingCharacters(in: .whitespacesAndNewlines)

        let hasInlineCode = inlineCode?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let hasScriptPath = trimmedScriptPath?.isEmpty == false

        switch (hasInlineCode, hasScriptPath) {
        case (true, true):
            throw JavaScriptSourceRequestError.invalidRequest("provide exactly one of code or script_path")
        case (false, false):
            throw JavaScriptSourceRequestError.invalidRequest("either code or script_path is required")
        case (true, false):
            return .init(code: inlineCode ?? "", sourceURL: nil)
        case (false, true):
            guard let workspaceRootURL else {
                throw JavaScriptSourceRequestError.unavailable("javascript script execution requires an active workspace")
            }
            guard let scriptPath = trimmedScriptPath else {
                throw JavaScriptSourceRequestError.invalidRequest("script_path must be a non-empty string")
            }

            do {
                let scriptURL = try resolveScriptURL(path: scriptPath, workspaceRootURL: workspaceRootURL)
                let code = try normalizedScriptCode(at: scriptURL)
                return .init(code: code, sourceURL: scriptURL)
            } catch let error as JavaScriptSourceResolutionError {
                throw JavaScriptSourceRequestError.invalidRequest(error.localizedDescription)
            } catch {
                throw JavaScriptSourceRequestError.unavailable(error.localizedDescription)
            }
        }
    }

    private static func resolveScriptURL(path: String, workspaceRootURL: URL) throws -> URL {
        let workspaceURL = workspaceRootURL.standardizedFileURL
        let scriptURL: URL
        if path.hasPrefix("/") {
            scriptURL = URL(fileURLWithPath: path).standardizedFileURL
        } else {
            scriptURL = workspaceURL.appendingPathComponent(path).standardizedFileURL
        }

        let workspacePath = workspaceURL.path
        let scriptPath = scriptURL.path
        let isWithinWorkspace = scriptPath == workspacePath || scriptPath.hasPrefix(workspacePath + "/")
        guard isWithinWorkspace else {
            throw JavaScriptSourceResolutionError.outsideWorkspace(path)
        }

        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: scriptURL.path, isDirectory: &isDirectory) else {
            throw JavaScriptSourceResolutionError.fileNotFound(path)
        }
        guard !isDirectory.boolValue else {
            throw JavaScriptSourceResolutionError.directoryNotSupported(path)
        }

        return scriptURL
    }

    private static func normalizedScriptCode(at url: URL) throws -> String {
        let raw = try String(contentsOf: url, encoding: .utf8)
        guard raw.hasPrefix("#!") else {
            return raw
        }

        guard let newline = raw.firstIndex(of: "\n") else {
            return ""
        }
        return String(raw[raw.index(after: newline)...])
    }
}

private enum JavaScriptSourceResolutionError: LocalizedError {
    case fileNotFound(String)
    case outsideWorkspace(String)
    case directoryNotSupported(String)

    var errorDescription: String? {
        switch self {
        case let .fileNotFound(path):
            return "script file not found at '\(path)'"
        case let .outsideWorkspace(path):
            return "script_path must stay within the active workspace: '\(path)'"
        case let .directoryNotSupported(path):
            return "script_path must reference a file, not a directory: '\(path)'"
        }
    }
}

private enum JavaScriptSourceRequestError: Error {
    case invalidRequest(String)
    case unavailable(String)
}
