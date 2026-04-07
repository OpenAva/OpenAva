import SwiftUI

struct ContextSettingsView: View {
    @Environment(\.appContainerStore) private var containerStore
    @State private var viewModel = ContextSettingsViewModel()
    @State private var templateTarget: AgentContextDocumentKind?
    @State private var resetTarget: AgentContextDocumentKind?

    var body: some View {
        Form {
            ForEach(AgentContextDocumentKind.allCases) { kind in
                sectionView(for: kind)
            }

            if let errorText = viewModel.errorText {
                Section {
                    Text(errorText)
                        .foregroundStyle(.red)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(L10n.tr("settings.context.navigationTitle"))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            viewModel.load(workspaceRootURL: containerStore.activeAgentWorkspaceURL)
        }
        .onChange(of: containerStore.activeAgent?.id.uuidString ?? "") { _, _ in
            viewModel.load(workspaceRootURL: containerStore.activeAgentWorkspaceURL)
        }
        .confirmationDialog(
            L10n.tr("settings.context.applyTemplate.confirmTitle"),
            isPresented: Binding(
                get: { templateTarget != nil },
                set: { if !$0 { templateTarget = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(L10n.tr("common.apply"), role: .destructive) {
                guard let templateTarget else { return }
                viewModel.applyTemplate(for: templateTarget)
                self.templateTarget = nil
            }
            Button(L10n.tr("common.cancel"), role: .cancel) {
                templateTarget = nil
            }
        } message: {
            if let templateTarget {
                Text(L10n.tr("settings.context.applyTemplate.message", templateTarget.fileName))
            }
        }
        .confirmationDialog(
            L10n.tr("settings.context.reset.confirmTitle"),
            isPresented: Binding(
                get: { resetTarget != nil },
                set: { if !$0 { resetTarget = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(L10n.tr("common.reset"), role: .destructive) {
                guard let resetTarget else { return }
                viewModel.resetContent(for: resetTarget)
                self.resetTarget = nil
            }
            Button(L10n.tr("common.cancel"), role: .cancel) {
                resetTarget = nil
            }
        } message: {
            if let resetTarget {
                Text(L10n.tr("settings.context.reset.message", resetTarget.fileName))
            }
        }
    }

    private func sectionView(for kind: AgentContextDocumentKind) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 16) {
                sectionHeader(for: kind)
                editorView(for: kind)
                sectionActions(for: kind)
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
        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }

    private func editorView(for kind: AgentContextDocumentKind) -> some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: Binding(
                get: { viewModel.content(for: kind) },
                set: { viewModel.updateContent($0, for: kind) }
            ))
            .font(.system(.body, design: .monospaced))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .scrollContentBackground(.hidden)
            .padding(.horizontal, 8)
            .padding(.vertical, 8)

            if viewModel.content(for: kind).isEmpty {
                Text(L10n.tr("settings.context.emptyPlaceholder"))
                    .font(.body)
                    .foregroundStyle(Color(uiColor: .tertiaryLabel))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 16)
                    .allowsHitTesting(false)
            }
        }
        .frame(minHeight: 160, maxHeight: 240)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(sectionTint(for: kind).opacity(0.12), lineWidth: 1.0)
        )
    }

    private func sectionHeader(for kind: AgentContextDocumentKind) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(sectionTint(for: kind).opacity(0.16))
                        .frame(width: 22, height: 22)

                    Circle()
                        .fill(sectionTint(for: kind))
                        .frame(width: 8, height: 8)
                }

                Text(kind.fileName)
                    .font(.headline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
                    .tracking(0.3)
            }

            Text(kind.localizedPurpose)
                .font(.subheadline)
                .foregroundStyle(Color(uiColor: .secondaryLabel))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .textCase(nil)
    }

    private func sectionActions(for kind: AgentContextDocumentKind) -> some View {
        HStack(alignment: .center, spacing: 12) {
            if let document = viewModel.document(for: kind), document.hasTemplateContent {
                actionButton(
                    title: L10n.tr("settings.context.applyTemplate"),
                    systemImage: "doc.text",
                    foregroundColor: .accentColor,
                    backgroundColor: Color.accentColor.opacity(0.14),
                    iconBackgroundColor: Color.accentColor.opacity(0.18),
                    borderColor: Color.accentColor.opacity(0.16)
                ) {
                    templateTarget = kind
                }
            }

            Spacer(minLength: 12)

            actionButton(
                title: L10n.tr("common.reset"),
                systemImage: "arrow.counterclockwise",
                foregroundColor: viewModel.content(for: kind).isEmpty ? Color(uiColor: .tertiaryLabel) : Color(uiColor: .secondaryLabel),
                backgroundColor: viewModel.content(for: kind).isEmpty ? Color(uiColor: .systemGray6) : Color(uiColor: .secondarySystemBackground),
                iconBackgroundColor: viewModel.content(for: kind).isEmpty ? Color(uiColor: .systemGray5) : Color.primary.opacity(0.08),
                borderColor: Color.primary.opacity(viewModel.content(for: kind).isEmpty ? 0.03 : 0.06),
                isDisabled: viewModel.content(for: kind).isEmpty
            ) {
                resetTarget = kind
            }
        }
    }

    private func actionButton(
        title: String,
        systemImage: String,
        foregroundColor: Color,
        backgroundColor: Color,
        iconBackgroundColor: Color,
        borderColor: Color = .clear,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 22, height: 22)
                    .background(iconBackgroundColor, in: Circle())

                Text(title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
            }
            .foregroundStyle(foregroundColor)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(backgroundColor)
            )
            .overlay(
                Capsule()
                    .strokeBorder(borderColor, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
    }

    private func sectionTint(for kind: AgentContextDocumentKind) -> Color {
        switch kind {
        case .agents:
            return .blue
        case .heartbeat:
            return .orange
        case .soul:
            return .purple
        case .tools:
            return .green
        case .identity:
            return .indigo
        case .user:
            return .pink
        }
    }
}

#Preview {
    NavigationStack {
        ContextSettingsView()
    }
}
