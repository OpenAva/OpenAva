import Foundation

/// LLM provider types with their configurations
enum LLMProvider: String, CaseIterable, Identifiable {
    private static let fallbackMaxContextTokens = 200_000

    case openai
    case anthropic
    case google
    case deepseek
    case grok
    case moonshot
    case openrouter
    case openrouterFree = "openrouter-free"
    case custom = "openai-compatible"

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .openai: return "OpenAI"
        case .anthropic: return "Anthropic"
        case .google: return "Google (Gemini)"
        case .deepseek: return "DeepSeek"
        case .grok: return "xAI (Grok)"
        case .moonshot: return "Moonshot (Kimi)"
        case .openrouter: return "OpenRouter"
        case .openrouterFree: return "OpenRouter (Free)"
        case .custom: return "Custom (OpenAI Compatible)"
        }
    }

    /// Default base endpoint URL without API path
    var defaultEndpoint: String {
        switch self {
        case .openai: return "https://api.openai.com/v1"
        case .anthropic: return "https://api.anthropic.com"
        case .google: return "https://generativelanguage.googleapis.com/v1beta"
        case .deepseek: return "https://api.deepseek.com/v1"
        case .grok: return "https://api.x.ai/v1"
        case .moonshot: return "https://api.moonshot.cn/v1"
        case .openrouter: return "https://openrouter.ai/api/v1"
        case .openrouterFree: return "https://openrouter.ai/api/v1"
        case .custom: return ""
        }
    }

    /// API path for chat/completions endpoint
    var chatApiPath: String {
        switch self {
        case .openai, .deepseek, .grok, .moonshot, .openrouter, .openrouterFree, .custom:
            return "/chat/completions"
        case .anthropic:
            return "/v1/messages"
        case .google:
            return "/models"
        }
    }

    /// Default API key header name
    var defaultApiKeyHeader: String {
        switch self {
        case .openai, .anthropic, .deepseek, .grok, .moonshot, .openrouter, .openrouterFree, .custom:
            return "Authorization"
        case .google:
            return "x-goog-api-key"
        }
    }

    /// Built-in API key for providers that ship with a preset key
    var builtInApiKey: String? {
        switch self {
        case .openrouterFree:
            return "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"
        default:
            return nil
        }
    }

    /// Recommended models for this provider
    var recommendedModels: [LLMModelOption] {
        switch self {
        case .openai:
            return [
                .init(id: "gpt-5.4", displayName: "GPT-5.4", maxContextTokens: 320_000),
                .init(id: "gpt-5-mini", displayName: "GPT-5 mini", maxContextTokens: 272_000),
            ]
        case .anthropic:
            return [
                .init(id: "claude-opus-4-6", displayName: "Claude Opus 4.6", maxContextTokens: 200_000),
                .init(id: "claude-sonnet-4-6", displayName: "Claude Sonnet 4.6", maxContextTokens: 200_000),
                .init(id: "claude-haiku-4-5", displayName: "Claude Haiku 4.5", maxContextTokens: 200_000),
            ]
        case .google:
            return [
                .init(id: "gemini-3.1-pro-preview", displayName: "Gemini 3.1 Pro", maxContextTokens: 320_000),
                .init(id: "gemini-3-flash-preview", displayName: "Gemini 3 Flash", maxContextTokens: 320_000),
                .init(id: "gemini-3.1-flash-lite-preview", displayName: "Gemini 3.1 Flash-Lite", maxContextTokens: 320_000),
            ]
        case .deepseek:
            return [
                .init(id: "deepseek-reasoner", displayName: "DeepSeek Reasoner", maxContextTokens: 131_000),
                .init(id: "deepseek-chat", displayName: "DeepSeek Chat", maxContextTokens: 131_000),
            ]
        case .grok:
            return [
                .init(id: "grok-4-1-fast-reasoning", displayName: "Grok 4.1 Fast Reasoning", maxContextTokens: 200_000),
                .init(id: "grok-3-mini", displayName: "Grok 3 mini", maxContextTokens: 131_000),
            ]
        case .moonshot:
            return [
                .init(id: "kimi-k2.5", displayName: "Kimi K2.5", maxContextTokens: 262_144),
                .init(id: "kimi-k2-thinking", displayName: "Kimi K2 Thinking", maxContextTokens: 256_000),
            ]
        case .openrouter:
            return [
                .init(id: "openai/gpt-5.4", displayName: "OpenAI GPT-5.4", maxContextTokens: 320_000),
                .init(id: "anthropic/claude-sonnet-4-6", displayName: "Anthropic Claude Sonnet 4.6", maxContextTokens: 200_000),
                .init(id: "google/gemini-3-flash-preview", displayName: "Google Gemini 3 Flash", maxContextTokens: 320_000),
            ]
        case .openrouterFree:
            return [
                .init(id: "stepfun/step-3.5-flash:free", displayName: "StepFun Step 3.5 Flash (Free)", maxContextTokens: 256_000),
                .init(id: "arcee-ai/trinity-large-preview:free", displayName: "Arcee Trinity Large Preview (Free)", maxContextTokens: 131_000),
                .init(id: "z-ai/glm-4.5-air:free", displayName: "Z.ai GLM-4.5 Air (Free)", maxContextTokens: 131_000),
            ]
        case .custom:
            return []
        }
    }

    // OpenRouter Free
    // ApiKey: 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
    // stepfun/step-3.5-flash:free
    // arcee-ai/trinity-large-preview:free
    // z-ai/glm-4.5-air:free

    /// Default model ID for this provider
    var defaultModel: String {
        recommendedModels.first?.id ?? ""
    }

    /// Default max context tokens for this provider
    var defaultContextTokens: Int {
        recommendedModels.first?.maxContextTokens ?? Self.fallbackMaxContextTokens
    }

    /// Find recommended model option by ID
    func recommendedModelOption(id: String) -> LLMModelOption? {
        let normalizedModelID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedModelID.isEmpty else { return nil }
        return recommendedModels.first(where: { $0.id == normalizedModelID })
    }

    /// Build full request URL from base URL
    func chatRequestURL(baseURL: URL, model: String? = nil) -> URL {
        let baseString = baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        switch self {
        case .google:
            // Google requires model name in path: /v1beta/models/{model}:generateContent
            let modelId = model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "gemini-1.5-pro-latest"
            return URL(string: "\(baseString)/models/\(modelId):generateContent")!
        default:
            return URL(string: "\(baseString)\(chatApiPath)")!
        }
    }

    /// Build request URL from base URL, handling both new base URL format and legacy full endpoint format
    func resolveRequestURL(baseURL: URL, model: String) -> URL {
        let baseString = baseURL.absoluteString

        // Check if the URL already contains the API path (backward compatibility)
        switch self {
        case .openai, .deepseek, .grok, .moonshot, .openrouter, .openrouterFree, .custom:
            if baseString.contains("/chat/completions") {
                return baseURL
            }
        case .anthropic:
            if baseString.contains("/v1/messages") {
                return baseURL
            }
        case .google:
            if baseString.contains("/models/"), baseString.contains(":generateContent") {
                return baseURL
            }
        }

        // Build URL from base URL + API path
        return chatRequestURL(baseURL: baseURL, model: model)
    }

    // MARK: - Static helpers

    static var allRecommendedModelIDs: Set<String> {
        Set(allCases.flatMap(\.recommendedModels).map(\.id))
    }

    /// Find model option by model ID across all providers.
    static func recommendedModelOption(for modelID: String) -> LLMModelOption? {
        let normalizedModelID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedModelID.isEmpty else { return nil }
        return allCases
            .lazy
            .flatMap(\.recommendedModels)
            .first(where: { $0.id == normalizedModelID })
    }

    /// Infer provider type from endpoint, header, and model
    static func infer(endpoint: String, apiKeyHeader: String, model: String) -> LLMProvider? {
        let normalizedEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)

        // Match by base URL
        if let matchedByEndpoint = allCases.first(where: { provider in
            guard provider != .custom else { return false }
            let defaultBaseURL = provider.defaultEndpoint
            if normalizedEndpoint == defaultBaseURL {
                return true
            }
            // Backward compatibility: match old full endpoint formats
            if normalizedEndpoint.hasPrefix(defaultBaseURL + "/") {
                return true
            }
            return false
        }) {
            return matchedByEndpoint
        }

        // Match by model
        let normalizedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if let matchedByModel = allCases.first(where: { provider in
            provider.recommendedModels.contains(where: { $0.id == normalizedModel })
        }) {
            return matchedByModel
        }

        // Match by header
        let normalizedHeader = apiKeyHeader.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedHeader.caseInsensitiveCompare("Authorization") == .orderedSame {
            if normalizedEndpoint.contains("openai.com") { return .openai }
            if normalizedEndpoint.contains("deepseek.com") { return .deepseek }
            if normalizedEndpoint.contains("x.ai") { return .grok }
            if normalizedEndpoint.contains("moonshot.cn") { return .moonshot }
            if normalizedEndpoint.contains("openrouter.ai") {
                if allCases
                    .first(where: { provider in
                        provider.recommendedModels.contains(where: { $0.id == normalizedModel })
                    }) == .openrouterFree
                {
                    return .openrouterFree
                }
                return .openrouter
            }
        }
        if normalizedHeader.caseInsensitiveCompare("x-goog-api-key") == .orderedSame {
            return .google
        }
        return nil
    }
}

/// Model option for UI display
struct LLMModelOption: Identifiable, Hashable {
    let id: String
    let displayName: String
    let maxContextTokens: Int
}

// MARK: - Request Helpers

enum LLMRequestBuilder {
    /// Apply authentication headers to the request
    static func applyAuthentication(apiKey: String?, apiKeyHeader: String?, to request: inout URLRequest) {
        guard let apiKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines),
              !apiKey.isEmpty else { return }
        let header = apiKeyHeader?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Authorization"
        if header.caseInsensitiveCompare("Authorization") == .orderedSame {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: header)
        } else {
            request.setValue(apiKey, forHTTPHeaderField: header)
        }
    }
}

// MARK: - Response Helpers

enum LLMResponseParser {
    /// Extract error message from response data
    static func extractErrorMessage(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return extractErrorMessage(from: object)
    }

    static func extractErrorMessage(from value: Any) -> String? {
        if let text = value as? String {
            return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
        }
        if let object = value as? [String: Any] {
            if let message = object["message"] as? String,
               !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                return message
            }
            if let error = object["error"] {
                return extractErrorMessage(from: error)
            }
        }
        return nil
    }
}
