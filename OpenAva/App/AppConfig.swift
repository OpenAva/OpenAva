import Foundation

struct AppConfig {
    struct Session {
        var defaultSessionKey: String
    }

    struct Agent {
        var id: String?
        var name: String
        var emoji: String
        var selectedLLMModelID: UUID?
        var workspaceRootURL: URL?
        var supportRootURL: URL?
    }

    // MARK: - LLM Model Configuration

    /// Individual LLM model configuration
    struct LLMModel: Identifiable, Codable, Equatable {
        let id: UUID
        var name: String
        var endpoint: URL?
        var apiKey: String?
        var apiKeyHeader: String
        var model: String?
        var provider: String
        var systemPrompt: String?
        var contextTokens: Int
        var maxOutputTokens: Int?
        var requestTimeoutMs: Int

        var isConfigured: Bool {
            Self.checkIsConfigured(endpoint: endpoint, model: model)
        }

        var resolvedMaxOutputTokens: Int {
            if let maxOutputTokens {
                return max(maxOutputTokens, 0)
            }
            let providerType = LLMProvider(rawValue: provider) ?? .custom
            return providerType.resolvedMaxOutputTokens(for: model)
        }

        init(
            id: UUID = UUID(),
            name: String,
            endpoint: URL?,
            apiKey: String?,
            apiKeyHeader: String,
            model: String?,
            provider: String,
            systemPrompt: String?,
            contextTokens: Int,
            maxOutputTokens: Int? = nil,
            requestTimeoutMs: Int
        ) {
            let providerType = LLMProvider(rawValue: provider) ?? .custom
            self.id = id
            self.name = name
            self.endpoint = endpoint
            self.apiKey = apiKey
            self.apiKeyHeader = apiKeyHeader
            self.model = model
            self.provider = provider
            self.systemPrompt = systemPrompt
            self.contextTokens = contextTokens
            self.maxOutputTokens = maxOutputTokens ?? providerType.resolvedMaxOutputTokens(for: model)
            self.requestTimeoutMs = requestTimeoutMs
        }

        /// Shared helper to check if configuration is valid
        static func checkIsConfigured(endpoint: URL?, model: String?) -> Bool {
            endpoint != nil && AppConfig.nonEmpty(model) != nil
        }
    }

    /// Collection of LLM configurations
    struct LLMCollection {
        var models: [LLMModel]

        func selectedModel(preferredID: UUID?) -> LLMModel? {
            if let preferredID,
               let matchedModel = models.first(where: { $0.id == preferredID })
            {
                return matchedModel
            }
            return models.first
        }

        func isConfigured(preferredID: UUID?) -> Bool {
            selectedModel(preferredID: preferredID)?.isConfigured ?? false
        }

        static func empty() -> LLMCollection {
            LLMCollection(models: [])
        }
    }

    var session: Session
    var llmCollection: LLMCollection
    var agent: Agent

    /// Selected model id resolved from the active agent preference and model list.
    var selectedLLMModelID: UUID? {
        llmCollection.selectedModel(preferredID: agent.selectedLLMModelID)?.id
    }

    /// Expose the selected model directly so runtime code can use the latest config shape.
    var selectedLLMModel: LLMModel? {
        llmCollection.selectedModel(preferredID: agent.selectedLLMModelID)
    }

    static func makeDefault() -> AppConfig {
        make(
            environment: ProcessInfo.processInfo.environment,
            persistedLLMCollection: LLMConfigStore.loadCollection()
        )
    }

    static func make(
        environment: [String: String],
        persistedLLMCollection: LLMCollection? = nil
    ) -> AppConfig {
        let defaultSessionKey = nonEmpty(environment["OPENAVA_DEFAULT_SESSION_KEY"]) ?? "main"

        let llmCollection = resolveLLMCollection(
            environment: environment,
            persisted: persistedLLMCollection
        )

        return AppConfig(
            session: Session(defaultSessionKey: defaultSessionKey),
            llmCollection: llmCollection,
            agent: Agent(
                id: nil,
                name: "Agent",
                emoji: "🤖",
                selectedLLMModelID: nil,
                workspaceRootURL: nil,
                supportRootURL: nil
            )
        )
    }

    private static func resolveLLMURL(environment: [String: String]) -> URL? {
        if let rawURL = nonEmpty(environment["OPENAVA_LLM_URL"]) ??
            nonEmpty(environment["OPENAVA_LLM_ENDPOINT"]),
            let parsedURL = URL(string: rawURL)
        {
            return parsedURL
        }

        guard let rawBaseURL = nonEmpty(environment["OPENAVA_LLM_BASE_URL"]),
              var components = URLComponents(string: rawBaseURL)
        else {
            return nil
        }

        let trimmedPath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if trimmedPath.isEmpty {
            components.path = "/v1/chat/completions"
        }
        return components.url
    }

    private static func resolveLLMCollection(
        environment: [String: String],
        persisted: LLMCollection?
    ) -> LLMCollection {
        // Prefer the persisted collection because it already reflects the latest model format.
        if let persisted, !persisted.models.isEmpty {
            return persisted
        }

        // Create from environment if configured.
        let envEndpoint = resolveLLMURL(environment: environment)
        let envModel = nonEmpty(environment["OPENAVA_LLM_MODEL"])

        if envEndpoint != nil, let envModel {
            let model = LLMModel(
                name: nonEmpty(environment["OPENAVA_LLM_PROVIDER"]) ?? "Environment",
                endpoint: envEndpoint,
                apiKey: nonEmpty(environment["OPENAVA_LLM_API_KEY"]),
                apiKeyHeader: nonEmpty(environment["OPENAVA_LLM_API_KEY_HEADER"]) ?? "Authorization",
                model: envModel,
                provider: nonEmpty(environment["OPENAVA_LLM_PROVIDER"]) ?? "openai-compatible",
                systemPrompt: nonEmpty(environment["OPENAVA_LLM_SYSTEM_PROMPT"]),
                contextTokens: Int(environment["OPENAVA_LLM_CONTEXT_TOKENS"] ?? "") ?? 128_000,
                requestTimeoutMs: Int(environment["OPENAVA_LLM_TIMEOUT_MS"] ?? "") ?? 60000
            )
            return LLMCollection(
                models: [model]
            )
        }

        return LLMCollection.empty()
    }

    private static func boolValue(_ raw: String?) -> Bool? {
        guard let normalized = nonEmpty(raw)?.lowercased() else { return nil }
        switch normalized {
        case "1", "true", "yes", "y", "on":
            return true
        case "0", "false", "no", "n", "off":
            return false
        default:
            return nil
        }
    }

    static func nonEmpty(_ raw: String?) -> String? {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
