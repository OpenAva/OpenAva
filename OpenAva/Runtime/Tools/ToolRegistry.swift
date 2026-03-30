import Foundation

/// Central registry for managing tool definitions from various services.
/// Tools are registered at startup and queried by LLMClient when building requests.
actor ToolRegistry {
    private var definitions: [ToolDefinition] = []
    private var commandToFunctionName: [String: String] = [:]
    private var functionNameToCommand: [String: String] = [:]

    /// Shared singleton instance
    static let shared = ToolRegistry()

    private init() {}

    /// Register tools from a provider
    func register(provider: ToolDefinitionProvider) {
        let newDefinitions = provider.toolDefinitions()
        for definition in newDefinitions {
            // Keep registry idempotent across repeated startup/attach cycles.
            definitions.removeAll {
                $0.functionName == definition.functionName || $0.command == definition.command
            }

            if let previousCommand = functionNameToCommand[definition.functionName] {
                commandToFunctionName.removeValue(forKey: previousCommand)
            }
            if let previousFunctionName = commandToFunctionName[definition.command] {
                functionNameToCommand.removeValue(forKey: previousFunctionName)
            }

            definitions.append(definition)
            commandToFunctionName[definition.command] = definition.functionName
            functionNameToCommand[definition.functionName] = definition.command
        }
    }

    /// Get all registered tool definitions
    func allDefinitions() -> [ToolDefinition] {
        definitions
    }

    /// Get function name for a command
    func functionName(forCommand command: String) -> String? {
        commandToFunctionName[command]
    }

    /// Get command for a function name
    func command(forFunctionName functionName: String) -> String? {
        functionNameToCommand[functionName]
    }

    /// Clear all registered tools (useful for testing)
    func clear() {
        definitions.removeAll()
        commandToFunctionName.removeAll()
        functionNameToCommand.removeAll()
    }
}
