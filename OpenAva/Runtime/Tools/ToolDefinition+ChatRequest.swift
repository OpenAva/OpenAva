import ChatClient
import Foundation

extension ToolDefinition {
    var chatRequestTool: ChatRequestBody.Tool {
        .function(
            name: functionName,
            description: description,
            parameters: parametersObject,
            strict: nil
        )
    }

    var parametersObject: [String: AnyCodingValue]? {
        do {
            let data = try JSONEncoder().encode(parametersSchema)
            return try JSONDecoder().decode([String: AnyCodingValue].self, from: data)
        } catch {
            return nil
        }
    }
}
