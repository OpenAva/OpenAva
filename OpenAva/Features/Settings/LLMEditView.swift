import ChatUI
import SwiftUI

/// Edit view for adding or modifying a LLM configuration
struct LLMEditView: View {
    enum Mode {
        case add
        case edit(AppConfig.LLMModel)
    }

    enum PresentationStyle {
        case modal
        case embedded
    }

    let mode: Mode
    let onSave: (AppConfig.LLMModel) -> Void
    let onCancel: (() -> Void)?
    let presentationStyle: PresentationStyle

    @Environment(\.dismiss) private var dismiss

    @State private var viewModel: LLMEditViewModel
    @State private var isShowingDiscardAlert = false

    init(
        mode: Mode,
        onSave: @escaping (AppConfig.LLMModel) -> Void,
        onCancel: (() -> Void)? = nil,
        presentationStyle: PresentationStyle = .modal
    ) {
        self.mode = mode
        self.onSave = onSave
        self.onCancel = onCancel
        self.presentationStyle = presentationStyle
        _viewModel = State(initialValue: LLMEditViewModel(mode: mode))
    }

    private var navigationTitle: String {
        switch mode {
        case .add: return L10n.tr("settings.llmEdit.addTitle")
        case .edit: return L10n.tr("settings.llmEdit.editTitle")
        }
    }

    private var apiKeyPlaceholder: String {
        "sk-..."
    }

    private var modelPlaceholder: String {
        "gpt-5.4"
    }

    private var namePlaceholder: String {
        "Model display name"
    }

    private var endpointPlaceholder: String {
        "https://api.openai.com/v1"
    }

    private var apiKeyHeaderPlaceholder: String {
        "Authorization"
    }

    private var providerIDPlaceholder: String {
        "openai-compatible"
    }

    private var contextTokensPlaceholder: String {
        "128000"
    }

    private var timeoutPlaceholder: String {
        "60000"
    }

    private var systemPromptPlaceholder: String {
        "Optional system prompt"
    }

    var body: some View {
        Group {
            #if targetEnvironment(macCatalyst)
                VStack(spacing: 0) {
                    sheetTopBar()
                    formContent
                }
            #else
                formContent
                    .navigationTitle(navigationTitle)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(L10n.tr("common.cancel")) {
                                requestCancel()
                            }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button(L10n.tr("common.save")) {
                                saveModel()
                            }
                            .disabled(!viewModel.isValid)
                        }
                    }
            #endif
        }
        .background(Color(uiColor: ChatUIDesign.Color.warmCream))
        .alert(L10n.tr("settings.llmEdit.discard.title"), isPresented: $isShowingDiscardAlert) {
            Button(L10n.tr("common.cancel"), role: .cancel) {}
            Button(L10n.tr("common.discard"), role: .destructive) {
                cancelEditing()
            }
        } message: {
            Text(L10n.tr("settings.llmEdit.discard.message"))
        }
    }

    private var formContent: some View {
        ScrollView {
            VStack(spacing: 24) {
                CustomSection(title: L10n.tr("settings.llmEdit.basicSettings")) {
                    VStack(alignment: .leading, spacing: 16) {
                        labeledField(L10n.tr("settings.llm.provider.header")) {
                            Picker(selection: $viewModel.selectedProviderType) {
                                ForEach(LLMProvider.allCases) { provider in
                                    Text(provider.displayName).tag(provider)
                                }
                            } label: {
                                EmptyView()
                            }
                            .pickerStyle(.menu)
                            .tint(.primary)
                        }

                        labeledField(L10n.tr("settings.llm.apiKey")) {
                            SecureField(L10n.tr("settings.llmEdit.required"), text: $viewModel.apiKey)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .settingsInputFieldStyle()
                        }

                        if viewModel.supportsQuickSetup {
                            labeledField(L10n.tr("settings.llm.model.picker")) {
                                Picker(selection: $viewModel.selectedModelOption) {
                                    ForEach(viewModel.recommendedModelsForSelectedProvider) { model in
                                        Text(model.displayName).tag(model.id)
                                    }
                                    Text(L10n.tr("common.custom")).tag(viewModel.customModelOptionID)
                                } label: {
                                    EmptyView()
                                }
                                .pickerStyle(.menu)
                                .tint(.primary)
                            }

                            if viewModel.shouldShowCustomModelInput {
                                labeledField(L10n.tr("settings.llm.customModel")) {
                                    TextField(L10n.tr("settings.llmEdit.modelIdentifier"), text: $viewModel.model)
                                        .textInputAutocapitalization(.never)
                                        .autocorrectionDisabled()
                                        .settingsInputFieldStyle()
                                        .onChange(of: viewModel.model) { _, _ in
                                            viewModel.handleModelChanged()
                                        }
                                }
                            }
                        } else {
                            labeledField(L10n.tr("settings.llm.providerId")) {
                                TextField(L10n.tr("settings.llmEdit.providerExample"), text: $viewModel.provider)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .settingsInputFieldStyle()
                            }

                            labeledField(L10n.tr("settings.llm.model.picker")) {
                                TextField(L10n.tr("settings.llmEdit.modelExample"), text: $viewModel.model)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .settingsInputFieldStyle()
                                    .onChange(of: viewModel.model) { _, _ in
                                        viewModel.handleModelChanged()
                                    }
                            }
                        }

                        labeledField(L10n.tr("common.name")) {
                            TextField(L10n.tr("settings.llmEdit.displayName"), text: $viewModel.name)
                                .textInputAutocapitalization(.words)
                                .settingsInputFieldStyle()
                                .onChange(of: viewModel.name) { _, _ in
                                    viewModel.handleNameChangedByUser()
                                }
                        }
                    }
                    .padding(.horizontal, 20)
                }

                CustomSection {
                    DisclosureGroup(L10n.tr("settings.llm.advanced.title")) {
                        VStack(alignment: .leading, spacing: 16) {
                            labeledField(L10n.tr("settings.llm.endpoint")) {
                                VStack(alignment: .leading, spacing: 4) {
                                    TextField(endpointPlaceholder, text: $viewModel.endpoint)
                                        .textInputAutocapitalization(.never)
                                        .autocorrectionDisabled()
                                        .keyboardType(.URL)
                                        .settingsInputFieldStyle()
                                    if let message = viewModel.endpointValidationMessage {
                                        Text(message).font(.caption).foregroundStyle(.red)
                                    }
                                }
                            }

                            labeledField(L10n.tr("settings.llm.apiKeyHeader")) {
                                TextField(apiKeyHeaderPlaceholder, text: $viewModel.apiKeyHeader)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .settingsInputFieldStyle()
                            }

                            labeledField(L10n.tr("settings.llm.contextTokens")) {
                                VStack(alignment: .leading, spacing: 4) {
                                    TextField(contextTokensPlaceholder, text: $viewModel.contextTokens)
                                        .keyboardType(.numberPad)
                                        .settingsInputFieldStyle()
                                        .onChange(of: viewModel.contextTokens) { _, _ in
                                            viewModel.handleContextTokensChangedByUser()
                                        }
                                    if let message = viewModel.contextTokensValidationMessage {
                                        Text(message).font(.caption).foregroundStyle(.red)
                                    }
                                }
                            }

                            labeledField(L10n.tr("settings.llm.timeoutMs")) {
                                VStack(alignment: .leading, spacing: 4) {
                                    TextField(timeoutPlaceholder, text: $viewModel.requestTimeoutMs)
                                        .keyboardType(.numberPad)
                                        .settingsInputFieldStyle()
                                    if let message = viewModel.requestTimeoutValidationMessage {
                                        Text(message).font(.caption).foregroundStyle(.red)
                                    }
                                }
                            }

                            labeledField(L10n.tr("settings.llm.systemPrompt")) {
                                TextField(systemPromptPlaceholder, text: $viewModel.systemPrompt, axis: .vertical)
                                    .lineLimit(4 ... 12)
                                    .settingsInputFieldStyle()
                            }
                        }
                        .padding(.top, 16)
                    }
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color(uiColor: ChatUIDesign.Color.black60))
                    .tint(Color(uiColor: ChatUIDesign.Color.black50))
                    .padding(.horizontal, 20)
                }

                VStack(spacing: 16) {
                    Button {
                        Task { await viewModel.testConnection() }
                    } label: {
                        HStack(spacing: 8) {
                            if viewModel.isTestingConnection {
                                ProgressView().tint(.white)
                            }
                            Text(viewModel.isTestingConnection ? L10n.tr("settings.llmEdit.testing") : L10n.tr("settings.llm.testConnection"))
                                .frame(maxWidth: .infinity)
                                .font(.system(size: 16, weight: .medium))
                        }
                        .padding(.vertical, 14)
                        .foregroundStyle(Color(uiColor: ChatUIDesign.Color.pureWhite))
                        .frame(maxWidth: .infinity)
                        .background(
                            (viewModel.isTestingConnection || !viewModel.canTestConnection)
                                ? Color(uiColor: ChatUIDesign.Color.black50).opacity(0.3)
                                : Color(uiColor: ChatUIDesign.Color.offBlack)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: ChatUIDesign.Radius.button, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(viewModel.isTestingConnection || !viewModel.canTestConnection)

                    if let isSuccess = viewModel.isConnectionTestSuccessful,
                       let message = viewModel.connectionTestMessage
                    {
                        Label(message, systemImage: isSuccess ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .font(.footnote)
                            .foregroundStyle(isSuccess ? .green : .red)
                    }

                    if let errorText = viewModel.errorText {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                            Text(errorText)
                        }
                        .font(.footnote)
                        .foregroundStyle(.red)
                    }
                }
                .padding(.horizontal, 20)
            }
            .padding(.vertical, 24)
        }
        #if !targetEnvironment(macCatalyst)
        .scrollDismissesKeyboard(.interactively)
        #endif
    }

    #if targetEnvironment(macCatalyst)
        private func sheetTopBar() -> some View {
            VStack(spacing: 0) {
                ZStack {
                    Text(navigationTitle)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color(uiColor: ChatUIDesign.Color.offBlack))

                    HStack {
                        actionButton(
                            title: L10n.tr("common.cancel"),
                            role: .secondary,
                            action: requestCancel
                        )
                        Spacer(minLength: 0)
                        actionButton(
                            title: L10n.tr("common.save"),
                            role: .primary,
                            action: saveModel
                        )
                        .disabled(!viewModel.isValid)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 12)

                Rectangle()
                    .fill(Color(uiColor: ChatUIDesign.Color.oatBorder))
                    .frame(height: 1)
            }
        }
    #endif

    private enum InlineActionRole {
        case primary
        case secondary
    }

    private func actionButton(
        title: String,
        role: InlineActionRole,
        action: @escaping () -> Void
    ) -> some View {
        let foregroundColor: UIColor = switch role {
        case .primary:
            ChatUIDesign.Color.pureWhite
        case .secondary:
            ChatUIDesign.Color.offBlack
        }
        let backgroundColor: Color = switch role {
        case .primary:
            Color(uiColor: ChatUIDesign.Color.offBlack)
        case .secondary:
            .clear
        }

        return Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color(uiColor: foregroundColor))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(backgroundColor)
                .clipShape(RoundedRectangle(cornerRadius: ChatUIDesign.Radius.button, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: ChatUIDesign.Radius.button, style: .continuous)
                        .strokeBorder(Color(uiColor: ChatUIDesign.Color.oatBorder), lineWidth: role == .secondary ? 1 : 0)
                )
        }
        .buttonStyle(.plain)
    }

    private struct CustomSection<Content: View, Footer: View>: View {
        let title: String?
        let footer: Footer?
        @ViewBuilder let content: () -> Content

        init(title: String? = nil, @ViewBuilder footer: () -> Footer, @ViewBuilder content: @escaping () -> Content) {
            self.title = title
            self.footer = footer()
            self.content = content
        }

        init(title: String? = nil, @ViewBuilder content: @escaping () -> Content) where Footer == EmptyView {
            self.title = title
            self.footer = nil
            self.content = content
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                if let title {
                    Text(title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color(uiColor: ChatUIDesign.Color.black60))
                        .padding(.horizontal, 20)
                }

                content()

                if let footer {
                    footer
                        .font(.system(size: 13))
                        .foregroundStyle(Color(uiColor: ChatUIDesign.Color.black50))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 20)
                }
            }
        }
    }

    private func labeledField<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color(uiColor: ChatUIDesign.Color.black80))
            content()
        }
    }

    private func requestCancel() {
        if viewModel.hasChanges {
            isShowingDiscardAlert = true
        } else {
            cancelEditing()
        }
    }

    private func cancelEditing() {
        onCancel?()
        if presentationStyle == .modal {
            dismiss()
        }
    }

    private func saveModel() {
        guard let model = viewModel.buildModel() else { return }
        onSave(model)
    }
}

private extension View {
    func settingsInputFieldStyle() -> some View {
        frame(minHeight: 34)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                Color(uiColor: ChatUIDesign.Color.pureWhite),
                in: RoundedRectangle(cornerRadius: ChatUIDesign.Radius.card, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: ChatUIDesign.Radius.card, style: .continuous)
                    .strokeBorder(Color(uiColor: ChatUIDesign.Color.oatBorder), lineWidth: 1)
            )
    }
}

// MARK: - ViewModel

@MainActor
@Observable
final class LLMEditViewModel {
    private let mode: LLMEditView.Mode
    private let originalModel: AppConfig.LLMModel?

    // Form fields
    var name = ""
    var endpoint = "" {
        didSet { resetConnectionTestState() }
    }

    var apiKey = "" {
        didSet { resetConnectionTestState() }
    }

    var apiKeyHeader = "Authorization" {
        didSet { resetConnectionTestState() }
    }

    var model = "" {
        didSet { resetConnectionTestState() }
    }

    var provider = "openai-compatible" {
        didSet { resetConnectionTestState() }
    }

    var systemPrompt = ""
    var contextTokens = String(LLMProvider.openai.defaultContextTokens)
    var requestTimeoutMs = "60000"
    // UI state
    var errorText: String?
    var isTestingConnection = false
    var connectionTestMessage: String?
    var isConnectionTestSuccessful: Bool?

    private static let customModelOptionID = "__custom_model__"
    private var hasCustomizedName = false
    private var hasCustomizedContextTokens = false
    private var isSyncingDerivedName = false
    private var isSyncingDerivedContextTokens = false

    // Track initial values for detecting changes in add mode
    private let initialName: String
    private let initialEndpoint: String
    private let initialApiKey: String
    private let initialApiKeyHeader: String
    private let initialModel: String
    private let initialProvider: String
    private let initialSystemPrompt: String
    private let initialContextTokens: String
    private let initialRequestTimeoutMs: String

    var hasChanges: Bool {
        guard let original = originalModel else {
            // In add mode, compare against initial defaults
            return name != initialName
                || endpoint != initialEndpoint
                || apiKey != initialApiKey
                || apiKeyHeader != initialApiKeyHeader
                || model != initialModel
                || provider != initialProvider
                || systemPrompt != initialSystemPrompt
                || contextTokens != initialContextTokens
                || requestTimeoutMs != initialRequestTimeoutMs
        }
        let current = buildModel()
        return current?.name != original.name
            || current?.endpoint != original.endpoint
            || current?.apiKey != original.apiKey
            || current?.apiKeyHeader != original.apiKeyHeader
            || current?.model != original.model
            || current?.provider != original.provider
            || current?.systemPrompt != original.systemPrompt
            || current?.contextTokens != original.contextTokens
            || current?.requestTimeoutMs != original.requestTimeoutMs
    }

    var isValid: Bool {
        missingRequiredFieldsForSave.isEmpty
            && endpointValidationMessage == nil
            && contextTokensValidationMessage == nil
            && requestTimeoutValidationMessage == nil
    }

    private var missingRequiredFieldsForSave: [String] {
        var missing: [String] = []
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            missing.append(L10n.tr("common.name"))
        }
        if apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            missing.append(L10n.tr("settings.llm.apiKey"))
        }
        if endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            missing.append(L10n.tr("settings.llm.endpoint"))
        }
        if model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            missing.append(L10n.tr("settings.llm.model.picker"))
        }
        if provider.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            missing.append(L10n.tr("settings.llm.providerId"))
        }
        if apiKeyHeader.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            missing.append(L10n.tr("settings.llm.apiKeyHeader"))
        }
        return missing
    }

    var endpointValidationMessage: String? {
        let endpointText = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !endpointText.isEmpty else { return nil }
        guard let url = URL(string: endpointText),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else {
            return L10n.tr("settings.llmEdit.error.endpointInvalid")
        }
        return nil
    }

    var contextTokensValidationMessage: String? {
        let text = contextTokens.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        guard let value = Int(text), value > 0 else {
            return L10n.tr("settings.llmEdit.error.contextTokensInvalid")
        }
        return nil
    }

    var requestTimeoutValidationMessage: String? {
        let text = requestTimeoutMs.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        guard let value = Int(text), value > 0 else {
            return L10n.tr("settings.llmEdit.error.timeoutInvalid")
        }
        return nil
    }

    var missingRequiredFieldsForTest: [String] {
        missingRequiredFieldsForSave
    }

    var canTestConnection: Bool {
        missingRequiredFieldsForTest.isEmpty
            && endpointValidationMessage == nil
            && contextTokensValidationMessage == nil
            && requestTimeoutValidationMessage == nil
    }

    init(mode: LLMEditView.Mode) {
        self.mode = mode

        switch mode {
        case .add:
            originalModel = nil
            // Set defaults for new model
            let defaultProvider = LLMProvider.openai
            name = Self.derivedName(from: defaultProvider.defaultModel, providerType: defaultProvider)
            endpoint = defaultProvider.defaultEndpoint
            apiKey = defaultProvider.builtInApiKey ?? ""
            apiKeyHeader = defaultProvider.defaultApiKeyHeader
            model = defaultProvider.defaultModel
            provider = defaultProvider.rawValue
            systemPrompt = ""
            contextTokens = String(defaultProvider.defaultContextTokens)
            requestTimeoutMs = "60000"

            // Track initial values for change detection
            initialName = Self.derivedName(from: defaultProvider.defaultModel, providerType: defaultProvider)
            initialEndpoint = defaultProvider.defaultEndpoint
            initialApiKey = defaultProvider.builtInApiKey ?? ""
            initialApiKeyHeader = defaultProvider.defaultApiKeyHeader
            initialModel = defaultProvider.defaultModel
            initialProvider = defaultProvider.rawValue
            initialSystemPrompt = ""
            initialContextTokens = String(defaultProvider.defaultContextTokens)
            initialRequestTimeoutMs = "60000"

        case let .edit(model):
            originalModel = model
            name = model.name
            hasCustomizedName = true
            endpoint = model.endpoint?.absoluteString ?? ""
            apiKey = model.apiKey ?? ""
            apiKeyHeader = model.apiKeyHeader
            self.model = model.model ?? ""
            provider = model.provider
            systemPrompt = model.systemPrompt ?? ""
            contextTokens = String(model.contextTokens)
            requestTimeoutMs = String(model.requestTimeoutMs)
            hasCustomizedContextTokens = true

            // In edit mode, initial values are the same as the model's values
            initialName = model.name
            initialEndpoint = model.endpoint?.absoluteString ?? ""
            initialApiKey = model.apiKey ?? ""
            initialApiKeyHeader = model.apiKeyHeader
            initialModel = model.model ?? ""
            initialProvider = model.provider
            initialSystemPrompt = model.systemPrompt ?? ""
            initialContextTokens = String(model.contextTokens)
            initialRequestTimeoutMs = String(model.requestTimeoutMs)
        }
    }

    // MARK: - Provider Type

    var supportsQuickSetup: Bool {
        selectedProviderType != .custom
    }

    var recommendedModelsForSelectedProvider: [LLMModelOption] {
        selectedProviderType.recommendedModels
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
            updateDerivedNameFromModelIfNeeded()
            updateDerivedContextTokensFromModelIfNeeded()
        }
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
                updateDerivedNameFromModelIfNeeded()
                updateDerivedContextTokensFromModelIfNeeded()
                return
            }
            model = newValue
            updateDerivedNameFromModelIfNeeded()
            updateDerivedContextTokensFromModelIfNeeded()
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

    func handleModelChanged() {
        updateDerivedNameFromModelIfNeeded()
        updateDerivedContextTokensFromModelIfNeeded()
    }

    /// Clear stale result once critical connection fields change.
    func resetConnectionTestState() {
        connectionTestMessage = nil
        isConnectionTestSuccessful = nil
        errorText = nil
    }

    func handleNameChangedByUser() {
        guard !isSyncingDerivedName else { return }

        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedDerivedName = Self.derivedName(from: model, providerType: selectedProviderType)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        hasCustomizedName = normalizedName != normalizedDerivedName
    }

    func handleContextTokensChangedByUser() {
        guard !isSyncingDerivedContextTokens else { return }

        let normalizedContextTokens = contextTokens.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedDerivedContextTokens = String(Self.derivedContextTokens(from: model, providerType: selectedProviderType))
        hasCustomizedContextTokens = normalizedContextTokens != normalizedDerivedContextTokens
    }

    private func updateDerivedNameFromModelIfNeeded() {
        // Keep the generated name synced with selected model until user customizes it.
        guard originalModel == nil, !hasCustomizedName else { return }
        isSyncingDerivedName = true
        name = Self.derivedName(from: model, providerType: selectedProviderType)
        isSyncingDerivedName = false
    }

    private func updateDerivedContextTokensFromModelIfNeeded() {
        // Keep context window synced with selected model until user customizes it.
        guard originalModel == nil, !hasCustomizedContextTokens else { return }
        isSyncingDerivedContextTokens = true
        contextTokens = String(Self.derivedContextTokens(from: model, providerType: selectedProviderType))
        isSyncingDerivedContextTokens = false
    }

    private static func derivedName(from model: String, providerType: LLMProvider) -> String {
        let normalizedModelID = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedModelID.isEmpty else { return "" }

        if let option = providerType.recommendedModels.first(where: { $0.id == normalizedModelID }) {
            return option.displayName
        }
        if let option = LLMProvider.allCases
            .flatMap(\.recommendedModels)
            .first(where: { $0.id == normalizedModelID })
        {
            return option.displayName
        }
        return normalizedModelID
    }

    private static func derivedContextTokens(from model: String, providerType: LLMProvider) -> Int {
        let normalizedModelID = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedModelID.isEmpty else { return providerType.defaultContextTokens }

        if let option = providerType.recommendedModelOption(id: normalizedModelID) {
            return option.maxContextTokens
        }
        if let option = LLMProvider.recommendedModelOption(for: normalizedModelID) {
            return option.maxContextTokens
        }
        return providerType.defaultContextTokens
    }

    // MARK: - Build Model

    func buildModel() -> AppConfig.LLMModel? {
        let nameText = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let endpointText = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let modelText = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let providerText = provider.trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKeyHeaderText = apiKeyHeader.trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKeyText = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let systemPromptText = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !nameText.isEmpty,
              let endpoint = URL(string: endpointText),
              !apiKeyText.isEmpty,
              !modelText.isEmpty,
              !providerText.isEmpty,
              !apiKeyHeaderText.isEmpty,
              let contextTokens = Int(contextTokens.trimmingCharacters(in: .whitespacesAndNewlines)),
              contextTokens > 0,
              let requestTimeoutMs = Int(requestTimeoutMs.trimmingCharacters(in: .whitespacesAndNewlines)),
              requestTimeoutMs > 0
        else {
            return nil
        }

        let id: UUID
        switch mode {
        case .add:
            id = UUID()
        case let .edit(existingModel):
            id = existingModel.id
        }

        return AppConfig.LLMModel(
            id: id,
            name: nameText,
            endpoint: endpoint,
            apiKey: apiKeyText,
            apiKeyHeader: apiKeyHeaderText,
            model: modelText,
            provider: providerText,
            systemPrompt: systemPromptText.isEmpty ? nil : systemPromptText,
            contextTokens: contextTokens,
            requestTimeoutMs: requestTimeoutMs
        )
    }

    // MARK: - Connection Test

    func testConnection() async {
        isTestingConnection = true
        errorText = nil
        connectionTestMessage = nil
        isConnectionTestSuccessful = nil

        guard let model = buildModel() else {
            errorText = L10n.tr("settings.llmEdit.error.fixFields")
            isTestingConnection = false
            return
        }

        do {
            try await performConnectionTest(with: model)
            connectionTestMessage = L10n.tr("settings.llmEdit.connectionSucceeded")
            isConnectionTestSuccessful = true
        } catch {
            connectionTestMessage = formatConnectionFailureMessage(error.localizedDescription)
            isConnectionTestSuccessful = false
        }

        isTestingConnection = false
    }

    private func performConnectionTest(with model: AppConfig.LLMModel) async throws {
        guard let endpoint = model.endpoint else {
            throw ConnectionTestError(message: L10n.tr("settings.llmEdit.error.endpointRequired"))
        }

        struct ConnectionTestError: LocalizedError {
            let message: String
            var errorDescription: String? {
                message
            }
        }

        // Build request URL with correct API path for the provider
        let requestURL = selectedProviderType.chatRequestURL(baseURL: endpoint, model: model.model)
        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.timeoutInterval = Double(max(1, model.requestTimeoutMs)) / 1000.0
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        LLMRequestBuilder.applyAuthentication(apiKey: model.apiKey, apiKeyHeader: model.apiKeyHeader, to: &request)

        // Build request body based on provider type
        request.httpBody = try buildConnectionTestRequestBody(for: selectedProviderType, model: model.model ?? "")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ConnectionTestError(message: L10n.tr("settings.llmEdit.error.missingHTTPStatus"))
        }
        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            let message = LLMResponseParser.extractErrorMessage(from: data) ?? HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)
            throw ConnectionTestError(message: message)
        }

        try validateConnectionTestResponse(data, providerType: selectedProviderType)
    }

    private func formatConnectionFailureMessage(_ message: String) -> String {
        let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            return L10n.tr("settings.llmEdit.error.connectionFailed")
        }
        return L10n.tr("settings.llmEdit.error.connectionFailedWithReason", normalized)
    }

    /// Build request body for connection test based on provider type
    private func buildConnectionTestRequestBody(for providerType: LLMProvider, model: String) throws -> Data {
        struct OpenAIRequest: Encodable {
            struct Message: Encodable {
                let role: String
                let content: String
            }

            let model: String
            let messages: [Message]
            let stream: Bool
        }

        struct AnthropicRequest: Encodable {
            struct Message: Encodable {
                let role: String
                let content: String
            }

            let model: String
            let messages: [Message]
            let max_tokens: Int
        }

        struct GoogleContent: Encodable {
            struct Part: Encodable {
                let text: String
            }

            let parts: [Part]
        }

        struct GoogleRequest: Encodable {
            let contents: [GoogleContent]
        }

        switch providerType {
        case .google:
            return try JSONEncoder().encode(GoogleRequest(
                contents: [.init(parts: [.init(text: "Hi")])]
            ))
        case .anthropic:
            return try JSONEncoder().encode(AnthropicRequest(
                model: model,
                messages: [.init(role: "user", content: "Reply with OK.")],
                max_tokens: 10
            ))
        default:
            return try JSONEncoder().encode(OpenAIRequest(
                model: model,
                messages: [.init(role: "user", content: "Reply with OK.")],
                stream: false
            ))
        }
    }

    private func validateConnectionTestResponse(_ data: Data, providerType: LLMProvider) throws {
        struct ConnectionTestError: LocalizedError {
            let message: String
            var errorDescription: String? {
                message
            }
        }

        // Google and Anthropic use different response formats, skip detailed validation
        guard providerType != .google, providerType != .anthropic else { return }

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
