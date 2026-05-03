//
//  DeepSeekClient.swift
//  ChatClient
//
//  Preconfigured OpenAI-compatible client for DeepSeek API.
//  Handles `reasoning_content` field natively via ChatCompletionChunk.
//
//  Note: DeepSeek V4 introduced thinking-integrated tool-use.
//  Rules for reasoning_content in follow-up requests:
//  - Assistant messages that contain thinking text should send it back using
//    reasoning_content in follow-up requests.
//  - tool_calls only affects content requirements (content must be present),
//    not whether reasoning_content should be included.
//    Ref: https://api-docs.deepseek.com/guides/reasoning_model
//

import Foundation

open class DeepSeekClient: OpenAICompatibleClient, @unchecked Sendable {
    override open var apiProvider: APIProvider {
        .deepSeek
    }

    public convenience init(
        model: String = "deepseek-v4-flash",
        apiKey: String? = nil
    ) {
        self.init(
            model: model,
            baseURL: "https://api.deepseek.com",
            path: "/chat/completions",
            apiKey: apiKey
        )
    }

    // Keep assistant reasoning as internal canonical field; it will be mapped
    // to `reasoning_content` in `makeURLRequest(body:)` for DeepSeek.
    //
    // See: https://api-docs.deepseek.com/guides/reasoning_model
    //      https://api-docs.deepseek.com/guides/tool_calls

    override func makeURLRequest(body: ChatRequestBody) throws -> URLRequest {
        var request = try super.makeURLRequest(body: body)
        guard let httpBody = request.httpBody,
              var root = try JSONSerialization.jsonObject(with: httpBody) as? [String: Any],
              var messages = root["messages"] as? [[String: Any]]
        else {
            return request
        }

        for index in messages.indices {
            guard let role = messages[index]["role"] as? String, role == "assistant" else {
                continue
            }

            let toolCalls = messages[index]["tool_calls"] as? [[String: Any]]
            let hasToolCalls = !(toolCalls?.isEmpty ?? true)

            // DeepSeek expects historical thinking under reasoning_content.
            if let reasoning = messages[index].removeValue(forKey: "reasoning") {
                messages[index]["reasoning_content"] = reasoning
            }

            if hasToolCalls {
                if messages[index]["content"] == nil || messages[index]["content"] is NSNull {
                    messages[index]["content"] = ""
                }
            }
        }

        root["messages"] = messages
        request.httpBody = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        return request
    }
}
