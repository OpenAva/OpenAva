import ChatUI
import SwiftUI

struct ContextSettingsView: View {
    @Environment(\.appContainerStore) private var containerStore
    @State private var viewModel = ContextSettingsViewModel()

    var body: some View {
        List {
            Section {
                ForEach(AgentContextDocumentKind.allCases) { kind in
                    NavigationLink(destination: ContextDocumentEditorView(kind: kind, viewModel: viewModel)) {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                ZStack {
                                    Circle()
                                        .fill(sectionTint(for: kind).opacity(0.16))
                                        .frame(width: 16, height: 16)
                                    Circle()
                                        .fill(sectionTint(for: kind))
                                        .frame(width: 6, height: 6)
                                }

                                Text(kind.fileName)
                                    .font(.system(size: 16, weight: .regular))
                                    .foregroundStyle(Color(uiColor: ChatUIDesign.Color.offBlack))
                                    .tracking(-0.2)
                            }

                            Text(kind.localizedPurpose)
                                .font(.system(size: 14))
                                .foregroundStyle(Color(uiColor: ChatUIDesign.Color.black60))
                                .lineSpacing(2)
                        }
                        .padding(.vertical, 8)
                    }
                    .listRowBackground(Color(uiColor: ChatUIDesign.Color.pureWhite))
                }
            }

            if let errorText = viewModel.errorText {
                Section {
                    Text(errorText)
                        .font(.system(size: 14))
                        .foregroundStyle(.red)
                }
                .listRowBackground(Color.clear)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color(uiColor: ChatUIDesign.Color.warmCream).ignoresSafeArea())
        .navigationTitle(L10n.tr("settings.context.navigationTitle"))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            viewModel.load(workspaceRootURL: containerStore.activeAgentWorkspaceURL)
        }
        .onChange(of: containerStore.activeAgent?.id.uuidString ?? "") { _, _ in
            viewModel.load(workspaceRootURL: containerStore.activeAgentWorkspaceURL)
        }
    }

    private func sectionTint(for kind: AgentContextDocumentKind) -> Color {
        switch kind {
        case .agents: return .blue
        case .heartbeat: return .orange
        case .soul: return .purple
        case .tools: return .green
        case .identity: return .indigo
        case .user: return .pink
        }
    }
}

private struct ContextDocumentEditorView: View {
    let kind: AgentContextDocumentKind
    @Bindable var viewModel: ContextSettingsViewModel

    @State private var showApplyTemplateDialog = false
    @State private var showResetDialog = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: Binding(
                get: { viewModel.content(for: kind) },
                set: { viewModel.updateContent($0, for: kind) }
            ))
            .font(.system(size: 14, weight: .regular, design: .monospaced))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .scrollContentBackground(.hidden)
            .background(Color(uiColor: ChatUIDesign.Color.pureWhite))
            .padding(16)

            if viewModel.content(for: kind).isEmpty {
                Text(L10n.tr("settings.context.emptyPlaceholder"))
                    .font(.system(size: 14))
                    .foregroundStyle(Color(uiColor: ChatUIDesign.Color.contentTertiary))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 24)
                    .allowsHitTesting(false)
            }
        }
        .background(Color(uiColor: ChatUIDesign.Color.pureWhite).ignoresSafeArea())
        .navigationTitle(kind.fileName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if let document = viewModel.document(for: kind), document.hasTemplateContent {
                        Button(role: .destructive) {
                            showApplyTemplateDialog = true
                        } label: {
                            Label(L10n.tr("settings.context.applyTemplate"), systemImage: "doc.text")
                        }
                    }

                    Button(role: .destructive) {
                        showResetDialog = true
                    } label: {
                        Label(L10n.tr("common.reset"), systemImage: "arrow.counterclockwise")
                    }
                    .disabled(viewModel.content(for: kind).isEmpty)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .confirmationDialog(
            L10n.tr("settings.context.applyTemplate.confirmTitle"),
            isPresented: $showApplyTemplateDialog,
            titleVisibility: .visible
        ) {
            Button(L10n.tr("common.apply"), role: .destructive) {
                viewModel.applyTemplate(for: kind)
            }
            Button(L10n.tr("common.cancel"), role: .cancel) {}
        } message: {
            Text(L10n.tr("settings.context.applyTemplate.message", kind.fileName))
        }
        .confirmationDialog(
            L10n.tr("settings.context.reset.confirmTitle"),
            isPresented: $showResetDialog,
            titleVisibility: .visible
        ) {
            Button(L10n.tr("common.reset"), role: .destructive) {
                viewModel.resetContent(for: kind)
            }
            Button(L10n.tr("common.cancel"), role: .cancel) {}
        } message: {
            Text(L10n.tr("settings.context.reset.message", kind.fileName))
        }
    }
}

#Preview {
    NavigationStack {
        ContextSettingsView()
    }
}
