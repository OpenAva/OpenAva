import Foundation
import OpenClawKit

/// Store for persisting multiple LLM configurations
enum LLMConfigStore {
    private static let apiKeyService = "com.day1-labs.openava.llm-apikeys"

    private enum DefaultsKey {
        static let collection = "llmCollection"
    }

    // MARK: - Collection Management

    static func keychainAccount(for provider: String, endpoint: URL?) -> String {
        if provider == LLMProvider.custom.rawValue {
            return "custom_" + (endpoint?.host ?? "unknown")
        }
        return provider
    }

    /// Load the full collection of LLM configurations.
    static func loadCollection(defaults: UserDefaults = .standard) -> AppConfig.LLMCollection {
        let models: [AppConfig.LLMModel]
        if let data = defaults.data(forKey: DefaultsKey.collection),
           let decoded = try? JSONDecoder().decode([AppConfig.LLMModel].self, from: data),
           !decoded.isEmpty
        {
            models = decoded
        } else {
            models = defaultModels()
            // Save models metadata to defaults directly to ensure stable UUIDs
            if let data = try? JSONEncoder().encode(models) {
                defaults.set(data, forKey: DefaultsKey.collection)
            }
        }

        // Load API keys from keychain for each model.
        let modelsWithKeys = models.map { model in
            var updatedModel = model
            if let apiKey = GenericPasswordKeychainStore.loadString(
                service: apiKeyService,
                account: keychainAccount(for: model.provider, endpoint: model.endpoint)
            ) {
                updatedModel.apiKey = apiKey
            }
            return updatedModel
        }

        return AppConfig.LLMCollection(
            models: modelsWithKeys
        )
    }

    private static func defaultModels() -> [AppConfig.LLMModel] {
        var defaultModels: [AppConfig.LLMModel] = []
        for provider in LLMProvider.allCases where provider != .custom {
            for option in provider.recommendedModels {
                let model = AppConfig.LLMModel(
                    id: UUID(),
                    name: option.displayName,
                    endpoint: URL(string: provider.defaultEndpoint),
                    apiKey: nil,
                    apiKeyHeader: provider.defaultApiKeyHeader,
                    model: option.id,
                    provider: provider.rawValue,
                    systemPrompt: nil,
                    contextTokens: option.maxContextTokens,
                    maxOutputTokens: option.maxOutputTokens,
                    requestTimeoutMs: 60000
                )
                defaultModels.append(model)
            }
        }
        return defaultModels
    }

    /// Save the full collection of LLM configurations.
    static func saveCollection(
        _ collection: AppConfig.LLMCollection,
        defaults: UserDefaults = .standard
    ) {
        // Save models metadata.
        if let data = try? JSONEncoder().encode(collection.models) {
            defaults.set(data, forKey: DefaultsKey.collection)
        }

        // Save API keys to keychain.
        for model in collection.models {
            saveAPIKey(model.apiKey, account: keychainAccount(for: model.provider, endpoint: model.endpoint))
        }
    }

    /// Clear all persisted configurations.
    static func clearCollection(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: DefaultsKey.collection)
    }

    // MARK: - Single Model Operations

    /// Add or update a single model in the collection.
    static func saveModel(
        _ model: AppConfig.LLMModel,
        defaults: UserDefaults = .standard
    ) {
        var collection = loadCollection(defaults: defaults)

        // Update or append.
        if let index = collection.models.firstIndex(where: { $0.id == model.id }) {
            collection.models[index] = model
        } else {
            collection.models.append(model)
        }

        // Sync API key to other models with the same account
        let account = keychainAccount(for: model.provider, endpoint: model.endpoint)
        for i in 0 ..< collection.models.count {
            let m = collection.models[i]
            if keychainAccount(for: m.provider, endpoint: m.endpoint) == account {
                collection.models[i].apiKey = model.apiKey
            }
        }

        saveCollection(collection, defaults: defaults)
    }

    /// Delete a model from the collection.
    static func deleteModel(id: UUID, defaults: UserDefaults = .standard) {
        var collection = loadCollection(defaults: defaults)
        if let model = collection.models.first(where: { $0.id == id }) {
            collection.models.removeAll { $0.id == id }
            // Do not delete API key because it might be shared by other models of the same provider
            saveCollection(collection, defaults: defaults)
        }
    }

    // MARK: - Private Helpers

    private static func saveAPIKey(_ apiKey: String?, account: String) {
        if let apiKey = AppConfig.nonEmpty(apiKey) {
            _ = GenericPasswordKeychainStore.saveString(
                apiKey,
                service: apiKeyService,
                account: account
            )
        } else {
            _ = GenericPasswordKeychainStore.delete(
                service: apiKeyService,
                account: account
            )
        }
    }
}

// MARK: - Environment Keys Fetcher

enum EnvKeyFetcher {
    /// Try to fetch common API keys from standard environment variables and user's shell profile.
    static func fetchCommonAPIKeys() -> [LLMProvider: String] {
        var keys: [LLMProvider: String] = [:]

        let possibleEnvNames: [LLMProvider: [String]] = [
            .openai: ["OPENAI_API_KEY"],
            .anthropic: ["ANTHROPIC_API_KEY"],
            .google: ["GEMINI_API_KEY", "GOOGLE_API_KEY", "GOOGLE_GENAI_API_KEY"],
            .deepseek: ["DEEPSEEK_API_KEY"],
            .grok: ["XAI_API_KEY", "GROK_API_KEY"],
            .moonshot: ["MOONSHOT_API_KEY", "KIMI_API_KEY"],
            .openrouter: ["OPENROUTER_API_KEY"],
        ]

        // 1. First, read from current ProcessInfo (if app was launched from terminal or env vars were passed)
        let processEnvs = ProcessInfo.processInfo.environment
        for (provider, envNames) in possibleEnvNames {
            for envName in envNames {
                if let value = processEnvs[envName], !value.isEmpty {
                    keys[provider] = value
                    break
                }
            }
        }

        #if targetEnvironment(macCatalyst) || os(macOS)
            // 2. Read from user's shell configuration files
            let homePath = NSHomeDirectory()
            let homeUrl = URL(fileURLWithPath: homePath)
            let shellFiles = [".zshrc", ".zprofile", ".bash_profile", ".bashrc"]

            for file in shellFiles {
                let fileUrl = homeUrl.appendingPathComponent(file)
                if let content = try? String(contentsOf: fileUrl, encoding: .utf8) {
                    let lines = content.components(separatedBy: .newlines)
                    for line in lines {
                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        if trimmed.hasPrefix("export ") {
                            let exportPart = trimmed.dropFirst(7).trimmingCharacters(in: .whitespaces)
                            let parts = exportPart.split(separator: "=", maxSplits: 1)
                            if parts.count == 2 {
                                let key = String(parts[0])
                                var value = String(parts[1]).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))

                                // Handle inline comments
                                if let commentIndex = value.firstIndex(of: "#") {
                                    value = String(value[..<commentIndex]).trimmingCharacters(in: .whitespaces)
                                }

                                if !value.isEmpty {
                                    if let provider = possibleEnvNames.first(where: { $0.value.contains(key) })?.key {
                                        if keys[provider] == nil {
                                            keys[provider] = value
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        #endif

        return keys
    }
}
