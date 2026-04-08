import ChatUI
import SwiftUI

// MARK: - Reusable Input Components

private struct StyledFieldModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                Color(uiColor: ChatUIDesign.Color.warmCream),
                in: RoundedRectangle(cornerRadius: ChatUIDesign.Radius.card, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: ChatUIDesign.Radius.card, style: .continuous)
                    .stroke(Color(uiColor: ChatUIDesign.Color.oatBorder), lineWidth: 1)
            )
    }
}

private extension View {
    func styledField() -> some View {
        modifier(StyledFieldModifier())
    }
}

private struct PlaceholderTextEditor: View {
    let placeholder: String
    @Binding var text: String
    var minHeight: CGFloat = 100

    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text(placeholder)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 8)
                    .padding(.leading, 4)
                    .allowsHitTesting(false)
            }
            TextEditor(text: $text)
                .frame(minHeight: minHeight)
                .scrollContentBackground(.hidden)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            Color(uiColor: ChatUIDesign.Color.warmCream),
            in: RoundedRectangle(cornerRadius: ChatUIDesign.Radius.card, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: ChatUIDesign.Radius.card, style: .continuous)
                .stroke(Color(uiColor: ChatUIDesign.Color.oatBorder), lineWidth: 1)
        )
    }
}

// MARK: - Agent Creation View

struct AgentCreationView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appContainerStore) private var containerStore
    @State private var viewModel: AgentCreationViewModel
    @State private var isEmojiPickerPresented = false

    private enum EmojiPickerTarget {
        case agent
        case team
    }

    @State private var emojiPickerTarget: EmojiPickerTarget = .agent

    let targetTeamID: UUID?
    let onComplete: () -> Void

    init(
        initialMode: AgentCreationViewModel.CreationMode = .singleAgent,
        targetTeamID: UUID? = nil,
        onComplete: @escaping () -> Void
    ) {
        self.targetTeamID = targetTeamID
        self.onComplete = onComplete
        _viewModel = State(initialValue: AgentCreationViewModel(initialMode: initialMode, targetTeamID: targetTeamID))
    }

    private var usedEmojis: Set<String> {
        Set(containerStore.agents.map { $0.emoji.trimmingCharacters(in: .whitespacesAndNewlines) })
    }

    private var usedTeamEmojis: Set<String> {
        Set(containerStore.teams.map { $0.emoji.trimmingCharacters(in: .whitespacesAndNewlines) })
    }

    var body: some View {
        formContent
            .navigationTitle(L10n.tr("agent.creation.nav.title"))
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(true)
        #if !targetEnvironment(macCatalyst)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.tr("common.cancel")) {
                        dismiss()
                    }
                }
            }
        #endif
            .onAppear {
                switch viewModel.creationMode {
                case .singleAgent:
                    viewModel.applyAgentDefaultsIfNeeded(avoiding: usedEmojis)
                case .defaultTeam:
                    viewModel.applyTeamDefaultsIfNeeded(avoiding: usedTeamEmojis)
                }
            }
    }

    // MARK: - Form

    private var formContent: some View {
        ScrollView {
            VStack(spacing: 36) {
                aboutYouSection

                modeSection

                if viewModel.creationMode == .singleAgent {
                    if !viewModel.presets.isEmpty {
                        presetSection
                    }

                    singleAgentSections
                }

                if viewModel.creationMode == .defaultTeam {
                    teamIdentitySection

                    teamSelectionSection
                }

                noticeSection

                createButtonSection
            }
            .padding(.vertical, 24)
        }
        .scrollContentBackground(.hidden)
        .background(Color(uiColor: ChatUIDesign.Color.warmCream))
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

    // MARK: - About You (Collapsible)

    private var aboutYouSection: some View {
        CustomSection {
            DisclosureGroup(isExpanded: $viewModel.isUserInfoExpanded) {
                VStack(alignment: .leading, spacing: 16) {
                    labeledField(L10n.tr("agent.creation.callName.header")) {
                        TextField(L10n.tr("agent.creation.callName.placeholder"), text: $viewModel.data.userCallName)
                            .textInputAutocapitalization(.words)
                            .styledField()
                    }

                    labeledField(L10n.tr("agent.creation.context.header")) {
                        PlaceholderTextEditor(
                            placeholder: L10n.tr("agent.creation.context.placeholder"),
                            text: $viewModel.data.userContext
                        )
                    }

                    Text(L10n.tr("agent.creation.context.footer"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                }
                .padding(.top, 12)
            } label: {
                HStack(spacing: 6) {
                    Text(L10n.tr("agent.creation.about.title"))
                        .font(.headline)
                        .foregroundStyle(.primary)
                    if !viewModel.isUserInfoExpanded, !viewModel.data.userCallName.isEmpty {
                        Text("·")
                            .foregroundStyle(.tertiary)
                        Text(viewModel.data.userCallName)
                            .foregroundStyle(.secondary)
                            .font(.subheadline)
                    }
                }
            }
            .tint(.secondary)
            .padding(.horizontal, 20)
        }
    }

    // MARK: - Mode Selection

    private var modeSection: some View {
        CustomSection(title: L10n.tr("agent.creation.mode.header")) {
            Picker(
                L10n.tr("agent.creation.mode.header"),
                selection: Binding(
                    get: { viewModel.creationMode },
                    set: {
                        switch $0 {
                        case .singleAgent:
                            viewModel.setCreationMode($0, avoiding: usedEmojis)
                        case .defaultTeam:
                            viewModel.setCreationMode($0, avoiding: usedTeamEmojis)
                        }
                    }
                )
            ) {
                ForEach(AgentCreationViewModel.CreationMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 20)
        }
    }

    // MARK: - Presets Section

    private var presetSection: some View {
        CustomSection(title: L10n.tr("agent.creation.presets.header"), footer: {
            Text(L10n.tr("agent.creation.presets.footer"))
                .padding(.horizontal, 20)
        }) {
            presetPicker
        }
    }

    // MARK: - Single Agent Sections

    @ViewBuilder
    private var singleAgentSections: some View {
        CustomSection(title: L10n.tr("agent.creation.identity.header")) {
            nameEmojiRow(
                name: $viewModel.data.agentName,
                namePlaceholder: L10n.tr("agent.creation.agentName.placeholder"),
                emoji: viewModel.data.agentEmoji,
                onPick: {
                    emojiPickerTarget = .agent
                    isEmojiPickerPresented = true
                },
                onShuffle: {
                    viewModel.randomizeAgentEmoji(avoiding: usedEmojis)
                }
            )
            .padding(.horizontal, 20)
        }

        CustomSection(title: L10n.tr("agent.creation.vibe.header")) {
            VStack(alignment: .leading, spacing: 14) {
                TextField(L10n.tr("agent.creation.vibe.placeholder"), text: $viewModel.data.agentVibe)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .styledField()
                    .padding(.horizontal, 20)

                optionWrap(options: viewModel.vibeOptions) { option in
                    viewModel.applyVibeOption(option)
                }
            }
        }

        CustomSection(title: L10n.tr("agent.creation.truths.header")) {
            VStack(alignment: .leading, spacing: 14) {
                PlaceholderTextEditor(
                    placeholder: L10n.tr("agent.creation.truths.placeholder"),
                    text: $viewModel.data.soulCoreTruths,
                    minHeight: 120
                )
                .padding(.horizontal, 20)

                optionWrap(options: viewModel.truthOptions) { option in
                    viewModel.toggleTruthOption(option)
                } isActive: { option in
                    viewModel.containsTruthOption(option)
                }
            }
        }
    }

    // MARK: - Team Identity

    private var teamIdentitySection: some View {
        CustomSection(footer: {
            Text(L10n.tr("agent.creation.team.identity.footer"))
                .padding(.horizontal, 20)
        }) {
            VStack(spacing: 16) {
                labeledField(L10n.tr("agent.creation.team.name.header")) {
                    nameEmojiRow(
                        name: $viewModel.data.teamName,
                        namePlaceholder: L10n.tr("agent.creation.team.name.placeholder"),
                        emoji: viewModel.data.teamEmoji,
                        onPick: {
                            emojiPickerTarget = .team
                            isEmojiPickerPresented = true
                        },
                        onShuffle: {
                            viewModel.randomizeTeamEmoji(avoiding: usedTeamEmojis)
                        }
                    )
                }

                labeledField(L10n.tr("agent.creation.team.description.header")) {
                    PlaceholderTextEditor(
                        placeholder: L10n.tr("agent.creation.team.description.placeholder"),
                        text: $viewModel.data.teamDescription,
                        minHeight: 90
                    )
                }
            }
            .padding(.horizontal, 20)
        }
    }

    // MARK: - Team Selection (summary + grid merged)

    private var teamSelectionSection: some View {
        CustomSection(title: L10n.tr("agent.creation.team.selection.header"), footer: {
            Text(L10n.tr("agent.creation.team.selection.footer"))
                .padding(.horizontal, 20)
        }) {
            VStack(spacing: 16) {
                teamPresetGrid
            }
            .padding(.horizontal, 20)
        }
    }

    // MARK: - Notice & Error

    @ViewBuilder
    private var noticeSection: some View {
        if let emojiNoticeText = viewModel.emojiNoticeText {
            Text(emojiNoticeText)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)
        }

        if let errorText = viewModel.errorText {
            Text(errorText)
                .font(.callout)
                .foregroundStyle(.red)
                .padding(.horizontal, 20)
        }
    }

    // MARK: - Create Button

    private var createButtonSection: some View {
        Button(action: performPrimaryAction) {
            Group {
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
            .font(.system(size: 16, weight: .regular))
            .foregroundStyle(Color(uiColor: ChatUIDesign.Color.pureWhite))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background((canPerformPrimaryAction && !viewModel.isCreating) ? Color(uiColor: ChatUIDesign.Color.offBlack) : Color(uiColor: .tertiarySystemFill))
            .clipShape(RoundedRectangle(cornerRadius: ChatUIDesign.Radius.button, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!canPerformPrimaryAction || viewModel.isCreating)
        .padding(.horizontal, 20)
    }

    // MARK: - Reusable Components

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
            VStack(alignment: .leading, spacing: 14) {
                if let title {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 20)
                }

                content()

                if let footer {
                    footer
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 20)
                }
            }
        }
    }

    private func labeledField<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.primary)
            content()
        }
    }

    private func nameEmojiRow(
        name: Binding<String>,
        namePlaceholder: String,
        emoji: String,
        onPick: @escaping () -> Void,
        onShuffle: @escaping () -> Void
    ) -> some View {
        HStack {
            TextField(namePlaceholder, text: name)
                .textInputAutocapitalization(.words)

            Divider()
                .padding(.vertical, 8)

            EmojiSelectionControl(emoji: emoji, onPick: onPick, onShuffle: onShuffle)
        }
        .styledField()
    }

    private var emojiPickerGrid: some View {
        EmojiPickerGrid(emojis: viewModel.emojiCandidates) { emoji in
            switch emojiPickerTarget {
            case .agent:
                viewModel.setAgentEmoji(emoji)
            case .team:
                viewModel.setTeamEmoji(emoji)
            }
            isEmojiPickerPresented = false
        }
    }

    // MARK: - Presets

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
            .padding(.horizontal, 20)
        }
    }

    private func presetCard(preset: AgentPreset, isSelected: Bool) -> some View {
        let backgroundColor = isSelected ? Color.accentColor.opacity(0.14) : Color(uiColor: ChatUIDesign.Color.warmCream)
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
        let backgroundColor = isSelected ? Color.accentColor.opacity(0.14) : Color(uiColor: ChatUIDesign.Color.warmCream)
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

    // MARK: - Option Chips

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
            .padding(.horizontal, 20)
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

    // MARK: - Actions

    private var primaryActionTitle: String {
        switch viewModel.creationMode {
        case .singleAgent:
            L10n.tr("agent.creation.create")
        case .defaultTeam:
            L10n.tr(targetTeamID == nil ? "agent.creation.team.create" : "agent.creation.team.createAndAdd")
        }
    }

    private var canPerformPrimaryAction: Bool {
        switch viewModel.creationMode {
        case .singleAgent:
            viewModel.canComplete
        case .defaultTeam:
            viewModel.canCreateTeam
        }
    }

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
            try await viewModel.createTeam(containerStore: containerStore)
            onComplete()
        } catch {
            viewModel.errorText = error.localizedDescription
        }
    }
}

#Preview {
    AgentCreationView(onComplete: {})
        .environment(\.appContainerStore, AppContainerStore(container: .makeDefault()))
}
