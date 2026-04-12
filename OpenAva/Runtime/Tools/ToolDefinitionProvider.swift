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
    /// providers whose handlers are still in LocalToolInvokeService.
    func registerHandlers(into handlers: inout [String: ToolHandler])
}

extension ToolDefinitionProvider {
    func registerHandlers(into _: inout [String: ToolHandler]) {
        // Default: no handlers — backward compatible with providers not yet migrated.
    }
}

/// A tool invocation handler closure type.
typealias ToolHandler = @Sendable (BridgeInvokeRequest) async throws -> BridgeInvokeResponse
