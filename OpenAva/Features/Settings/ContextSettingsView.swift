import SwiftUI

struct ContextSettingsView: View {
    @Environment(\.appContainerStore) private var containerStore
    @State private var viewModel = ContextSettingsViewModel()
    @State private var templateTarget: AgentContextDocumentKind?
    @State private var showingResetAllConfirmation = false

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
        .background(Color.white)
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
            L10n.tr("settings.context.resetAll.confirmTitle"),
            isPresented: $showingResetAllConfirmation,
            titleVisibility: .visible
        ) {
            Button(L10n.tr("settings.context.resetAll.action"), role: .destructive) {
                viewModel.resetAllContent()
            }
            Button(L10n.tr("common.cancel"), role: .cancel) {}
        } message: {
            Text(L10n.tr("settings.context.resetAll.message"))
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showingResetAllConfirmation = true
                } label: {
                    Label(L10n.tr("settings.context.resetAll.action"), systemImage: "arrow.counterclockwise")
                }
                #if !targetEnvironment(macCatalyst)
                .buttonStyle(.bordered)
                #endif
                .disabled(viewModel.documents.allSatisfy(\.content.isEmpty))
            }
        }
    }

    private func sectionView(for kind: AgentContextDocumentKind) -> some View {
        Section {
            editorView(for: kind)
        } header: {
            sectionHeader(for: kind)
        }
    }

    private func editorView(for kind: AgentContextDocumentKind) -> some View {
        TextEditor(text: Binding(
            get: { viewModel.content(for: kind) },
            set: { viewModel.updateContent($0, for: kind) }
        ))
        .frame(height: 140)
        .font(.body.monospaced())
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .scrollContentBackground(.hidden)
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(uiColor: .tertiarySystemFill))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
    }

    private func sectionHeader(for kind: AgentContextDocumentKind) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(kind.fileName)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
                Text(kind.localizedPurpose)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .textCase(nil)

            Spacer()

            sectionActions(for: kind)
        }
        .padding(.vertical, 6)
    }

    private func sectionActions(for kind: AgentContextDocumentKind) -> some View {
        HStack(spacing: 16) {
            if let document = viewModel.document(for: kind), document.hasTemplateContent {
                Button {
                    templateTarget = kind
                } label: {
                    Label(L10n.tr("settings.context.applyTemplate"), systemImage: "square.and.arrow.down")
                        .font(.subheadline)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            }

            Button {
                viewModel.resetContent(for: kind)
            } label: {
                Label(L10n.tr("common.reset"), systemImage: "arrow.counterclockwise")
                    .font(.subheadline)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(viewModel.content(for: kind).isEmpty)
        }
        .textCase(nil)
    }
}

#Preview {
    NavigationStack {
        ContextSettingsView()
    }
}
