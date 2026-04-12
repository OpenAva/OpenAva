import Foundation

/// Central registry for managing tool definitions and handlers from various services.
/// Tools are registered at startup and queried by LLMClient when building requests.
actor ToolRegistry {
    private var definitionsByCommand: [String: ToolDefinition] = [:]
    private var handlersByCommand: [String: ToolHandler] = [:]

    /// Shared singleton instance
    static let shared = ToolRegistry()

    private init() {}

    /// Register tools and handlers from a provider
    func register(provider: ToolDefinitionProvider) {
        let newDefinitions = provider.toolDefinitions()
        for definition in newDefinitions {
            definitionsByCommand[definition.command] = definition
        }
        provider.registerHandlers(into: &handlersByCommand)
    }

    /// Register a single handler for a command
    func registerHandler(command: String, handler: @escaping ToolHandler) {
        handlersByCommand[command] = handler
    }

    /// Get all registered tool definitions
    func allDefinitions() -> [ToolDefinition] {
        Array(definitionsByCommand.values)
    }

    /// Get command for a function name
    func command(forFunctionName functionName: String) -> String? {
        definitionsByCommand.values.first { $0.functionName == functionName }?.command
    }

    /// Get full definition for a function name
    func definition(forFunctionName functionName: String) -> ToolDefinition? {
        definitionsByCommand.values.first { $0.functionName == functionName }
    }

    /// Get full definition for a command
    func definition(forCommand command: String) -> ToolDefinition? {
        definitionsByCommand[command]
    }

    /// Get handler for a command
    func handler(forCommand command: String) -> ToolHandler? {
        handlersByCommand[command]
    }

    /// Get all registered handlers
    func allHandlers() -> [String: ToolHandler] {
        handlersByCommand
    }

    /// Clear all registered tools and handlers (useful for testing)
    func clear() {
        definitionsByCommand.removeAll()
        handlersByCommand.removeAll()
    }
}
