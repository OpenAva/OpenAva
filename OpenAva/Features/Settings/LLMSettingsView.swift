import SwiftUI

struct LLMSettingsView: View {
    @Environment(\.appContainerStore) private var containerStore

    @State private var viewModel: LLMSettingsViewModel

    init(model: AppConfig.LLMModel) {
        _viewModel = State(initialValue: LLMSettingsViewModel(model: model))
    }

    var body: some View {
        Form {
            cardSection {
                settingsCard(
                    title: L10n.tr("settings.llm.provider.header"),
                    description: L10n.tr("settings.llm.provider.footer"),
                    tint: .blue
                ) {
                    cardField(L10n.tr("settings.llm.provider.picker")) {
                        Picker("", selection: $viewModel.selectedProviderType) {
                            ForEach(LLMProvider.allCases) { provider in
                                Text(provider.displayName).tag(provider)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                }
            }

            if viewModel.supportsQuickSetup {
                cardSection {
                    settingsCard(
                        title: L10n.tr("settings.llm.quickSetup.header"),
                        tint: .indigo
                    ) {
                        cardField(L10n.tr("settings.llm.apiKey")) {
                            SecureField(L10n.tr("settings.llm.apiKey"), text: $viewModel.apiKey)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .settingsCardInputStyle()
                        }

                        cardField(L10n.tr("settings.llm.model.picker")) {
                            Picker("", selection: $viewModel.selectedModelOption) {
                                ForEach(viewModel.recommendedModelsForSelectedProvider) { model in
                                    Text(model.displayName).tag(model.id)
                                }
                                Text(L10n.tr("common.custom")).tag(viewModel.customModelOptionID)
                            }
                            .pickerStyle(.menu)
                        }

                        if viewModel.shouldShowCustomModelInput {
                            cardField(L10n.tr("settings.llm.customModel")) {
                                TextField(L10n.tr("settings.llm.customModel"), text: $viewModel.model)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .settingsCardInputStyle()
                            }
                        }
                    }
                }

                cardSection {
                    settingsCard(
                        title: L10n.tr("settings.llm.advanced.title"),
                        description: L10n.tr("settings.llm.advanced.footer"),
                        tint: .purple
                    ) {
                        cardField(L10n.tr("settings.llm.endpoint")) {
                            TextField(L10n.tr("settings.llm.endpoint"), text: $viewModel.endpoint)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .keyboardType(.URL)
                                .settingsCardInputStyle()
                        }

                        cardField(L10n.tr("settings.llm.apiKeyHeader")) {
                            TextField(L10n.tr("settings.llm.apiKeyHeader"), text: $viewModel.apiKeyHeader)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .settingsCardInputStyle()
                        }

                        cardField(L10n.tr("settings.llm.contextTokens")) {
                            TextField(L10n.tr("settings.llm.contextTokens"), text: $viewModel.contextTokens)
                                .keyboardType(.numberPad)
                                .settingsCardInputStyle()
                        }

                        cardField(L10n.tr("settings.llm.timeoutMs")) {
                            TextField(L10n.tr("settings.llm.timeoutMs"), text: $viewModel.requestTimeoutMs)
                                .keyboardType(.numberPad)
                                .settingsCardInputStyle()
                        }

                        cardField(L10n.tr("settings.llm.systemPrompt")) {
                            TextField(L10n.tr("settings.llm.systemPrompt"), text: $viewModel.systemPrompt, axis: .vertical)
                                .lineLimit(4 ... 12)
                                .settingsCardInputStyle()
                        }
                    }
                }
            } else {
                cardSection {
                    settingsCard(
                        title: L10n.tr("settings.llm.connection.header"),
                        tint: .blue
                    ) {
                        cardField(L10n.tr("settings.llm.endpoint")) {
                            TextField(L10n.tr("settings.llm.endpoint"), text: $viewModel.endpoint)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .keyboardType(.URL)
                                .settingsCardInputStyle()
                        }

                        cardField(L10n.tr("settings.llm.apiKey")) {
                            SecureField(L10n.tr("settings.llm.apiKey"), text: $viewModel.apiKey)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .settingsCardInputStyle()
                        }

                        cardField(L10n.tr("settings.llm.apiKeyHeader")) {
                            TextField(L10n.tr("settings.llm.apiKeyHeader"), text: $viewModel.apiKeyHeader)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .settingsCardInputStyle()
                        }
                    }
                }

                cardSection {
                    settingsCard(
                        title: L10n.tr("settings.llm.model.header"),
                        tint: .indigo
                    ) {
                        cardField(L10n.tr("settings.llm.providerId")) {
                            TextField(L10n.tr("settings.llm.providerId"), text: $viewModel.provider)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .settingsCardInputStyle()
                        }

                        cardField(L10n.tr("settings.llm.model.picker")) {
                            TextField(L10n.tr("settings.llm.model.picker"), text: $viewModel.model)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .settingsCardInputStyle()
                        }

                        cardField(L10n.tr("settings.llm.contextTokens")) {
                            TextField(L10n.tr("settings.llm.contextTokens"), text: $viewModel.contextTokens)
                                .keyboardType(.numberPad)
                                .settingsCardInputStyle()
                        }

                        cardField(L10n.tr("settings.llm.timeoutMs")) {
                            TextField(L10n.tr("settings.llm.timeoutMs"), text: $viewModel.requestTimeoutMs)
                                .keyboardType(.numberPad)
                                .settingsCardInputStyle()
                        }
                    }
                }

                cardSection {
                    settingsCard(
                        title: L10n.tr("settings.llm.prompt.header"),
                        tint: .purple
                    ) {
                        cardField(L10n.tr("settings.llm.systemPrompt")) {
                            TextField(L10n.tr("settings.llm.systemPrompt"), text: $viewModel.systemPrompt, axis: .vertical)
                                .lineLimit(4 ... 12)
                                .settingsCardInputStyle()
                        }
                    }
                }
            }

            cardSection {
                settingsCard(
                    title: L10n.tr("settings.llm.verification.header"),
                    tint: .green
                ) {
                    Button {
                        Task {
                            await viewModel.testConnection()
                        }
                    } label: {
                        HStack(spacing: 10) {
                            if viewModel.isTestingConnection {
                                ProgressView()
                                    .tint(.white)
                            } else {
                                Image(systemName: "network")
                                    .font(.system(size: 13, weight: .semibold))
                            }

                            Text(L10n.tr("settings.llm.testConnection"))
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                        }
                        .padding(.vertical, 10)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.isTestingConnection)

                    if let message = viewModel.connectionTestMessage,
                       let isSuccess = viewModel.isConnectionTestSuccessful
                    {
                        Label(message, systemImage: isSuccess ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .font(.footnote)
                            .foregroundStyle(isSuccess ? .green : .red)
                    }
                }
            }

            if let errorText = viewModel.errorText {
                cardSection {
                    settingsCard(
                        title: L10n.tr("common.error"),
                        tint: .red
                    ) {
                        Text(errorText)
                            .font(.subheadline)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color(uiColor: .systemGroupedBackground))
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

    private func cardSection<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        Section {
            content()
        }
        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }

    private func settingsCard<Content: View>(
        title: String,
        description: String? = nil,
        tint: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(tint.opacity(0.16))
                        .frame(width: 22, height: 22)

                    Circle()
                        .fill(tint)
                        .frame(width: 8, height: 8)
                }

                Text(title)
                    .font(.headline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
                    .tracking(0.3)
            }

            if let description, !description.isEmpty {
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(Color(uiColor: .secondaryLabel))
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            content()
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(uiColor: .systemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.8)
        )
        .shadow(color: .black.opacity(0.035), radius: 10, y: 4)
    }

    private func cardField<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)

            content()
        }
    }
}

private extension View {
    func settingsCardInputStyle() -> some View {
        padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.05), lineWidth: 0.8)
            )
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
