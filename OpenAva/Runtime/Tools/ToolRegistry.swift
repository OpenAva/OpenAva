import Foundation
import OpenClawKit

/// Central registry for managing tool definitions and handlers from various services.
/// Tools are registered at startup and queried by LLMClient when building requests.
actor ToolRegistry {
    private var definitionsByFunctionName: [String: ToolDefinition] = [:]
    private var handlersByCommand: [String: ToolHandler] = [:]

    /// Shared singleton instance
    static let shared = ToolRegistry()

    private init() {}

    /// Register tools and handlers from a provider
    func register(provider: ToolDefinitionProvider) {
        register(provider: provider, context: .init())
    }

    /// Register tools and handlers from a provider with a shared registration context.
    func register(provider: ToolDefinitionProvider, context: ToolHandlerRegistrationContext) {
        let newDefinitions = provider.toolDefinitions()
        for definition in newDefinitions {
            definitionsByFunctionName[definition.functionName] = definition
        }
        provider.registerHandlers(into: &handlersByCommand, context: context)
    }

    /// Register a single handler for a command
    func registerHandler(command: String, handler: @escaping ToolHandler) {
        handlersByCommand[command] = handler
    }

    /// Get all registered tool definitions
    func allDefinitions() -> [ToolDefinition] {
        Array(definitionsByFunctionName.values)
    }

    /// Get full definition for a function name
    func definition(forFunctionName functionName: String) -> ToolDefinition? {
        definitionsByFunctionName[functionName]
    }

    /// Build an invoke request for a function name.
    func request(id: String, forFunctionName functionName: String, argumentsJSON: String?) -> BridgeInvokeRequest? {
        guard let definition = definitionsByFunctionName[functionName] else {
            return nil
        }
        return BridgeInvokeRequest(id: id, command: definition.command, paramsJSON: argumentsJSON)
    }

    /// Get handler for a command
    func handler(forCommand command: String) -> ToolHandler? {
        handlersByCommand[command]
    }

    /// Clear all registered tools and handlers (useful for testing)
    func clear() {
        definitionsByFunctionName.removeAll()
        handlersByCommand.removeAll()
    }
}
