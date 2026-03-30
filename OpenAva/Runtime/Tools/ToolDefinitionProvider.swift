import Foundation

/// Protocol for services that provide tool definitions to the LLM.
/// Each tool service implements this protocol to register its available tools.
protocol ToolDefinitionProvider {
    /// Returns the tool definitions that this service provides.
    /// Each definition includes the function name, command, description, and parameter schema.
    func toolDefinitions() -> [ToolDefinition]
}
