import SwiftUI

struct AgentCreationView: View {
    @Environment(\.appContainerStore) private var containerStore
    @State private var viewModel = AgentCreationViewModel()
    @State private var isEmojiPickerPresented = false

    let onComplete: () -> Void

    private var usedEmojis: Set<String> {
        Set(containerStore.agents.map { $0.emoji.trimmingCharacters(in: .whitespacesAndNewlines) })
    }

    var body: some View {
        NavigationStack {
            Group {
                switch viewModel.currentStep {
                case .userInfo:
                    userInfoStep
                case .agentAndSoul:
                    agentAndSoulStep
                }
            }
            .navigationTitle(L10n.tr("agent.creation.nav.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if viewModel.currentStep != .userInfo {
                        Button {
                            viewModel.goToPreviousStep()
                        } label: {
                            Label(L10n.tr("common.back"), systemImage: "chevron.left")
                        }
                    }
                }
            }
        }
    }

    // MARK: - Step 1: User Info

    private var userInfoStep: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.tr("agent.creation.about.title"))
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.primary)
                    Text(L10n.tr("agent.creation.about.subtitle"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 16, leading: 20, bottom: 8, trailing: 20))
            }

            Section {
                TextField(L10n.tr("agent.creation.callName.placeholder"), text: $viewModel.data.userCallName)
                    .textInputAutocapitalization(.words)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        Color(uiColor: .secondarySystemBackground),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                    )
                    .listRowBackground(Color.clear)
            } header: {
                Text(L10n.tr("agent.creation.callName.header"))
            }

            Section {
                ZStack(alignment: .topLeading) {
                    if viewModel.data.userContext.isEmpty {
                        Text(L10n.tr("agent.creation.context.placeholder"))
                            .foregroundStyle(.tertiary)
                            .padding(.top, 8)
                            .padding(.leading, 4)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $viewModel.data.userContext)
                        .frame(minHeight: 120)
                        .scrollContentBackground(.hidden)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    Color(uiColor: .secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
                .listRowBackground(Color.clear)
            } header: {
                Text(L10n.tr("agent.creation.context.header"))
            } footer: {
                Text(L10n.tr("agent.creation.context.footer"))
            }

            if let errorText = viewModel.errorText {
                Section {
                    Text(errorText)
                        .foregroundStyle(.red)
                }
            }

            Section {
                Button {
                    viewModel.goToNextStep(avoiding: usedEmojis)
                } label: {
                    Text(L10n.tr("common.continue"))
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(viewModel.canProceedFromUserInfo ? Color.accentColor : Color(uiColor: .tertiarySystemFill))
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .disabled(!viewModel.canProceedFromUserInfo)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.white)
        #if !targetEnvironment(macCatalyst)
            .scrollDismissesKeyboard(.interactively)
        #endif
    }

    // MARK: - Step 2: Agent & Soul

    private var agentAndSoulStep: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.tr("agent.creation.design.title"))
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.primary)
                    Text(L10n.tr("agent.creation.design.subtitle"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 16, leading: 20, bottom: 8, trailing: 20))
            }

            if !viewModel.presets.isEmpty {
                Section {
                    presetPicker
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                } header: {
                    Text(L10n.tr("agent.creation.presets.header"))
                } footer: {
                    Text(L10n.tr("agent.creation.presets.footer"))
                }
            }

            Section {
                HStack {
                    TextField(L10n.tr("common.name"), text: $viewModel.data.agentName, prompt: Text(L10n.tr("agent.creation.agentName.placeholder")))
                        .textInputAutocapitalization(.words)

                    Divider()
                        .padding(.vertical, 8)

                    Button {
                        isEmojiPickerPresented = true
                    } label: {
                        Text(viewModel.data.agentEmoji)
                            .font(.title3)
                            .frame(width: 34, height: 34)
                            .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)

                    Button {
                        viewModel.randomizeAgentEmoji(avoiding: usedEmojis)
                    } label: {
                        Image(systemName: "shuffle")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 34, height: 34)
                            .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    Color(uiColor: .secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
                .listRowBackground(Color.clear)
            } header: {
                Text(L10n.tr("agent.creation.identity.header"))
            }

            Section {
                TextField(L10n.tr("agent.creation.vibe.placeholder"), text: $viewModel.data.agentVibe)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .listRowSeparator(.hidden)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        Color(uiColor: .secondarySystemBackground),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                    )
                    .listRowBackground(Color.clear)

                optionWrap(options: viewModel.vibeOptions) { option in
                    viewModel.applyVibeOption(option)
                }
                .padding(.vertical, 4)
                .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 12, trailing: 0))
                .listRowBackground(Color.white)
            } header: {
                Text(L10n.tr("agent.creation.vibe.header"))
            }

            Section {
                ZStack(alignment: .topLeading) {
                    if viewModel.data.soulCoreTruths.isEmpty {
                        Text(L10n.tr("agent.creation.truths.placeholder"))
                            .foregroundStyle(.tertiary)
                            .padding(.top, 8)
                            .padding(.leading, 4)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $viewModel.data.soulCoreTruths)
                        .frame(minHeight: 120)
                        .scrollContentBackground(.hidden)
                }
                .listRowSeparator(.hidden)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    Color(uiColor: .secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
                .listRowBackground(Color.clear)

                optionWrap(options: viewModel.truthOptions) { option in
                    viewModel.toggleTruthOption(option)
                } isActive: { option in
                    viewModel.containsTruthOption(option)
                }
                .padding(.vertical, 4)
                .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 12, trailing: 0))
                .listRowBackground(Color.white)
            } header: {
                Text(L10n.tr("agent.creation.truths.header"))
            }

            if let emojiNoticeText = viewModel.emojiNoticeText {
                Section {
                    Text(emojiNoticeText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if let errorText = viewModel.errorText {
                Section {
                    Text(errorText)
                        .foregroundStyle(.red)
                }
            }

            Section {
                Button {
                    Task {
                        await createAgent()
                    }
                } label: {
                    if viewModel.isCreating {
                        HStack(spacing: 8) {
                            ProgressView()
                                .tint(.white)
                            Text(L10n.tr("agent.creation.creating"))
                        }
                    } else {
                        Text(L10n.tr("agent.creation.create"))
                    }
                }
                .disabled(!viewModel.canComplete || viewModel.isCreating)
                .font(.headline)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background((viewModel.canComplete && !viewModel.isCreating) ? Color.accentColor : Color(uiColor: .tertiarySystemFill))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.white)
        #if !targetEnvironment(macCatalyst)
            .scrollDismissesKeyboard(.interactively)
        #endif
            .sheet(isPresented: $isEmojiPickerPresented) {
                NavigationStack {
                    emojiPickerGrid
                        .navigationTitle(L10n.tr("agent.creation.emojiPicker.title"))
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button(L10n.tr("common.done")) {
                                    isEmojiPickerPresented = false
                                }
                            }
                        }
                }
                .presentationDetents([.medium, .large])
            }
    }

    // MARK: - Actions

    private func createAgent() async {
        do {
            try await viewModel.createAgent(containerStore: containerStore)
            onComplete()
        } catch {
            viewModel.errorText = error.localizedDescription
        }
    }

    private var emojiPickerGrid: some View {
        // Keep a simple local picker to avoid adding new dependencies.
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 44), spacing: 12)], spacing: 12) {
                ForEach(viewModel.emojiCandidates, id: \.self) { emoji in
                    Button {
                        viewModel.setAgentEmoji(emoji)
                        isEmojiPickerPresented = false
                    } label: {
                        Text(emoji)
                            .font(.title2)
                            .frame(width: 44, height: 44)
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.tr("agent.creation.emojiPicker.choose", emoji))
                }
            }
            .padding()
        }
    }

    private var presetPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(viewModel.presets, id: \.id) { preset in
                    let isSelected = viewModel.selectedPresetID == preset.id
                    Button {
                        viewModel.applyPreset(preset, avoiding: usedEmojis)
                    } label: {
                        presetCard(preset: preset, isSelected: isSelected)
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 1)
            .padding(.horizontal, 2)
        }
    }

    private func presetCard(preset: AgentPreset, isSelected: Bool) -> some View {
        let backgroundColor = isSelected ? Color.accentColor.opacity(0.14) : Color(uiColor: .secondarySystemBackground)
        let borderColor = isSelected ? Color.accentColor.opacity(0.8) : Color.secondary.opacity(0.2)

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(displayEmoji(for: preset))
                Text(preset.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }

            Text(preset.subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(height: 32, alignment: .topLeading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .frame(width: 196, height: 76, alignment: .leading)
        .background(backgroundColor, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(borderColor, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func displayEmoji(for preset: AgentPreset) -> String {
        let normalized = preset.agentEmoji.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? "🤖" : normalized
    }

    private func optionWrap(
        options: [String],
        onTap: @escaping (String) -> Void,
        isActive: @escaping (String) -> Bool = { _ in false }
    ) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(options, id: \.self) { option in
                    optionChip(title: option, isActive: isActive(option)) {
                        onTap(option)
                    }
                }
            }
            .padding(.vertical, 1)
            .padding(.horizontal, 2)
        }
    }

    private func optionChip(title: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    isActive ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.12),
                    in: Capsule()
                )
                .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    AgentCreationView(onComplete: {})
        .environment(\.appContainerStore, AppContainerStore(container: .makeDefault()))
}
