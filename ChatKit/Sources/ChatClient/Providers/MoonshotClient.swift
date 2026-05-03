//
//  MoonshotClient.swift
//  ChatClient
//
//  Preconfigured OpenAI-compatible client for Moonshot/Kimi API.
//  Handles `reasoning_content` field natively via ChatCompletionChunk.
//
//  Kimi thinking models (kimi-k2-thinking, kimi-k2.5) return
//  reasoning content in `reasoning_content` field during streaming.
//
//  Rules for `reasoning_content` in follow-up requests (same as DeepSeek V3.2):
//  - Assistant messages WITH tool_calls: reasoning_content MUST be preserved
//    when thinking mode is active (omitting causes "thinking is enabled but
//    reasoning_content is missing" error).
//    Ref: https://platform.moonshot.ai/docs/guide/use-kimi-api-to-complete-tool-calls
//  - Assistant messages WITHOUT tool_calls: reasoning_content must be stripped
//    (not accepted in regular multi-turn).
//  - content must be "" (not absent/null) when tool_calls are present.
//

import Foundation

open class MoonshotClient: OpenAICompatibleClient, @unchecked Sendable {
    override open var apiProvider: APIProvider {
        .moonshot
    }

    public convenience init(
        model: String = "kimi-k2.5",
        apiKey: String? = nil
    ) {
        self.init(
            model: model,
            baseURL: "https://api.moonshot.cn/v1",
            path: "/chat/completions",
            apiKey: apiKey
        )
    }

    /// Map canonical assistant `reasoning` to Moonshot/Kimi's
    /// `reasoning_content` transport field after API-bound normalization has
    /// applied the provider-specific preservation rules.
    ///
    /// See: https://platform.moonshot.ai/docs/guide/use-kimi-api-to-complete-tool-calls
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
            if let reasoning = messages[index].removeValue(forKey: "reasoning") {
                messages[index]["reasoning_content"] = reasoning
            }
        }

        root["messages"] = messages
        request.httpBody = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        return request
    }
}
