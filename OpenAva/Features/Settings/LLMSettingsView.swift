import SwiftUI

struct LLMSettingsView: View {
    @Environment(\.appContainerStore) private var containerStore

    @State private var viewModel: LLMSettingsViewModel

    init(model: AppConfig.LLMModel) {
        _viewModel = State(initialValue: LLMSettingsViewModel(model: model))
    }

    var body: some View {
        Form {
            Section {
                Picker(L10n.tr("settings.llm.provider.picker"), selection: $viewModel.selectedProviderType) {
                    ForEach(LLMProvider.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .pickerStyle(.menu)
            } header: {
                Text(L10n.tr("settings.llm.provider.header"))
            } footer: {
                Text(L10n.tr("settings.llm.provider.footer"))
            }

            if viewModel.supportsQuickSetup {
                Section {
                    SecureField(L10n.tr("settings.llm.apiKey"), text: $viewModel.apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    Picker(L10n.tr("settings.llm.model.picker"), selection: $viewModel.selectedModelOption) {
                        ForEach(viewModel.recommendedModelsForSelectedProvider) { model in
                            Text(model.displayName).tag(model.id)
                        }
                        Text(L10n.tr("common.custom")).tag(viewModel.customModelOptionID)
                    }
                    .pickerStyle(.menu)

                    if viewModel.shouldShowCustomModelInput {
                        TextField(L10n.tr("settings.llm.customModel"), text: $viewModel.model)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                } header: {
                    Text(L10n.tr("settings.llm.quickSetup.header"))
                }

                Section {
                    DisclosureGroup(L10n.tr("settings.llm.advanced.title")) {
                        TextField(L10n.tr("settings.llm.endpoint"), text: $viewModel.endpoint)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)

                        TextField(L10n.tr("settings.llm.apiKeyHeader"), text: $viewModel.apiKeyHeader)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()

                        TextField(L10n.tr("settings.llm.contextTokens"), text: $viewModel.contextTokens)
                            .keyboardType(.numberPad)
                        TextField(L10n.tr("settings.llm.timeoutMs"), text: $viewModel.requestTimeoutMs)
                            .keyboardType(.numberPad)

                        TextField(L10n.tr("settings.llm.systemPrompt"), text: $viewModel.systemPrompt, axis: .vertical)
                            .lineLimit(4 ... 12)
                    }
                } footer: {
                    Text(L10n.tr("settings.llm.advanced.footer"))
                }
            } else {
                Section {
                    TextField(L10n.tr("settings.llm.endpoint"), text: $viewModel.endpoint)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    SecureField(L10n.tr("settings.llm.apiKey"), text: $viewModel.apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField(L10n.tr("settings.llm.apiKeyHeader"), text: $viewModel.apiKeyHeader)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text(L10n.tr("settings.llm.connection.header"))
                }

                Section {
                    TextField(L10n.tr("settings.llm.providerId"), text: $viewModel.provider)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField(L10n.tr("settings.llm.model.picker"), text: $viewModel.model)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField(L10n.tr("settings.llm.contextTokens"), text: $viewModel.contextTokens)
                        .keyboardType(.numberPad)
                    TextField(L10n.tr("settings.llm.timeoutMs"), text: $viewModel.requestTimeoutMs)
                        .keyboardType(.numberPad)
                } header: {
                    Text(L10n.tr("settings.llm.model.header"))
                }

                Section {
                    TextField(L10n.tr("settings.llm.systemPrompt"), text: $viewModel.systemPrompt, axis: .vertical)
                        .lineLimit(4 ... 12)
                } header: {
                    Text(L10n.tr("settings.llm.prompt.header"))
                }
            }

            Section {
                Button {
                    // Run the network check asynchronously so the form stays responsive.
                    Task {
                        await viewModel.testConnection()
                    }
                } label: {
                    HStack {
                        Text(L10n.tr("settings.llm.testConnection"))
                        Spacer()
                        if viewModel.isTestingConnection {
                            ProgressView()
                        }
                    }
                }
                .disabled(viewModel.isTestingConnection)

                if let message = viewModel.connectionTestMessage,
                   let isSuccess = viewModel.isConnectionTestSuccessful
                {
                    Text(message)
                        .foregroundStyle(isSuccess ? .green : .red)
                }
            } header: {
                Text(L10n.tr("settings.llm.verification.header"))
            }

            if let errorText = viewModel.errorText {
                Section {
                    Text(errorText)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle(L10n.tr("settings.llm.navigationTitle"))
        .navigationBarTitleDisplayMode(.inline)
        // Auto-save when any configuration field changes
        .onChange(of: viewModel.endpoint) { _, _ in autoSave() }
        .onChange(of: viewModel.apiKey) { _, _ in autoSave() }
        .onChange(of: viewModel.apiKeyHeader) { _, _ in autoSave() }
        .onChange(of: viewModel.model) { _, _ in autoSave() }
        .onChange(of: viewModel.provider) { _, _ in autoSave() }
        .onChange(of: viewModel.systemPrompt) { _, _ in autoSave() }
        .onChange(of: viewModel.contextTokens) { _, _ in autoSave() }
        .onChange(of: viewModel.requestTimeoutMs) { _, _ in autoSave() }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    containerStore.clearLLM()
                    viewModel.reset()
                } label: {
                    Label(L10n.tr("common.reset"), systemImage: "arrow.counterclockwise")
                }
                #if !targetEnvironment(macCatalyst)
                .buttonStyle(.bordered)
                #endif
            }
        }
    }

    private func autoSave() {
        viewModel.autoSaveIfValid { model in
            containerStore.saveLLMModel(model)
        }
    }
}

#Preview {
    NavigationStack {
        LLMSettingsView(
            model: .init(
                name: "Default",
                endpoint: URL(string: "https://api.openai.com/v1/chat/completions"),
                apiKey: nil,
                apiKeyHeader: "Authorization",
                model: "gpt-4.1",
                provider: "openai-compatible",
                systemPrompt: "You are a helpful assistant.",
                contextTokens: 128_000,
                requestTimeoutMs: 60000
            )
        )
    }
}
