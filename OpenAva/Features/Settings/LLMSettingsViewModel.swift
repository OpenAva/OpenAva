import Foundation
import Observation

@MainActor
@Observable
final class LLMSettingsViewModel {
    private struct ConnectionTestRequest: Encodable {
        struct Message: Encodable {
            let role: String
            let content: String
        }

        let model: String
        let messages: [Message]
        let stream: Bool
    }

    private struct ConnectionTestError: LocalizedError {
        let message: String

        var errorDescription: String? {
            message
        }
    }

    /// Simple validation error for form validation
    private struct ValidationError: LocalizedError {
        let message: String

        var errorDescription: String? {
            message
        }

        init(_ message: String) {
            self.message = message
        }
    }

    var modelID: UUID
    var modelName: String
    var endpoint = ""
    var apiKey = ""
    var apiKeyHeader = "Authorization"
    var model = ""
    var provider = "openai-compatible"
    var systemPrompt = ""
    var contextTokens = String(LLMProvider.openai.defaultContextTokens)
    var requestTimeoutMs = "60000"
    var errorText: String?
    var isTestingConnection = false
    var connectionTestMessage: String?
    var isConnectionTestSuccessful: Bool?

    private static let customModelOptionID = "__custom_model__"

    // MARK: - Computed Properties

    var supportsQuickSetup: Bool {
        selectedProviderType != .custom
    }

    var recommendedModelsForSelectedProvider: [LLMModelOption] {
        selectedProviderType.recommendedModels
    }

    var selectedModelOption: String {
        get {
            let normalizedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
            if recommendedModelsForSelectedProvider.contains(where: { $0.id == normalizedModel }) {
                return normalizedModel
            }
            return Self.customModelOptionID
        }
        set {
            if newValue == Self.customModelOptionID {
                let normalizedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
                if recommendedModelsForSelectedProvider.contains(where: { $0.id == normalizedModel }) {
                    model = ""
                }
                return
            }
            model = newValue
        }
    }

    var shouldShowCustomModelInput: Bool {
        if selectedProviderType == .custom {
            return true
        }
        return selectedModelOption == Self.customModelOptionID
    }

    var customModelOptionID: String {
        Self.customModelOptionID
    }

    var selectedProviderType: LLMProvider {
        get {
            let normalizedProvider = provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if let providerType = LLMProvider(rawValue: normalizedProvider) {
                return providerType
            }

            if normalizedProvider.isEmpty,
               let inferred = LLMProvider.infer(endpoint: endpoint, apiKeyHeader: apiKeyHeader, model: model)
            {
                return inferred
            }
            return .custom
        }
        set {
            provider = newValue.rawValue
            let endpointText = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
            let knownEndpoints = Set(LLMProvider.allCases.map(\.defaultEndpoint).filter { !$0.isEmpty })
            if endpointText.isEmpty || knownEndpoints.contains(endpointText) {
                endpoint = newValue.defaultEndpoint
            }

            let apiKeyHeaderText = apiKeyHeader.trimmingCharacters(in: .whitespacesAndNewlines)
            let knownHeaders = Set(LLMProvider.allCases.map(\.defaultApiKeyHeader))
            if apiKeyHeaderText.isEmpty || knownHeaders.contains(apiKeyHeaderText) {
                apiKeyHeader = newValue.defaultApiKeyHeader
            }

            // Preserve user-entered keys, but allow switching between built-in presets.
            let apiKeyText = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            let builtInKeys = Set(LLMProvider.allCases.compactMap(\.builtInApiKey))
            if apiKeyText.isEmpty || builtInKeys.contains(apiKeyText) {
                apiKey = newValue.builtInApiKey ?? ""
            }

            if newValue != .custom {
                let modelText = model.trimmingCharacters(in: .whitespacesAndNewlines)
                if modelText.isEmpty || LLMProvider.allRecommendedModelIDs.contains(modelText) {
                    model = newValue.defaultModel
                }
            }
        }
    }

    // MARK: - Initialization

    init(model: AppConfig.LLMModel) {
        modelID = model.id
        modelName = model.name
        endpoint = model.endpoint?.absoluteString ?? ""
        apiKey = model.apiKey ?? ""
        apiKeyHeader = model.apiKeyHeader
        self.model = model.model ?? ""
        provider = model.provider
        systemPrompt = model.systemPrompt ?? ""
        contextTokens = String(model.contextTokens)
        requestTimeoutMs = String(model.requestTimeoutMs)

        let selectedProvider = selectedProviderType
        if selectedProvider != .custom {
            provider = selectedProvider.rawValue
            if AppConfig.nonEmpty(endpoint) == nil {
                endpoint = selectedProvider.defaultEndpoint
            }
            if AppConfig.nonEmpty(apiKeyHeader) == nil {
                apiKeyHeader = selectedProvider.defaultApiKeyHeader
            }
            if AppConfig.nonEmpty(apiKey) == nil {
                apiKey = selectedProvider.builtInApiKey ?? ""
            }
            if AppConfig.nonEmpty(self.model) == nil {
                self.model = selectedProvider.defaultModel
            }
        }
    }

    // MARK: - Config Building

    func buildModel() throws -> AppConfig.LLMModel {
        let endpointText = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let modelText = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let providerText = provider.trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKeyHeaderText = apiKeyHeader.trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKeyText = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let systemPromptText = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !endpointText.isEmpty else {
            throw ValidationError(L10n.tr("settings.llmEdit.error.endpointRequired"))
        }
        guard let endpoint = URL(string: endpointText), endpoint.scheme != nil else {
            throw ValidationError(L10n.tr("settings.llmSettings.error.endpointValidURL"))
        }
        guard !modelText.isEmpty else {
            throw ValidationError(L10n.tr("settings.llmSettings.error.modelRequired"))
        }
        guard !providerText.isEmpty else {
            throw ValidationError(L10n.tr("settings.llmSettings.error.providerRequired"))
        }
        guard !apiKeyHeaderText.isEmpty else {
            throw ValidationError(L10n.tr("settings.llmSettings.error.apiKeyHeaderRequired"))
        }
        guard let contextTokens = Int(contextTokens.trimmingCharacters(in: .whitespacesAndNewlines)), contextTokens > 0 else {
            throw ValidationError(L10n.tr("settings.llmEdit.error.contextTokensInvalid"))
        }
        guard let requestTimeoutMs = Int(requestTimeoutMs.trimmingCharacters(in: .whitespacesAndNewlines)), requestTimeoutMs > 0 else {
            throw ValidationError(L10n.tr("settings.llmEdit.error.timeoutInvalid"))
        }

        return AppConfig.LLMModel(
            id: modelID,
            name: modelName,
            endpoint: endpoint,
            apiKey: apiKeyText.isEmpty ? nil : apiKeyText,
            apiKeyHeader: apiKeyHeaderText,
            model: modelText,
            provider: providerText,
            systemPrompt: systemPromptText.isEmpty ? nil : systemPromptText,
            contextTokens: contextTokens,
            requestTimeoutMs: requestTimeoutMs
        )
    }

    // MARK: - Actions

    func testConnection() async {
        isTestingConnection = true
        errorText = nil
        connectionTestMessage = nil
        isConnectionTestSuccessful = nil

        do {
            let model = try buildModel()
            try await Self.performConnectionTest(with: model)
            connectionTestMessage = L10n.tr("settings.llmEdit.connectionSucceeded")
            isConnectionTestSuccessful = true
        } catch let error as ValidationError {
            self.errorText = error.localizedDescription
        } catch {
            connectionTestMessage = error.localizedDescription
            isConnectionTestSuccessful = false
        }

        isTestingConnection = false
    }

    /// Auto-save the current configuration to the container store if valid
    func autoSaveIfValid(updateStore: (AppConfig.LLMModel) -> Void) {
        errorText = nil
        do {
            let model = try buildModel()
            updateStore(model)
        } catch {
            // Silently fail on validation errors during auto-save
            // The error will be shown when user explicitly tests connection
        }
    }

    func reset() {
        let defaultProvider = LLMProvider.openai
        endpoint = defaultProvider.defaultEndpoint
        apiKey = ""
        apiKeyHeader = defaultProvider.defaultApiKeyHeader
        model = defaultProvider.defaultModel
        provider = defaultProvider.rawValue
        systemPrompt = ""
        contextTokens = String(defaultProvider.defaultContextTokens)
        requestTimeoutMs = "60000"
        errorText = nil
        isTestingConnection = false
        connectionTestMessage = nil
        isConnectionTestSuccessful = nil
    }

    // MARK: - Private Methods

    private static func performConnectionTest(with model: AppConfig.LLMModel) async throws {
        guard let baseEndpoint = model.endpoint,
              let modelName = AppConfig.nonEmpty(model.model)
        else {
            throw ConnectionTestError(message: L10n.tr("settings.llmSettings.error.testNeedsEndpointModel"))
        }

        // Resolve provider type from the selected model.
        let providerType = LLMProvider(rawValue: model.provider) ?? .custom

        // Build the request URL using base URL + API path.
        let requestURL = providerType.resolveRequestURL(baseURL: baseEndpoint, model: modelName)

        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.timeoutInterval = Double(max(1, model.requestTimeoutMs)) / 1000.0
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        LLMRequestBuilder.applyAuthentication(apiKey: model.apiKey, apiKeyHeader: model.apiKeyHeader, to: &request)

        // Send a minimal completion request to verify the configured endpoint and credentials.
        // Note: Google uses different request format, skip detailed validation for now.
        if providerType != .google {
            request.httpBody = try JSONEncoder().encode(ConnectionTestRequest(
                model: modelName,
                messages: [.init(role: "user", content: "Reply with OK.")],
                stream: false
            ))
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ConnectionTestError(message: L10n.tr("settings.llmEdit.error.missingHTTPStatus"))
        }
        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            let message = LLMResponseParser.extractErrorMessage(from: data) ?? HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)
            throw ConnectionTestError(message: message)
        }

        try validateConnectionTestResponse(data, provider: providerType)
    }

    private static func validateConnectionTestResponse(_ data: Data, provider: LLMProvider) throws {
        // Google uses different response format, skip detailed validation.
        guard provider != .google else { return }

        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ConnectionTestError(message: L10n.tr("settings.llmEdit.error.invalidJSON"))
        }
        if let error = object["error"] {
            let message = LLMResponseParser.extractErrorMessage(from: error) ?? L10n.tr("common.unknownError")
            throw ConnectionTestError(message: message)
        }
        guard let choices = object["choices"] as? [Any], !choices.isEmpty else {
            throw ConnectionTestError(message: L10n.tr("settings.llmEdit.error.missingChoices"))
        }
    }
}
