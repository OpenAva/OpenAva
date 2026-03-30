import Foundation
import OpenClawKit

/// Store for persisting multiple LLM configurations
enum LLMConfigStore {
    private static let apiKeyService = "com.day1-labs.openava.llm-apikeys"

    private enum DefaultsKey {
        static let collection = "llmCollection"
    }

    // MARK: - Collection Management

    /// Load the full collection of LLM configurations.
    static func loadCollection(defaults: UserDefaults = .standard) -> AppConfig.LLMCollection {
        guard let data = defaults.data(forKey: DefaultsKey.collection),
              let models = try? JSONDecoder().decode([AppConfig.LLMModel].self, from: data)
        else {
            return AppConfig.LLMCollection.empty()
        }

        // Load API keys from keychain for each model.
        let modelsWithKeys = models.map { model in
            var updatedModel = model
            if let apiKey = GenericPasswordKeychainStore.loadString(
                service: apiKeyService,
                account: model.id.uuidString
            ) {
                updatedModel.apiKey = apiKey
            }
            return updatedModel
        }

        return AppConfig.LLMCollection(
            models: modelsWithKeys
        )
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
            saveAPIKey(model.apiKey, for: model.id)
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

        saveCollection(collection, defaults: defaults)
    }

    /// Delete a model from the collection.
    static func deleteModel(id: UUID, defaults: UserDefaults = .standard) {
        var collection = loadCollection(defaults: defaults)
        collection.models.removeAll { $0.id == id }

        // Clear API key.
        _ = GenericPasswordKeychainStore.delete(
            service: apiKeyService,
            account: id.uuidString
        )

        saveCollection(collection, defaults: defaults)
    }

    // MARK: - Private Helpers

    private static func saveAPIKey(_ apiKey: String?, for modelID: UUID) {
        if let apiKey = AppConfig.nonEmpty(apiKey) {
            _ = GenericPasswordKeychainStore.saveString(
                apiKey,
                service: apiKeyService,
                account: modelID.uuidString
            )
        } else {
            _ = GenericPasswordKeychainStore.delete(
                service: apiKeyService,
                account: modelID.uuidString
            )
        }
    }
}
