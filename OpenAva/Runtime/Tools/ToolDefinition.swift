import Foundation
import OpenClawKit

/// Defines an available tool that can be called by the LLM.
struct ToolDefinition: Equatable {
    let functionName: String
    let command: String
    let description: String
    let parametersSchema: AnyCodable
    let isReadOnly: Bool
    let isDestructive: Bool
    let isConcurrencySafe: Bool
    let maxResultSizeChars: Int?

    nonisolated init(
        functionName: String,
        command: String,
        description: String,
        parametersSchema: AnyCodable,
        isReadOnly: Bool = false,
        isDestructive: Bool = false,
        isConcurrencySafe: Bool = false,
        maxResultSizeChars: Int? = nil
    ) {
        self.functionName = functionName
        self.command = command
        self.description = description
        self.parametersSchema = parametersSchema
        self.isReadOnly = isReadOnly
        self.isDestructive = isDestructive
        self.isConcurrencySafe = isConcurrencySafe
        self.maxResultSizeChars = maxResultSizeChars
    }
}
