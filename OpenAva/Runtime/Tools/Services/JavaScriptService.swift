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
        let sourceURL: URL?
        let workspaceRootURL: URL?
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

    private struct CommonJSModuleDescriptor: Codable {
        let filename: String
        let dirname: String
        let code: String
    }

    private struct CommonJSModuleEnvelope: Codable {
        let ok: Bool
        let value: CommonJSModuleDescriptor?
        let error: ToolBridgeError?
    }

    private struct ExecutionEntry {
        let filename: String
        let dirname: String
        let sourceURL: URL?
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
    private static let inlineEntryFilename = "__openava_inline__.js"

    static let defaultAllowedTools: Set<String> = SubAgentDefinition.readOnlyFunctionNames
        .subtracting(blockedFunctionNames)

    private var persistentSessions: [String: PersistentSessionState] = [:]

    /// Injected tool invoker for handling nested tool calls from JavaScript.
    /// Set by ToolRuntime during initialization.
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

      const workspaceRoot = typeof globalThis.__openavaWorkspaceRoot === "string" && globalThis.__openavaWorkspaceRoot.length > 0
        ? globalThis.__openavaWorkspaceRoot
        : null;
      const entryFilename = typeof globalThis.__openavaEntryFilename === "string" && globalThis.__openavaEntryFilename.length > 0
        ? globalThis.__openavaEntryFilename
        : null;
      const entryDirname = typeof globalThis.__openavaEntryDirname === "string" && globalThis.__openavaEntryDirname.length > 0
        ? globalThis.__openavaEntryDirname
        : null;

      const moduleCache = (typeof globalThis.__openavaModuleCache === "object" && globalThis.__openavaModuleCache !== null)
        ? globalThis.__openavaModuleCache
        : Object.create(null);
      globalThis.__openavaModuleCache = moduleCache;

      const restoreGlobal = (key, previousValue) => {
        if (previousValue === undefined) {
          delete globalThis[key];
        } else {
          globalThis[key] = previousValue;
        }
      };

      const parseModuleEnvelope = (envelopeJSON) => {
        let envelope;
        try {
          envelope = JSON.parse(envelopeJSON);
        } catch (_error) {
          throw new Error("Failed to parse CommonJS module metadata");
        }

        if (envelope && envelope.ok && envelope.value) {
          return envelope.value;
        }

        throw new Error(envelope && envelope.error && envelope.error.message
          ? envelope.error.message
          : "Failed to load CommonJS module");
      };

      const processObject = {
        argv: entryFilename ? ["openava", entryFilename] : ["openava"],
        env: Object.create(null),
        platform: "darwin",
        versions: Object.freeze({
          openava: "1",
          javascriptcore: "JavaScriptCore",
        }),
        cwd() {
          return workspaceRoot ?? entryDirname ?? "";
        },
        exit(code = 0) {
          throw new Error(`process.exit(${code}) is not supported in OpenAva JavaScript runtime`);
        },
      };
      globalThis.process = processObject;

      const builtInModules = Object.create(null);
      const createPathModule = () => {
        const assertPathString = (value, name = "path") => {
          if (typeof value !== "string") {
            throw new TypeError(`${name} must be a string`);
          }
          return value;
        };

        const slashNormalized = (value) => assertPathString(value).replace(/\\/g, "/");
        const normalize = (value) => {
          const input = slashNormalized(value);
          if (input.length === 0) {
            return ".";
          }

          const isAbsolute = input.startsWith("/");
          const segments = input.split("/");
          const output = [];

          for (const segment of segments) {
            if (!segment || segment === ".") {
              continue;
            }
            if (segment === "..") {
              if (output.length > 0 && output[output.length - 1] !== "..") {
                output.pop();
              } else if (!isAbsolute) {
                output.push("..");
              }
            } else {
              output.push(segment);
            }
          }

          let normalized = `${isAbsolute ? "/" : ""}${output.join("/")}`;
          if (!normalized) {
            normalized = isAbsolute ? "/" : ".";
          }
          return normalized;
        };

        const dirname = (value) => {
          const normalized = normalize(value);
          if (normalized === "/") {
            return "/";
          }
          if (normalized === ".") {
            return ".";
          }
          const trimmed = normalized.endsWith("/") && normalized.length > 1
            ? normalized.slice(0, -1)
            : normalized;
          const index = trimmed.lastIndexOf("/");
          if (index < 0) {
            return ".";
          }
          if (index === 0) {
            return "/";
          }
          return trimmed.slice(0, index);
        };

        const basename = (value, suffix) => {
          const input = slashNormalized(value);
          const trimmed = input.endsWith("/") && input.length > 1
            ? input.slice(0, -1)
            : input;
          const index = trimmed.lastIndexOf("/");
          let base = index >= 0 ? trimmed.slice(index + 1) : trimmed;
          if (typeof suffix === "string" && suffix.length > 0 && base.endsWith(suffix) && base !== suffix) {
            base = base.slice(0, -suffix.length);
          }
          return base;
        };

        const extname = (value) => {
          const base = basename(value);
          if (base === "." || base === "..") {
            return "";
          }
          const index = base.lastIndexOf(".");
          return index <= 0 ? "" : base.slice(index);
        };

        const isAbsolute = (value) => slashNormalized(value).startsWith("/");
        const join = (...parts) => {
          if (parts.length === 0) {
            return ".";
          }
          const filtered = parts
            .map((part, index) => assertPathString(part, `path segment ${index}`))
            .filter(part => part.length > 0);
          if (filtered.length === 0) {
            return ".";
          }
          return normalize(filtered.join("/"));
        };

        const resolve = (...parts) => {
          const inputs = parts.map((part, index) => assertPathString(part, `path segment ${index}`));
          let resolved = "";
          let resolvedFromAbsolute = false;

          for (let index = inputs.length - 1; index >= 0; index -= 1) {
            const source = inputs[index];
            const segment = slashNormalized(source);
            if (!segment) {
              continue;
            }
            resolved = `${segment}/${resolved}`;
            if (segment.startsWith("/")) {
              resolvedFromAbsolute = true;
              break;
            }
          }

          if (!resolvedFromAbsolute) {
            const cwd = slashNormalized(processObject.cwd());
            resolved = `${cwd}/${resolved}`;
          }

          const normalized = normalize(resolved);
          return normalized.startsWith("/") ? normalized : `/${normalized}`;
        };

        const api = {
          sep: "/",
          delimiter: ":",
          normalize,
          dirname,
          basename,
          extname,
          isAbsolute,
          join,
          resolve,
        };
        api.posix = api;
        return Object.freeze(api);
      };

      const pathModule = createPathModule();
      builtInModules.path = pathModule;
      builtInModules["node:path"] = pathModule;
      moduleCache["__openava_builtin__/path"] = {
        id: "__openava_builtin__/path",
        filename: "__openava_builtin__/path",
        loaded: true,
        exports: pathModule,
      };

      const makeRequire = (parentFilename) => {
        const require = (specifier) => {
          if (typeof specifier !== "string" || specifier.trim().length === 0) {
            throw new Error("require() specifier must be a non-empty string");
          }
          const normalizedSpecifier = specifier.trim();
          if (Object.prototype.hasOwnProperty.call(builtInModules, normalizedSpecifier)) {
            return builtInModules[normalizedSpecifier];
          }
          if (typeof globalThis.__openavaLoadCommonJSModule !== "function") {
            throw new Error("require() is unavailable in this JavaScript execution");
          }

          const descriptor = parseModuleEnvelope(
            globalThis.__openavaLoadCommonJSModule(normalizedSpecifier, typeof parentFilename === "string" ? parentFilename : "")
          );
          if (moduleCache[descriptor.filename]) {
            return moduleCache[descriptor.filename].exports;
          }

          const module = {
            id: descriptor.filename,
            filename: descriptor.filename,
            loaded: false,
            exports: {},
          };
          const localRequire = makeRequire(descriptor.filename);
          module.require = localRequire;
          moduleCache[descriptor.filename] = module;

          const previousModule = globalThis.module;
          const previousExports = globalThis.exports;
          const previousFilename = globalThis.__filename;
          const previousDirname = globalThis.__dirname;
          const previousRequire = globalThis.require;

          try {
            globalThis.module = module;
            globalThis.exports = module.exports;
            globalThis.__filename = descriptor.filename;
            globalThis.__dirname = descriptor.dirname;
            globalThis.require = localRequire;

            const factory = globalThis.eval(
              "(function (exports, require, module, __filename, __dirname, process) {\n"
              + descriptor.code
              + "\n})\n//# sourceURL="
              + descriptor.filename
            );
            factory(module.exports, localRequire, module, descriptor.filename, descriptor.dirname, globalThis.process);
            module.loaded = true;
            return module.exports;
          } catch (error) {
            delete moduleCache[descriptor.filename];
            throw error;
          } finally {
            restoreGlobal("module", previousModule);
            restoreGlobal("exports", previousExports);
            restoreGlobal("__filename", previousFilename);
            restoreGlobal("__dirname", previousDirname);
            restoreGlobal("require", previousRequire);
          }
        };

        require.cache = moduleCache;
        return require;
      };

      globalThis.__openavaMakeRequire = makeRequire;

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

        let executionEntry = Self.executionEntry(for: request)

        let loadCommonJSModuleBlock: @convention(block) (String, String) -> String = { specifier, parentFilename in
            Self.loadCommonJSModuleEnvelope(
                specifier: specifier,
                parentFilename: parentFilename,
                workspaceRootURL: request.workspaceRootURL,
                entryFilename: executionEntry.filename
            )
        }
        context.setObject(unsafeBitCast(loadCommonJSModuleBlock, to: AnyObject.self), forKeyedSubscript: "__openavaLoadCommonJSModule" as NSString)

        let inputJSON = try Self.jsonString(from: request.input ?? AnyCodable(NSNull()))
        context.setObject(inputJSON, forKeyedSubscript: "__openavaInputJSON" as NSString)
        context.setObject(request.workspaceRootURL?.path ?? "", forKeyedSubscript: "__openavaWorkspaceRoot" as NSString)
        context.setObject(executionEntry.filename, forKeyedSubscript: "__openavaEntryFilename" as NSString)
        context.setObject(executionEntry.dirname, forKeyedSubscript: "__openavaEntryDirname" as NSString)

        _ = context.evaluateScript(Self.bootstrapJavaScript)
        if let exception = context.exception {
            context.exception = nil
            throw JavaScriptServiceError.executionFailed(Self.describeJavaScriptException(exception))
        }

        let wrappedCode = try Self.wrappedExecutionJavaScript(for: request, entry: executionEntry)
        if let sourceURL = executionEntry.sourceURL {
            _ = context.evaluateScript(wrappedCode, withSourceURL: sourceURL)
        } else {
            _ = context.evaluateScript(wrappedCode)
        }
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

    private static func executionEntry(for request: Request) -> ExecutionEntry {
        if let sourceURL = request.sourceURL?.standardizedFileURL {
            return ExecutionEntry(
                filename: sourceURL.path,
                dirname: sourceURL.deletingLastPathComponent().path,
                sourceURL: sourceURL
            )
        }

        if let workspaceRootURL = request.workspaceRootURL?.standardizedFileURL {
            let inlineURL = workspaceRootURL.appendingPathComponent(inlineEntryFilename, isDirectory: false).standardizedFileURL
            return ExecutionEntry(
                filename: inlineURL.path,
                dirname: workspaceRootURL.path,
                sourceURL: nil
            )
        }

        return ExecutionEntry(
            filename: inlineEntryFilename,
            dirname: "",
            sourceURL: nil
        )
    }

    private static func wrappedExecutionJavaScript(for request: Request, entry: ExecutionEntry) throws -> String {
        try wrappedCommonJSEntryJavaScript(for: request.code, entry: entry)
    }

    private static func wrappedCommonJSEntryJavaScript(for code: String, entry: ExecutionEntry) throws -> String {
        let filenameLiteral = try javaScriptStringLiteral(entry.filename)
        let dirnameLiteral = try javaScriptStringLiteral(entry.dirname)

        return """
        (async () => {
          const __openavaFilename = \(filenameLiteral);
          const __openavaDirname = \(dirnameLiteral);
          const module = { id: __openavaFilename, filename: __openavaFilename, loaded: false, exports: {} };
          const exports = module.exports;
          const require = globalThis.__openavaMakeRequire(__openavaFilename);
          const previousModule = globalThis.module;
          const previousExports = globalThis.exports;
          const previousFilename = globalThis.__filename;
          const previousDirname = globalThis.__dirname;
          const previousRequire = globalThis.require;
          globalThis.module = module;
          globalThis.exports = exports;
          globalThis.__filename = __openavaFilename;
          globalThis.__dirname = __openavaDirname;
          globalThis.require = require;
          try {
            const __openavaResult = await (async function (exports, require, module, __filename, __dirname, process) {
        \(code)
            })(exports, require, module, __openavaFilename, __openavaDirname, globalThis.process);
            module.loaded = true;
            return __openavaResult === undefined ? module.exports : __openavaResult;
          } finally {
            if (previousModule === undefined) { delete globalThis.module; } else { globalThis.module = previousModule; }
            if (previousExports === undefined) { delete globalThis.exports; } else { globalThis.exports = previousExports; }
            if (previousFilename === undefined) { delete globalThis.__filename; } else { globalThis.__filename = previousFilename; }
            if (previousDirname === undefined) { delete globalThis.__dirname; } else { globalThis.__dirname = previousDirname; }
            if (previousRequire === undefined) { delete globalThis.require; } else { globalThis.require = previousRequire; }
          }
        })()
        .then(value => globalThis.__openavaComplete(true, globalThis.__openavaSerialize(value)))
        .catch(error => globalThis.__openavaComplete(false, globalThis.__openavaSerializeError(error)));
        """
    }

    private static func loadCommonJSModuleEnvelope(
        specifier: String,
        parentFilename: String,
        workspaceRootURL: URL?,
        entryFilename: String
    ) -> String {
        do {
            let descriptor = try resolveCommonJSModule(
                specifier: specifier,
                parentFilename: parentFilename,
                workspaceRootURL: workspaceRootURL,
                entryFilename: entryFilename
            )
            return try jsonString(
                from: CommonJSModuleEnvelope(
                    ok: true,
                    value: descriptor,
                    error: nil
                )
            )
        } catch let error as CommonJSModuleResolutionError {
            return (try? jsonString(
                from: CommonJSModuleEnvelope(
                    ok: false,
                    value: nil,
                    error: ToolBridgeError(
                        code: OpenClawNodeErrorCode.invalidRequest.rawValue,
                        message: error.localizedDescription,
                        retryable: nil,
                        retryAfterMs: nil
                    )
                )
            )) ?? "{\"ok\":false,\"error\":{\"code\":\"invalid_request\",\"message\":\"Failed to encode CommonJS module error\"}}"
        } catch {
            return (try? jsonString(
                from: CommonJSModuleEnvelope(
                    ok: false,
                    value: nil,
                    error: ToolBridgeError(
                        code: OpenClawNodeErrorCode.unavailable.rawValue,
                        message: error.localizedDescription,
                        retryable: nil,
                        retryAfterMs: nil
                    )
                )
            )) ?? "{\"ok\":false,\"error\":{\"code\":\"unavailable\",\"message\":\"Failed to encode CommonJS module error\"}}"
        }
    }

    private static func resolveCommonJSModule(
        specifier: String,
        parentFilename: String,
        workspaceRootURL: URL?,
        entryFilename: String
    ) throws -> CommonJSModuleDescriptor {
        let trimmedSpecifier = specifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSpecifier.isEmpty else {
            throw CommonJSModuleResolutionError.invalidSpecifier("require() specifier must be a non-empty string")
        }
        guard let workspaceRootURL else {
            throw CommonJSModuleResolutionError.unavailable("require() requires an active workspace")
        }

        let workspaceURL = workspaceRootURL.standardizedFileURL
        let baseURL: URL
        if trimmedSpecifier.hasPrefix("/") {
            baseURL = URL(fileURLWithPath: trimmedSpecifier).standardizedFileURL
        } else if Self.isCommonJSRelativeSpecifier(trimmedSpecifier) {
            let parentURL: URL
            if !parentFilename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                parentURL = URL(fileURLWithPath: parentFilename).standardizedFileURL
            } else {
                parentURL = URL(fileURLWithPath: entryFilename).standardizedFileURL
            }
            baseURL = parentURL.deletingLastPathComponent().appendingPathComponent(trimmedSpecifier).standardizedFileURL
        } else {
            throw CommonJSModuleResolutionError.unsupportedSpecifier(trimmedSpecifier)
        }

        for candidate in commonJSCandidateURLs(for: baseURL) {
            if let moduleURL = try validatedCommonJSModuleURL(candidate, workspaceRootURL: workspaceURL) {
                let code = try normalizedScriptCode(at: moduleURL)
                return CommonJSModuleDescriptor(
                    filename: moduleURL.path,
                    dirname: moduleURL.deletingLastPathComponent().path,
                    code: code
                )
            }
        }

        throw CommonJSModuleResolutionError.notFound(trimmedSpecifier)
    }

    private static func isCommonJSRelativeSpecifier(_ specifier: String) -> Bool {
        specifier == "." || specifier == ".." || specifier.hasPrefix("./") || specifier.hasPrefix("../")
    }

    private static func commonJSCandidateURLs(for baseURL: URL) -> [URL] {
        var candidates: [URL] = [baseURL.standardizedFileURL]
        if baseURL.pathExtension.isEmpty {
            candidates.append(baseURL.appendingPathExtension("js").standardizedFileURL)
            candidates.append(baseURL.appendingPathExtension("cjs").standardizedFileURL)
        }

        let directoryBase = baseURL.standardizedFileURL
        candidates.append(directoryBase.appendingPathComponent("index.js", isDirectory: false).standardizedFileURL)
        candidates.append(directoryBase.appendingPathComponent("index.cjs", isDirectory: false).standardizedFileURL)

        var seen = Set<String>()
        return candidates.filter { seen.insert($0.path).inserted }
    }

    private static func validatedCommonJSModuleURL(_ candidate: URL, workspaceRootURL: URL) throws -> URL? {
        let normalizedURL = candidate.standardizedFileURL
        let workspacePath = workspaceRootURL.path
        let candidatePath = normalizedURL.path
        let isWithinWorkspace = candidatePath == workspacePath || candidatePath.hasPrefix(workspacePath + "/")
        guard isWithinWorkspace else {
            throw CommonJSModuleResolutionError.outsideWorkspace(candidatePath)
        }

        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: candidatePath, isDirectory: &isDirectory) else {
            return nil
        }

        guard !isDirectory.boolValue else {
            return nil
        }

        return normalizedURL
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

    private static func jsonString<T: Encodable>(from value: T) throws -> String {
        let data = try JSONEncoder().encode(value)
        guard let json = String(data: data, encoding: .utf8) else {
            throw JavaScriptServiceError.executionFailed("Failed to encode JavaScript payload as UTF-8")
        }
        return json
    }

    private static func javaScriptStringLiteral(_ value: String) throws -> String {
        let data = try JSONEncoder().encode(value)
        guard let json = String(data: data, encoding: .utf8) else {
            throw JavaScriptServiceError.executionFailed("Failed to encode JavaScript string literal as UTF-8")
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

private enum CommonJSModuleResolutionError: LocalizedError {
    case invalidSpecifier(String)
    case unsupportedSpecifier(String)
    case notFound(String)
    case outsideWorkspace(String)
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case let .invalidSpecifier(message):
            return message
        case let .unsupportedSpecifier(specifier):
            return "Unsupported CommonJS specifier '\(specifier)'. Only relative or absolute workspace paths are supported"
        case let .notFound(specifier):
            return "CommonJS module not found for '\(specifier)'"
        case let .outsideWorkspace(path):
            return "CommonJS module path must stay within the active workspace: '\(path)'"
        case let .unavailable(message):
            return message
        }
    }
}
