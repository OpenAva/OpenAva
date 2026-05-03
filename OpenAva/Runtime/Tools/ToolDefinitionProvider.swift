import Foundation
import OpenClawKit

/// Protocol for services that provide tool definitions and invocation handlers to the LLM.
/// Each tool service implements this protocol to register its available tools.
@preconcurrency
protocol ToolDefinitionProvider: AnyObject {
    /// Returns the tool definitions that this service provides.
    /// Each definition includes the function name, command, description, and parameter schema.
    func toolDefinitions() -> [ToolDefinition]

    /// Register invocation handlers for this provider's commands into the given handlers map.
    /// The default implementation does nothing, preserving backward compatibility for
    /// providers whose handlers are still in ToolRuntime.
    func registerHandlers(into handlers: inout [String: ToolHandler])

    /// Register invocation handlers using a shared registration context.
    func registerHandlers(into handlers: inout [String: ToolHandler], context: ToolHandlerRegistrationContext)
}

extension ToolDefinitionProvider {
    func registerHandlers(into _: inout [String: ToolHandler]) {
        // Default: no handlers — backward compatible with providers not yet migrated.
    }

    func registerHandlers(into handlers: inout [String: ToolHandler], context _: ToolHandlerRegistrationContext) {
        registerHandlers(into: &handlers)
    }
}

struct ToolHandlerRegistrationContext {
    let workspaceRootURL: URL?
    let modelConfig: AppConfig.LLMModel?
    let activeSupportRootURLProvider: @Sendable () -> URL?
    let toolInvoker: @Sendable (BridgeInvokeRequest, String?) async -> BridgeInvokeResponse
    let teamToolContextProvider: @Sendable () -> TeamSwarmCoordinator.ToolContext

    init(
        workspaceRootURL: URL? = nil,
        modelConfig: AppConfig.LLMModel? = nil,
        activeSupportRootURLProvider: @escaping @Sendable () -> URL? = { nil },
        toolInvoker: @escaping @Sendable (BridgeInvokeRequest, String?) async -> BridgeInvokeResponse = { request, _ in
            BridgeInvokeResponse(
                id: request.id,
                ok: false,
                error: OpenClawNodeError(code: .unavailable, message: "UNAVAILABLE: local tool handler unavailable")
            )
        },
        teamToolContextProvider: @escaping @Sendable () -> TeamSwarmCoordinator.ToolContext = {
            TeamSwarmCoordinator.ToolContext(sessionID: nil, senderMemberID: nil)
        }
    ) {
        self.workspaceRootURL = workspaceRootURL
        self.modelConfig = modelConfig
        self.activeSupportRootURLProvider = activeSupportRootURLProvider
        self.toolInvoker = toolInvoker
        self.teamToolContextProvider = teamToolContextProvider
    }
}

enum ToolHandlerError: Error {
    case unknownCommand
    case handlerUnavailable
}

/// A tool invocation handler closure type.
typealias ToolHandler = @Sendable (BridgeInvokeRequest) async throws -> BridgeInvokeResponse
