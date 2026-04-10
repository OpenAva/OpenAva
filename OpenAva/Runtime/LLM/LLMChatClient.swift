import ChatClient
import ChatUI
import Foundation
import OSLog

/// ChatClient implementation driven by AppConfig.LLMModel.
/// Runtime delegates network/protocol behavior to ChatKit provider clients.
open class LLMChatClient: ChatClient, @unchecked Sendable {
    let modelConfig: AppConfig.LLMModel

    private static let logger = Logger(subsystem: "com.day1-labs.openava", category: "runtime.client.llm")

    public enum ClientError: Swift.Error, LocalizedError {
        case notConfigured

        public var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "LLM client is not configured."
            }
        }
    }

    private let fallbackErrorCollector: ErrorCollector
    private var delegatedErrorCollector: ErrorCollector?

    public var errorCollector: ErrorCollector {
        delegatedErrorCollector ?? fallbackErrorCollector
    }

    init(modelConfig: AppConfig.LLMModel) {
        self.modelConfig = modelConfig
        fallbackErrorCollector = ErrorCollector.new()
    }

    public func chat(body: ChatRequestBody) async throws -> ChatResponse {
        let providerClient = try makeProviderClient()
        delegatedErrorCollector = providerClient.errorCollector

        var requestBody = body
        requestBody.model = AppConfig.nonEmpty(modelConfig.model)
        requestBody.stream = false

        Self.logger.info("delegating non-streaming request to ChatKit provider client")
        return try await providerClient.chat(body: requestBody)
    }

    public func streamingChat(body: ChatRequestBody) async throws -> AnyAsyncSequence<ChatResponseChunk> {
        let providerClient = try makeProviderClient()
        delegatedErrorCollector = providerClient.errorCollector

        var requestBody = body
        requestBody.model = AppConfig.nonEmpty(modelConfig.model)
        requestBody.stream = true

        Self.logger.info("delegating streaming request to ChatKit provider client")
        return try await providerClient.streamingChat(body: requestBody)
    }

    private func makeProviderClient() throws -> ChatClient {
        guard let endpoint = modelConfig.endpoint,
              let model = AppConfig.nonEmpty(modelConfig.model)
        else {
            throw ClientError.notConfigured
        }

        let providerType = LLMProvider(rawValue: modelConfig.provider) ?? .custom
        let requestURL = providerType.resolveRequestURL(baseURL: endpoint, model: model)

        let apiKey = AppConfig.nonEmpty(modelConfig.apiKey)
        let apiKeyHeader = AppConfig.nonEmpty(modelConfig.apiKeyHeader) ?? "Authorization"

        switch providerType {
        case .deepseek:
            let client = DeepSeekClient(model: model, apiKey: apiKey)
            configureOpenAICompatibleEndpoint(client: client, requestURL: requestURL)
            applyAPIKeyHeaderOverride(client: client, apiKey: apiKey, apiKeyHeader: apiKeyHeader)
            return client
        case .moonshot:
            let client = MoonshotClient(model: model, apiKey: apiKey)
            configureOpenAICompatibleEndpoint(client: client, requestURL: requestURL)
            applyAPIKeyHeaderOverride(client: client, apiKey: apiKey, apiKeyHeader: apiKeyHeader)
            return client
        case .grok:
            let client = GrokClient(model: model, apiKey: apiKey)
            configureOpenAICompatibleEndpoint(client: client, requestURL: requestURL)
            applyAPIKeyHeaderOverride(client: client, apiKey: apiKey, apiKeyHeader: apiKeyHeader)
            return client
        case .openrouter, .openrouterFree:
            let client = OpenRouterClient(model: model, apiKey: apiKey)
            configureOpenAICompatibleEndpoint(client: client, requestURL: requestURL)
            applyAPIKeyHeaderOverride(client: client, apiKey: apiKey, apiKeyHeader: apiKeyHeader)
            return client
        case .openai, .custom, .google:
            let client = OpenAICompatibleClient(
                model: model,
                baseURL: requestURL.absoluteString,
                path: nil,
                apiKey: apiKey,
                defaultHeaders: [:],
                requestCustomization: [:]
            )
            applyAPIKeyHeaderOverride(client: client, apiKey: apiKey, apiKeyHeader: apiKeyHeader)
            return client
        case .anthropic:
            let client = AnthropicClient(
                model: model,
                baseURL: requestURL.absoluteString,
                apiKey: apiKey,
                apiVersion: "2023-06-01",
                defaultHeaders: [:],
                thinkingBudgetTokens: 0
            )
            applyAnthropicAPIKeyHeaderOverride(client: client, apiKey: apiKey, apiKeyHeader: apiKeyHeader)
            return client
        }
    }

    /// Force OpenAI-compatible clients to send to resolved runtime URL directly.
    private func configureOpenAICompatibleEndpoint(client: OpenAICompatibleClient, requestURL: URL) {
        client.baseURL = requestURL.absoluteString
        client.path = nil
    }

    /// Support non-standard API key header configured by user.
    private func applyAPIKeyHeaderOverride(
        client: OpenAICompatibleClient,
        apiKey: String?,
        apiKeyHeader: String
    ) {
        guard let apiKey else {
            return
        }
        guard apiKeyHeader.caseInsensitiveCompare("Authorization") != .orderedSame else {
            return
        }
        client.apiKey = nil
        client.defaultHeaders[apiKeyHeader] = apiKey
    }

    /// Anthropic defaults to x-api-key, but keep custom header compatibility.
    private func applyAnthropicAPIKeyHeaderOverride(
        client: AnthropicClient,
        apiKey: String?,
        apiKeyHeader: String
    ) {
        guard let apiKey else {
            return
        }
        guard apiKeyHeader.caseInsensitiveCompare("x-api-key") != .orderedSame else {
            return
        }
        client.apiKey = nil
        client.defaultHeaders[apiKeyHeader] = apiKey
    }
}
