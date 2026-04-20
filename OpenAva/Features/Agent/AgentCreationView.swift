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
                viewModel.applyAgentDefaultsIfNeeded(avoiding: usedEmojis)
            }
    }

    // MARK: - Form

    private var formContent: some View {
        ScrollView {
            VStack(spacing: 36) {
                aboutYouSection

                if !viewModel.presets.isEmpty {
                    presetSection
                }

                singleAgentSections

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
                    emojiPickerSheetContent
                    #if !targetEnvironment(macCatalyst)
                    .navigationTitle(L10n.tr("agent.creation.emojiPicker.title"))
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button(L10n.tr("common.done")) {
                                isEmojiPickerPresented = false
                            }
                        }
                    }
                    #endif
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

    private var emojiPickerSheetContent: some View {
        VStack(spacing: 0) {
            #if targetEnvironment(macCatalyst)
                ZStack {
                    Text(L10n.tr("agent.creation.emojiPicker.title"))
                        .font(.headline)
                        .foregroundStyle(.primary)

                    HStack {
                        Spacer(minLength: 0)
                        actionButton(
                            title: L10n.tr("common.done"),
                            role: .primary,
                            action: { isEmojiPickerPresented = false }
                        )
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 12)
            #endif

            emojiPickerGrid
        }
    }

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
            viewModel.setAgentEmoji(emoji)
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
        L10n.tr("agent.creation.create")
    }

    private var canPerformPrimaryAction: Bool {
        viewModel.canComplete
    }

    private func performPrimaryAction() {
        Task {
            await createAgent()
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
}

#Preview {
    AgentCreationView(onComplete: {})
        .environment(\.appContainerStore, AppContainerStore(container: .makeDefault()))
}
