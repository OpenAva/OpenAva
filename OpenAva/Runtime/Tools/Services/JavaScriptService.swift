import Foundation
import JavaScriptCore
import OpenClawKit
import OpenClawProtocol

enum JavaScriptServiceError: LocalizedError {
    case emptyCode
    case contextUnavailable
    case executionFailed(String)
    case toolNotAllowed(String)
    case sessionBusy(String)
    case timeout(Int)

    var errorDescription: String? {
        switch self {
        case .emptyCode:
            return "JavaScript code is empty"
        case .contextUnavailable:
            return "Failed to create JavaScript execution context"
        case let .executionFailed(message):
            return message
        case let .toolNotAllowed(functionName):
            return "Tool '\(functionName)' is not allowed in this JavaScript execution"
        case let .sessionBusy(sessionID):
            return "JavaScript session '\(sessionID)' is already executing another request"
        case let .timeout(timeoutMs):
            return "JavaScript execution timed out after \(timeoutMs)ms"
        }
    }
}

@MainActor
final class JavaScriptService {
    struct Request {
        let code: String
        let input: AnyCodable?
        let allowedTools: Set<String>
        let sessionID: String?
        let timeoutMs: Int
    }

    struct ConsoleEntry: Codable {
        let level: String
        let message: String
    }

    struct ToolCallEntry: Codable {
        let functionName: String
        let ok: Bool
        let preview: String?
        let errorMessage: String?
    }

    struct ExecutionPayload: Codable {
        let result: AnyCodable
        let logs: [ConsoleEntry]
        let toolCalls: [ToolCallEntry]
    }

    struct ToolBridgeError: Codable {
        let code: String
        let message: String
        let retryable: Bool?
        let retryAfterMs: Int?
    }

    private struct ToolBridgeValue: Codable {
        let ok: Bool
        let text: String?
        let payload: AnyCodable?
    }

    private struct ToolBridgeEnvelope: Codable {
        let ok: Bool
        let value: ToolBridgeValue?
        let error: ToolBridgeError?
    }

    private struct JavaScriptErrorPayload: Decodable {
        let name: String?
        let message: String?
        let stack: String?
    }

    private final class PersistentSessionState {
        let context: JSContext
        var lastUsedAt: Date
        var isExecuting: Bool

        init(context: JSContext, lastUsedAt: Date = Date(), isExecuting: Bool = false) {
            self.context = context
            self.lastUsedAt = lastUsedAt
            self.isExecuting = isExecuting
        }
    }

    private static let blockedFunctionNames: Set<String> = SubAgentDefinition.recursiveToolFunctionNames
        .union(["javascript_execute"])
    private static let persistentSessionIdleTimeout: TimeInterval = 10 * 60
    private static let maxPersistentSessionCount = 8

    static let defaultAllowedTools: Set<String> = SubAgentDefinition.readOnlyFunctionNames
        .subtracting(blockedFunctionNames)

    private var persistentSessions: [String: PersistentSessionState] = [:]

    /// Injected tool invoker for handling nested tool calls from JavaScript.
    /// Set by LocalToolInvokeService during initialization.
    var toolInvoker: (@Sendable (BridgeInvokeRequest) async -> BridgeInvokeResponse)?

    static func normalizedAllowedTools(from names: [String]?) -> Set<String> {
        guard let names else {
            return defaultAllowedTools
        }

        return Set(
            names
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .filter { !blockedFunctionNames.contains($0) }
        )
    }

    static func clampedTimeoutMs(_ value: Int?) -> Int {
        let fallback = 15000
        guard let value else { return fallback }
        return max(100, min(value, 120_000))
    }

    private static let bootstrapJavaScript = #"""
    (() => {
      const hostSerialize = (value) => {
        if (value === undefined) {
          return "null";
        }

        const seen = new WeakSet();
        return JSON.stringify(value, (_key, current) => {
          if (typeof current === "bigint") {
            return current.toString();
          }
          if (typeof current === "function") {
            return `[Function ${current.name || "anonymous"}]`;
          }
          if (typeof current === "object" && current !== null) {
            if (seen.has(current)) {
              return "[Circular]";
            }
            seen.add(current);
          }
          return current;
        });
      };

      const renderForLog = (value) => {
        if (typeof value === "string") {
          return value;
        }
        return hostSerialize(value);
      };

      const pendingToolCalls = new Map();
      globalThis.__openavaBridgeResolve = (requestID, responseJSON) => {
        const pending = pendingToolCalls.get(requestID);
        if (!pending) {
          return;
        }

        pendingToolCalls.delete(requestID);
        const response = JSON.parse(responseJSON);
        if (response && response.ok) {
          pending.resolve(response.value ?? null);
          return;
        }

        pending.reject(response && response.error ? response.error : { message: "Tool execution failed" });
      };

      const logToHost = (level, args) => {
        const message = args.map(renderForLog).join(" ");
        globalThis.__openavaLog(level, message);
      };

      globalThis.console = Object.freeze({
        log: (...args) => logToHost("log", args),
        info: (...args) => logToHost("info", args),
        warn: (...args) => logToHost("warn", args),
        error: (...args) => logToHost("error", args),
      });

      const input = JSON.parse(globalThis.__openavaInputJSON ?? "null");
      const session = (typeof globalThis.__openavaPersistentSession === "object" && globalThis.__openavaPersistentSession !== null)
        ? globalThis.__openavaPersistentSession
        : Object.create(null);
      globalThis.__openavaPersistentSession = session;

      globalThis.openava = Object.freeze({
        input,
        session,
        tools: Object.freeze({
          call(name, args = {}) {
            return new Promise((resolve, reject) => {
              if (typeof name !== "string" || name.trim().length === 0) {
                reject({ message: "Tool name must be a non-empty string" });
                return;
              }

              if (args == null) {
                args = {};
              }
              if (typeof args !== "object" || Array.isArray(args)) {
                reject({ message: "Tool arguments must be an object" });
                return;
              }

              const requestID = `${Date.now()}-${Math.random().toString(16).slice(2)}`;
              pendingToolCalls.set(requestID, { resolve, reject });

              try {
                const argsJSON = hostSerialize(args);
                globalThis.__openavaCallTool(name.trim(), argsJSON === undefined ? "{}" : argsJSON, requestID);
              } catch (error) {
                pendingToolCalls.delete(requestID);
                reject(error instanceof Error ? {
                  name: error.name,
                  message: error.message,
                  stack: error.stack ?? null,
                } : {
                  message: String(error),
                });
              }
            });
          },
        }),
      });

      globalThis.__openavaSerialize = hostSerialize;
      globalThis.__openavaSerializeError = (error) => {
        if (error instanceof Error) {
          return hostSerialize({
            name: error.name || "Error",
            message: error.message || String(error),
            stack: typeof error.stack === "string" ? error.stack : null,
          });
        }

        return hostSerialize({
          message: typeof error === "string" ? error : String(error),
        });
      };
    })();
    """#

    func execute(
        request: Request,
        invokeTool: @escaping @Sendable (_ functionName: String, _ argumentsJSON: String?) async -> BridgeInvokeResponse
    ) async throws -> ExecutionPayload {
        let trimmedCode = request.code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCode.isEmpty else {
            throw JavaScriptServiceError.emptyCode
        }

        if let sessionID = Self.normalizedPersistentSessionID(request.sessionID) {
            let state = try persistentSessionState(for: sessionID)
            guard !state.isExecuting else {
                throw JavaScriptServiceError.sessionBusy(sessionID)
            }

            state.isExecuting = true
            state.lastUsedAt = Date()
            defer {
                state.isExecuting = false
                state.lastUsedAt = Date()
                cleanupPersistentSessions(referenceDate: Date())
            }

            do {
                return try await executeWithTimeout(
                    request: request,
                    context: state.context,
                    invokeTool: invokeTool
                )
            } catch let error as JavaScriptServiceError {
                if case .timeout = error {
                    removePersistentSession(for: sessionID)
                }
                throw error
            } catch {
                throw error
            }
        }

        guard let context = JSContext() else {
            throw JavaScriptServiceError.contextUnavailable
        }

        return try await executeWithTimeout(
            request: request,
            context: context,
            invokeTool: invokeTool
        )
    }

    private func executeWithTimeout(
        request: Request,
        context: JSContext,
        invokeTool: @escaping @Sendable (_ functionName: String, _ argumentsJSON: String?) async -> BridgeInvokeResponse
    ) async throws -> ExecutionPayload {
        return try await withThrowingTaskGroup(of: ExecutionPayload.self) { group in
            group.addTask { @MainActor in
                try await self.executeWithoutTimeout(request: request, context: context, invokeTool: invokeTool)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(request.timeoutMs) * 1_000_000)
                throw JavaScriptServiceError.timeout(request.timeoutMs)
            }

            guard let result = try await group.next() else {
                throw JavaScriptServiceError.executionFailed("JavaScript execution did not produce a result")
            }
            group.cancelAll()
            return result
        }
    }

    private func executeWithoutTimeout(
        request: Request,
        context: JSContext,
        invokeTool: @escaping @Sendable (_ functionName: String, _ argumentsJSON: String?) async -> BridgeInvokeResponse
    ) async throws -> ExecutionPayload {
        let session = JavaScriptExecutionSession(context: context)
        context.exceptionHandler = { [weak session] _, exception in
            guard let session else { return }
            session.finishFailure(message: Self.describeJavaScriptException(exception))
        }

        let logBlock: @convention(block) (String, String) -> Void = { [weak session] level, message in
            session?.recordLog(level: level, message: message)
        }
        context.setObject(unsafeBitCast(logBlock, to: AnyObject.self), forKeyedSubscript: "__openavaLog" as NSString)

        let completeBlock: @convention(block) (Bool, String) -> Void = { [weak session] ok, payloadJSON in
            guard let session else { return }
            if ok {
                session.finishSuccess(resultJSON: payloadJSON)
            } else {
                session.finishFailure(errorJSON: payloadJSON)
            }
        }
        context.setObject(unsafeBitCast(completeBlock, to: AnyObject.self), forKeyedSubscript: "__openavaComplete" as NSString)

        let callToolBlock: @convention(block) (String, String, String) -> Void = { [weak session] functionName, argumentsJSON, requestID in
            guard let session else { return }
            Task { @MainActor in
                let envelopeJSON = await self.invokeToolFromJavaScript(
                    functionName: functionName,
                    argumentsJSON: argumentsJSON,
                    allowedTools: request.allowedTools,
                    session: session,
                    invokeTool: invokeTool
                )
                session.deliverToolResponse(requestID: requestID, envelopeJSON: envelopeJSON)
            }
        }
        context.setObject(unsafeBitCast(callToolBlock, to: AnyObject.self), forKeyedSubscript: "__openavaCallTool" as NSString)

        let inputJSON = try Self.jsonString(from: request.input ?? AnyCodable(NSNull()))
        context.setObject(inputJSON, forKeyedSubscript: "__openavaInputJSON" as NSString)

        _ = context.evaluateScript(Self.bootstrapJavaScript)
        if let exception = context.exception {
            context.exception = nil
            throw JavaScriptServiceError.executionFailed(Self.describeJavaScriptException(exception))
        }

        let wrappedCode = Self.wrappedExecutionJavaScript(for: request.code)
        _ = context.evaluateScript(wrappedCode)
        if let exception = context.exception {
            context.exception = nil
            throw JavaScriptServiceError.executionFailed(Self.describeJavaScriptException(exception))
        }

        return try await session.waitForCompletion()
    }

    private func invokeToolFromJavaScript(
        functionName: String,
        argumentsJSON: String?,
        allowedTools: Set<String>,
        session: JavaScriptExecutionSession,
        invokeTool: @escaping @Sendable (_ functionName: String, _ argumentsJSON: String?) async -> BridgeInvokeResponse
    ) async -> String {
        let trimmedFunctionName = functionName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedFunctionName.isEmpty else {
            let envelope = ToolBridgeEnvelope(
                ok: false,
                value: nil,
                error: ToolBridgeError(code: OpenClawNodeErrorCode.invalidRequest.rawValue, message: "INVALID_REQUEST: tool name is required", retryable: nil, retryAfterMs: nil)
            )
            return Self.encodedToolBridgeEnvelope(envelope)
        }

        guard !Self.blockedFunctionNames.contains(trimmedFunctionName) else {
            session.recordToolCall(functionName: trimmedFunctionName, ok: false, preview: nil, errorMessage: "UNAVAILABLE: recursive JavaScript/sub-agent tool calls are blocked")
            let envelope = ToolBridgeEnvelope(
                ok: false,
                value: nil,
                error: ToolBridgeError(code: OpenClawNodeErrorCode.unavailable.rawValue, message: "UNAVAILABLE: recursive JavaScript/sub-agent tool calls are blocked", retryable: nil, retryAfterMs: nil)
            )
            return Self.encodedToolBridgeEnvelope(envelope)
        }

        guard allowedTools.contains(trimmedFunctionName) else {
            let message = JavaScriptServiceError.toolNotAllowed(trimmedFunctionName).localizedDescription
            session.recordToolCall(functionName: trimmedFunctionName, ok: false, preview: nil, errorMessage: message)
            let envelope = ToolBridgeEnvelope(
                ok: false,
                value: nil,
                error: ToolBridgeError(code: OpenClawNodeErrorCode.unauthorized.rawValue, message: message, retryable: nil, retryAfterMs: nil)
            )
            return Self.encodedToolBridgeEnvelope(envelope)
        }

        let response = await invokeTool(trimmedFunctionName, argumentsJSON)
        let error = response.error.map {
            ToolBridgeError(
                code: $0.code.rawValue,
                message: $0.message,
                retryable: $0.retryable,
                retryAfterMs: $0.retryAfterMs
            )
        }
        session.recordToolCall(
            functionName: trimmedFunctionName,
            ok: response.ok,
            preview: Self.previewText(response.payload),
            errorMessage: error?.message
        )

        if response.ok {
            let envelope = ToolBridgeEnvelope(
                ok: true,
                value: ToolBridgeValue(
                    ok: true,
                    text: response.payload,
                    payload: Self.anyPayloadValue(from: response.payload)
                ),
                error: nil
            )
            return Self.encodedToolBridgeEnvelope(envelope)
        }

        let envelope = ToolBridgeEnvelope(
            ok: false,
            value: nil,
            error: error ?? ToolBridgeError(code: OpenClawNodeErrorCode.unavailable.rawValue, message: "Tool execution failed.", retryable: nil, retryAfterMs: nil)
        )
        return Self.encodedToolBridgeEnvelope(envelope)
    }

    private static func wrappedExecutionJavaScript(for code: String) -> String {
        """
        (async () => {
        \(code)
        })()
        .then(value => globalThis.__openavaComplete(true, globalThis.__openavaSerialize(value)))
        .catch(error => globalThis.__openavaComplete(false, globalThis.__openavaSerializeError(error)));
        """
    }

    fileprivate static func describeJavaScriptException(_ exception: JSValue?) -> String {
        guard let exception else {
            return "JavaScript execution failed"
        }

        if let message = exception.forProperty("message")?.toString(), !message.isEmpty {
            let name = exception.forProperty("name")?.toString() ?? "Error"
            let stack = exception.forProperty("stack")?.toString()
            if let stack, !stack.isEmpty {
                return "\(name): \(message)\n\(stack)"
            }
            return "\(name): \(message)"
        }

        return exception.toString() ?? "JavaScript execution failed"
    }

    private static func jsonString(from value: AnyCodable) throws -> String {
        let data = try JSONEncoder().encode(value)
        guard let json = String(data: data, encoding: .utf8) else {
            throw JavaScriptServiceError.executionFailed("Failed to encode JavaScript payload as UTF-8")
        }
        return json
    }

    private static func normalizedPersistentSessionID(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func persistentSessionState(for sessionID: String) throws -> PersistentSessionState {
        let now = Date()
        cleanupPersistentSessions(referenceDate: now)

        if let existing = persistentSessions[sessionID] {
            existing.lastUsedAt = now
            return existing
        }

        guard let context = JSContext() else {
            throw JavaScriptServiceError.contextUnavailable
        }

        let state = PersistentSessionState(context: context, lastUsedAt: now)
        persistentSessions[sessionID] = state
        cleanupPersistentSessions(referenceDate: now)
        return state
    }

    private func removePersistentSession(for sessionID: String) {
        persistentSessions.removeValue(forKey: sessionID)
    }

    private func cleanupPersistentSessions(referenceDate: Date) {
        let expirationDate = referenceDate.addingTimeInterval(-Self.persistentSessionIdleTimeout)
        let expiredIDs = persistentSessions.compactMap { entry -> String? in
            let (sessionID, state) = entry
            guard !state.isExecuting, state.lastUsedAt < expirationDate else {
                return nil
            }
            return sessionID
        }

        for sessionID in expiredIDs {
            persistentSessions.removeValue(forKey: sessionID)
        }

        let removableSessions = persistentSessions
            .filter { !$0.value.isExecuting }
            .sorted { $0.value.lastUsedAt < $1.value.lastUsedAt }

        guard removableSessions.count > Self.maxPersistentSessionCount else {
            return
        }

        for (sessionID, _) in removableSessions.prefix(removableSessions.count - Self.maxPersistentSessionCount) {
            persistentSessions.removeValue(forKey: sessionID)
        }
    }

    private static func anyPayloadValue(from payload: String?) -> AnyCodable? {
        guard let payload else {
            return nil
        }
        guard let data = payload.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(AnyCodable.self, from: data)
        else {
            return AnyCodable(payload)
        }
        return decoded
    }

    private static func previewText(_ text: String?, limit: Int = 240) -> String? {
        guard let text else { return nil }
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "..."
    }

    private static func encodedToolBridgeEnvelope(_ envelope: ToolBridgeEnvelope) -> String {
        do {
            let data = try JSONEncoder().encode(envelope)
            if let json = String(data: data, encoding: .utf8) {
                return json
            }
        } catch {}

        return #"{"ok":false,"error":{"code":"UNAVAILABLE","message":"Failed to encode tool bridge response"}}"#
    }

    fileprivate static func executionPayload(from resultJSON: String, logs: [ConsoleEntry], toolCalls: [ToolCallEntry]) -> ExecutionPayload {
        let result: AnyCodable
        if let data = resultJSON.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(AnyCodable.self, from: data)
        {
            result = decoded
        } else {
            result = AnyCodable(resultJSON)
        }

        return ExecutionPayload(result: result, logs: logs, toolCalls: toolCalls)
    }

    fileprivate static func executionErrorMessage(from errorJSON: String) -> String {
        guard let data = errorJSON.data(using: .utf8),
              let payload = try? JSONDecoder().decode(JavaScriptErrorPayload.self, from: data)
        else {
            return errorJSON
        }

        let message = payload.message?.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = payload.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let stack = payload.stack?.trimmingCharacters(in: .whitespacesAndNewlines)

        let headline: String
        if let name, !name.isEmpty, let message, !message.isEmpty {
            headline = "\(name): \(message)"
        } else if let message, !message.isEmpty {
            headline = message
        } else if let name, !name.isEmpty {
            headline = name
        } else {
            headline = "JavaScript execution failed"
        }

        if let stack, !stack.isEmpty {
            return "\(headline)\n\(stack)"
        }
        return headline
    }
}

@MainActor
private final class JavaScriptExecutionSession {
    private let context: JSContext
    private let latch = JavaScriptExecutionLatch()

    private(set) var logs: [JavaScriptService.ConsoleEntry] = []
    private(set) var toolCalls: [JavaScriptService.ToolCallEntry] = []

    init(context: JSContext) {
        self.context = context
    }

    func waitForCompletion() async throws -> JavaScriptService.ExecutionPayload {
        try await latch.wait()
    }

    func recordLog(level: String, message: String) {
        logs.append(.init(level: level, message: message))
    }

    func recordToolCall(functionName: String, ok: Bool, preview: String?, errorMessage: String?) {
        toolCalls.append(.init(functionName: functionName, ok: ok, preview: preview, errorMessage: errorMessage))
    }

    func deliverToolResponse(requestID: String, envelopeJSON: String) {
        let requestIDLiteral = JavaScriptExecutionSession.javaScriptStringLiteral(requestID)
        let envelopeLiteral = JavaScriptExecutionSession.javaScriptStringLiteral(envelopeJSON)
        _ = context.evaluateScript("globalThis.__openavaBridgeResolve(\(requestIDLiteral), \(envelopeLiteral));")
        if let exception = context.exception {
            context.exception = nil
            finishFailure(message: JavaScriptService.describeJavaScriptException(exception))
        }
    }

    func finishSuccess(resultJSON: String) {
        latch.resume(returning: JavaScriptService.executionPayload(from: resultJSON, logs: logs, toolCalls: toolCalls))
    }

    func finishFailure(errorJSON: String) {
        finishFailure(message: JavaScriptService.executionErrorMessage(from: errorJSON))
    }

    func finishFailure(message: String) {
        latch.resume(throwing: JavaScriptServiceError.executionFailed(message))
    }

    private static func javaScriptStringLiteral(_ text: String) -> String {
        let data = try? JSONEncoder().encode(text)
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
    }
}

@MainActor
private final class JavaScriptExecutionLatch {
    private enum StoredResult {
        case success(JavaScriptService.ExecutionPayload)
        case failure(Error)
    }

    private var continuation: CheckedContinuation<JavaScriptService.ExecutionPayload, Error>?
    private var storedResult: StoredResult?
    private var completed = false

    func wait() async throws -> JavaScriptService.ExecutionPayload {
        if let storedResult {
            return try consume(storedResult)
        }

        return try await withCheckedThrowingContinuation { continuation in
            if let storedResult {
                continuation.resume(with: Result { try self.consume(storedResult) })
                return
            }
            self.continuation = continuation
        }
    }

    func resume(returning payload: JavaScriptService.ExecutionPayload) {
        guard !completed else { return }
        completed = true
        if let continuation {
            self.continuation = nil
            continuation.resume(returning: payload)
        } else {
            storedResult = .success(payload)
        }
    }

    func resume(throwing error: Error) {
        guard !completed else { return }
        completed = true
        if let continuation {
            self.continuation = nil
            continuation.resume(throwing: error)
        } else {
            storedResult = .failure(error)
        }
    }

    private func consume(_ result: StoredResult) throws -> JavaScriptService.ExecutionPayload {
        storedResult = nil
        switch result {
        case let .success(payload):
            return payload
        case let .failure(error):
            throw error
        }
    }
}
