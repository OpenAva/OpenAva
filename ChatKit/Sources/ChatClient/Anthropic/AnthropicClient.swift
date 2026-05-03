//
//  AnthropicClient.swift
//  ChatClient
//
//  Native Anthropic Messages API client with extended thinking support.
//
//  Extended thinking allows Claude to think through complex problems before responding.
//  Thinking blocks with signatures must be preserved for multi-turn tool-use conversations.
//
//  API Reference:
//  - Messages API: https://docs.anthropic.com/en/api/messages
//  - Extended thinking: https://docs.anthropic.com/en/docs/build-with-claude/extended-thinking
//  - Streaming: https://docs.anthropic.com/en/api/messages-streaming
//  - Tool use with thinking: https://docs.anthropic.com/en/docs/build-with-claude/extended-thinking#tool-use
//
//  Supported models (extended thinking):
//  - claude-haiku-4-5-20251001
//  - claude-sonnet-4-20250514, claude-sonnet-4-5-20250929, claude-sonnet-4-6
//  - claude-opus-4-20250514, claude-opus-4-1-20250805, claude-opus-4-5-20251101, claude-opus-4-6
//

import Foundation

open class AnthropicClient: BaseChatClient, @unchecked Sendable {
    public let model: String
    open var baseURL: String
    open var apiKey: String?
    open var apiVersion: String
    open var defaultHeaders: [String: String]
    open var thinkingBudgetTokens: Int

    override open var apiProvider: APIProvider {
        .anthropic
    }

    public enum Error: Swift.Error {
        case invalidURL
        case invalidApiKey
        case invalidData
    }

    let session: URLSessioning
    let eventSourceFactory: EventSourceProducing
    let chunkDecoderFactory: @Sendable () -> JSONDecoding

    public convenience init(
        model: String,
        baseURL: String = "https://api.anthropic.com",
        apiKey: String? = nil,
        apiVersion: String = "2023-06-01",
        defaultHeaders: [String: String] = [:],
        thinkingBudgetTokens: Int = 0
    ) {
        self.init(
            model: model,
            baseURL: baseURL,
            apiKey: apiKey,
            apiVersion: apiVersion,
            defaultHeaders: defaultHeaders,
            thinkingBudgetTokens: thinkingBudgetTokens,
            dependencies: .live
        )
    }

    public init(
        model: String,
        baseURL: String = "https://api.anthropic.com",
        apiKey: String? = nil,
        apiVersion: String = "2023-06-01",
        defaultHeaders: [String: String] = [:],
        thinkingBudgetTokens: Int = 0,
        errorCollector: ErrorCollector = .new(),
        dependencies: RemoteClientDependencies
    ) {
        self.model = model
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.apiVersion = apiVersion
        self.defaultHeaders = defaultHeaders
        self.thinkingBudgetTokens = thinkingBudgetTokens
        session = dependencies.session
        eventSourceFactory = dependencies.eventSourceFactory
        chunkDecoderFactory = dependencies.chunkDecoderFactory
        super.init(errorCollector: errorCollector)
    }

    override open func chat(body: ChatRequestBody) async throws -> ChatResponse {
        let transformer = AnthropicRequestTransformer(
            thinkingBudgetTokens: thinkingBudgetTokens
        )
        let preparedBody = try body.preparingForAPI(.init(provider: apiProvider))
        let requestBody = transformer.makeRequestBody(
            from: preparedBody,
            model: model,
            stream: false
        )
        let request = try makeURLRequest(body: requestBody)
        logger.info("starting Anthropic non-streaming request to model: \(self.model) with \(body.messages.count) messages")

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
            let message = extractConnectionError(from: data, statusCode: http.statusCode)
            await errorCollector.collect(message)
            throw Error.invalidData
        }

        let payload = try JSONDecoder().decode(AnthropicMessageResponse.self, from: data)
        return try payload.asChatResponse()
    }

    override open func provideStreamingChat(
        body: ChatRequestBody
    ) async throws -> AnyAsyncSequence<ChatResponseChunk> {
        let transformer = AnthropicRequestTransformer(
            thinkingBudgetTokens: thinkingBudgetTokens
        )
        let requestBody = transformer.makeRequestBody(
            from: body,
            model: model,
            stream: true
        )
        let request = try makeURLRequest(body: requestBody)
        let this = self
        logger.info("starting Anthropic streaming request to model: \(this.model) with \(body.messages.count) messages")

        let processor = AnthropicStreamProcessor(
            eventSourceFactory: eventSourceFactory,
            chunkDecoder: chunkDecoderFactory()
        )

        return processor.stream(request: request) { [weak self] error in
            await self?.collect(error: error)
        }
    }

    func makeURLRequest(body: AnthropicRequestBody) throws -> URLRequest {
        guard var components = URLComponents(string: baseURL) else {
            throw Error.invalidURL
        }

        let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let messagesPath = "v1/messages"
        if basePath.isEmpty {
            components.path = "/\(messagesPath)"
        } else if !basePath.hasSuffix(messagesPath) {
            components.path = "/\(basePath)/\(messagesPath)"
        }

        guard let url = components.url else {
            throw Error.invalidURL
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try encoder.encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")

        let trimmedApiKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedApiKey, !trimmedApiKey.isEmpty {
            request.setValue(trimmedApiKey, forHTTPHeaderField: "x-api-key")
        }

        for (key, value) in defaultHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }

        logger.info("Anthropic request URL: \(url.absoluteString), body size: \(request.httpBody?.count ?? 0) bytes")
        return request
    }

    override open var connectionFailureMessage: String {
        String(localized: "Unable to connect to the Anthropic API.")
    }

    override open func extractConnectionError(from response: Data?, statusCode: Int) -> String {
        extractAnthropicError(from: response) ?? String(localized: "Connection error: \(statusCode)")
    }

    private func extractAnthropicError(from data: Data?) -> String? {
        guard let data,
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = dict["error"] as? [String: Any],
              let message = error["message"] as? String
        else {
            return nil
        }
        return message
    }
}

private struct AnthropicMessageResponse: Decodable {
    struct Usage: Decodable {
        let inputTokens: Int?
        let outputTokens: Int?
        let cacheCreationInputTokens: Int?
        let cacheReadInputTokens: Int?

        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
            case cacheCreationInputTokens = "cache_creation_input_tokens"
            case cacheReadInputTokens = "cache_read_input_tokens"
        }
    }

    struct ContentBlock: Decodable {
        let type: String
        let text: String?
        let id: String?
        let name: String?
        let input: [String: AnyCodingValue]?
        let thinking: String?
        let signature: String?
        let data: String?
    }

    let content: [ContentBlock]
    let usage: Usage?

    func asChatResponse() throws -> ChatResponse {
        var reasoning = ""
        var text = ""
        var tools: [ToolRequest] = []
        var thinkingBlocks: [ChatResponse.ThinkingBlockContent] = []

        for block in content {
            switch block.type {
            case "text":
                text += block.text ?? ""
            case "tool_use":
                guard let name = block.name else { continue }
                let arguments = try Self.encodeJSON(block.input ?? [:])
                tools.append(.init(id: block.id ?? UUID().uuidString, name: name, arguments: arguments))
            case "thinking":
                let value = block.thinking ?? ""
                reasoning += value
                if let signature = block.signature {
                    thinkingBlocks.append(.thinking(.init(thinking: value, signature: signature)))
                }
            case "redacted_thinking":
                if let data = block.data {
                    thinkingBlocks.append(.redactedThinking(data: data))
                }
            default:
                continue
            }
        }

        let usage = usage.map {
            TokenUsage(
                inputTokens: $0.inputTokens ?? 0,
                outputTokens: $0.outputTokens ?? 0,
                cacheReadTokens: $0.cacheReadInputTokens ?? 0,
                cacheWriteTokens: $0.cacheCreationInputTokens ?? 0,
                costUSD: nil,
                model: nil
            )
        }

        return ChatResponse(
            reasoning: reasoning,
            text: text,
            images: [],
            tools: tools,
            thinkingBlocks: thinkingBlocks,
            usage: usage
        )
    }

    private static func encodeJSON(_ payload: [String: AnyCodingValue]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: payload.untypedDictionary, options: [.sortedKeys])
        guard let string = String(data: data, encoding: .utf8) else {
            throw AnthropicClient.Error.invalidData
        }
        return string
    }
}
