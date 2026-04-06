import SwiftUI

struct AgentCreationView: View {
    @Environment(\.appContainerStore) private var containerStore
    @State private var viewModel: AgentCreationViewModel
    @State private var isEmojiPickerPresented = false

    private let pageBackgroundColor = Color.white
    private let inputFillColor = Color(uiColor: .systemGray6)
    private let inputBorderColor = Color(uiColor: .systemGray4).opacity(0.45)

    let onComplete: () -> Void

    init(
        initialMode: AgentCreationViewModel.CreationMode = .singleAgent,
        onComplete: @escaping () -> Void
    ) {
        self.onComplete = onComplete
        _viewModel = State(initialValue: AgentCreationViewModel(initialMode: initialMode))
    }

    private var usedEmojis: Set<String> {
        Set(containerStore.agents.map { $0.emoji.trimmingCharacters(in: .whitespacesAndNewlines) })
    }

    var body: some View {
        NavigationStack {
            agentAndSoulStep
                .navigationTitle(L10n.tr("agent.creation.nav.title"))
                .navigationBarTitleDisplayMode(.inline)
                .onAppear {
                    viewModel.applyAgentDefaultsIfNeeded(avoiding: usedEmojis)
                }
        }
    }

    // MARK: - Collapsible About You Section

    private var aboutYouSection: some View {
        Section {
            DisclosureGroup(
                isExpanded: $viewModel.isUserInfoExpanded
            ) {
                VStack(spacing: 12) {
                    TextField(L10n.tr("agent.creation.callName.placeholder"), text: $viewModel.data.userCallName)
                        .textInputAutocapitalization(.words)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            inputFillColor,
                            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(inputBorderColor, lineWidth: 1)
                        )

                    ZStack(alignment: .topLeading) {
                        if viewModel.data.userContext.isEmpty {
                            Text(L10n.tr("agent.creation.context.placeholder"))
                                .foregroundStyle(.tertiary)
                                .padding(.top, 8)
                                .padding(.leading, 4)
                                .allowsHitTesting(false)
                        }
                        TextEditor(text: $viewModel.data.userContext)
                            .frame(minHeight: 100)
                            .scrollContentBackground(.hidden)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(
                        inputFillColor,
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(inputBorderColor, lineWidth: 1)
                    )
                }
                .padding(.top, 8)
            } label: {
                HStack(spacing: 6) {
                    Text(L10n.tr("agent.creation.about.title"))
                        .font(.subheadline.weight(.semibold))
                    if !viewModel.isUserInfoExpanded, !viewModel.data.userCallName.isEmpty {
                        Text("·")
                            .foregroundStyle(.tertiary)
                        Text(viewModel.data.userCallName)
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.subheadline)
            }
            .listRowBackground(Color.clear)
        } footer: {
            Text(L10n.tr("agent.creation.context.footer"))
        }
    }

    // MARK: - Step 1: User Info (removed — merged into single page)

    // MARK: - Step 2: Agent & Soul

    private var agentAndSoulStep: some View {
        Form {
            aboutYouSection

            Section {
                Picker(
                    L10n.tr("agent.creation.mode.header"),
                    selection: Binding(
                        get: { viewModel.creationMode },
                        set: { viewModel.setCreationMode($0, avoiding: usedEmojis) }
                    )
                ) {
                    ForEach(AgentCreationViewModel.CreationMode.allCases) { mode in
                        Text(mode.title)
                            .tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)

                modeSummaryCard
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            } header: {
                Text(L10n.tr("agent.creation.mode.header"))
            } footer: {
                Text(L10n.tr("agent.creation.mode.footer"))
            }

            if viewModel.creationMode == .singleAgent, !viewModel.presets.isEmpty {
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

            if viewModel.creationMode == .defaultTeam {
                Section {
                    teamSelectionSummaryCard
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }

                Section {
                    teamPresetGrid
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                } header: {
                    Text(L10n.tr("agent.creation.team.selection.header"))
                } footer: {
                    Text(L10n.tr("agent.creation.team.selection.footer"))
                }
            }

            if viewModel.creationMode == .singleAgent {
                singleAgentSections
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
                Button(action: performPrimaryAction) {
                    if viewModel.isCreating {
                        HStack(spacing: 8) {
                            ProgressView()
                                .tint(.white)
                            Text(L10n.tr("agent.creation.creating"))
                        }
                    } else {
                        Text(primaryActionTitle)
                    }
                }
                .disabled(!canPerformPrimaryAction || viewModel.isCreating)
                .font(.headline)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background((canPerformPrimaryAction && !viewModel.isCreating) ? Color.accentColor : Color(uiColor: .tertiarySystemFill))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
        }
        .scrollContentBackground(.hidden)
        .background(pageBackgroundColor)
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

    private var stepTwoTitle: String {
        switch viewModel.creationMode {
        case .singleAgent:
            L10n.tr("agent.creation.design.title")
        case .defaultTeam:
            L10n.tr("agent.creation.team.mode.title")
        }
    }

    private var stepTwoSubtitle: String {
        switch viewModel.creationMode {
        case .singleAgent:
            L10n.tr("agent.creation.design.subtitle")
        case .defaultTeam:
            L10n.tr("agent.creation.team.mode.subtitle")
        }
    }

    private var primaryActionTitle: String {
        switch viewModel.creationMode {
        case .singleAgent:
            L10n.tr("agent.creation.create")
        case .defaultTeam:
            L10n.tr("agent.creation.team.create")
        }
    }

    private var canPerformPrimaryAction: Bool {
        switch viewModel.creationMode {
        case .singleAgent:
            viewModel.canComplete
        case .defaultTeam:
            viewModel.canCreateDefaultTeam
        }
    }

    @ViewBuilder
    private var singleAgentSections: some View {
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
                inputFillColor,
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(inputBorderColor, lineWidth: 1)
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
                    inputFillColor,
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(inputBorderColor, lineWidth: 1)
                )
                .listRowBackground(Color.clear)

            optionWrap(options: viewModel.vibeOptions) { option in
                viewModel.applyVibeOption(option)
            }
            .padding(.vertical, 4)
            .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 12, trailing: 0))
            .listRowBackground(pageBackgroundColor)
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
                inputFillColor,
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(inputBorderColor, lineWidth: 1)
            )
            .listRowBackground(Color.clear)

            optionWrap(options: viewModel.truthOptions) { option in
                viewModel.toggleTruthOption(option)
            } isActive: { option in
                viewModel.containsTruthOption(option)
            }
            .padding(.vertical, 4)
            .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 12, trailing: 0))
            .listRowBackground(pageBackgroundColor)
        } header: {
            Text(L10n.tr("agent.creation.truths.header"))
        }
    }

    // MARK: - Actions

    private func performPrimaryAction() {
        Task {
            switch viewModel.creationMode {
            case .singleAgent:
                await createAgent()
            case .defaultTeam:
                await createDefaultTeam()
            }
        }
    }

    private func createAgent() async {
        do {
            try await viewModel.createAgent(containerStore: containerStore)
            onComplete()
        } catch {
            viewModel.errorText = error.localizedDescription
        }
    }

    private func createDefaultTeam() async {
        do {
            try await viewModel.createDefaultTeam(containerStore: containerStore)
            onComplete()
        } catch {
            viewModel.errorText = error.localizedDescription
        }
    }

    private func stepIntroCard(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.title2.weight(.bold))
                .foregroundStyle(.primary)

            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var modeSummaryCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: viewModel.creationMode.systemImage)
                .font(.headline.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 36, height: 36)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(viewModel.creationMode.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(viewModel.creationMode.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var teamSelectionSummaryCard: some View {
        let selectedPresets = viewModel.selectedDefaultTeamPresets
        let selectedTitles = selectedPresets.map(\.title).joined(separator: " · ")
        let isEmpty = selectedPresets.isEmpty

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: isEmpty ? "circle.dashed" : "checkmark.circle.fill")
                    .foregroundStyle(isEmpty ? Color.secondary : Color.accentColor)
                Text(selectedTeamSummaryText)
                    .font(.headline)
                    .foregroundStyle(.primary)
            }

            Text(isEmpty ? L10n.tr("agent.creation.team.selectedEmpty") : selectedTitles)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var selectedTeamSummaryText: String {
        String(format: L10n.tr("agent.creation.team.selectedCount"), viewModel.selectedDefaultTeamPresets.count)
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

    private var teamPresetPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(viewModel.defaultTeamPresets, id: \.id) { preset in
                    let isSelected = viewModel.containsDefaultTeamPreset(preset)

                    Button {
                        viewModel.toggleDefaultTeamPreset(preset)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                            Text(displayEmoji(for: preset))
                            Text(preset.title)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.primary)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(
                            isSelected ? Color.accentColor.opacity(0.12) : Color(uiColor: .secondarySystemBackground),
                            in: Capsule()
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 1)
            .padding(.horizontal, 2)
        }
    }

    private var teamPresetGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            ForEach(viewModel.defaultTeamPresets, id: \.id) { preset in
                let isSelected = viewModel.containsDefaultTeamPreset(preset)

                Button {
                    viewModel.toggleDefaultTeamPreset(preset)
                } label: {
                    teamPresetCard(preset: preset, isSelected: isSelected)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func teamPresetCard(preset: AgentPreset, isSelected: Bool) -> some View {
        let backgroundColor = isSelected ? Color.accentColor.opacity(0.14) : Color(uiColor: .secondarySystemBackground)
        let borderColor = isSelected ? Color.accentColor.opacity(0.72) : Color.secondary.opacity(0.18)

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Text(displayEmoji(for: preset))
                    .font(.title3)

                Spacer(minLength: 8)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            }

            Text(preset.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Text(preset.subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .topLeading)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 132, alignment: .topLeading)
        .background(backgroundColor, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(borderColor, lineWidth: 1)
        )
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
