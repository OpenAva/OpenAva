import Foundation
import OpenClawKit

/// Defines an available tool that can be called by the LLM.
struct ToolDefinition: Equatable {
    let functionName: String
    let command: String
    let description: String
    let parametersSchema: AnyCodable
}
