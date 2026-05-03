import ChatUI
import SwiftUI

struct ContextSettingsView: View {
    let kind: AgentContextDocumentKind
    @Environment(\.appContainerStore) private var containerStore
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel = ContextSettingsViewModel()

    var body: some View {
        ContextDocumentEditorView(kind: kind, viewModel: viewModel)
            .navigationTitle(kind.fileName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.tr("common.cancel")) {
                        dismiss()
                    }
                }
            }
            .task {
                viewModel.load(workspaceRootURL: containerStore.activeAgentContextURL)
            }
            .onChange(of: containerStore.activeAgent?.id.uuidString ?? "") { _, _ in
                viewModel.load(workspaceRootURL: containerStore.activeAgentContextURL)
            }
    }
}

private extension AgentContextDocumentKind {
    var iconName: String {
        switch self {
        case .agents: return "slider.horizontal.3"
        case .heartbeat: return "waveform.path.ecg"
        case .soul: return "sparkles"
        case .tools: return "hammer.fill"
        case .identity: return "person.text.rectangle.fill"
        case .user: return "person.fill"
        }
    }

    var iconColor: Color {
        // Based on DESIGN.md: prefer warm neutrals, brand orange for AI/brand emphasis.
        // We use the design system's offBlack and pureWhite for high contrast, and brandOrange for "soul" (core AI personality)
        switch self {
        case .agents: return Color(uiColor: ChatUIDesign.Color.offBlack)
        case .heartbeat: return Color(uiColor: ChatUIDesign.Color.offBlack)
        case .soul: return Color(uiColor: ChatUIDesign.Color.brandOrange)
        case .tools: return Color(uiColor: ChatUIDesign.Color.offBlack)
        case .identity: return Color(uiColor: ChatUIDesign.Color.offBlack)
        case .user: return Color(uiColor: ChatUIDesign.Color.offBlack)
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
            .padding(16)

            if viewModel.content(for: kind).isEmpty {
                VStack(alignment: .leading, spacing: 16) {
                    Text(L10n.tr("settings.context.emptyPlaceholder"))
                        .font(.system(size: 15))
                        .foregroundStyle(Color(uiColor: ChatUIDesign.Color.black60))
                        .lineSpacing(4)
                        .allowsHitTesting(false)

                    if let document = viewModel.document(for: kind), document.hasTemplateContent {
                        Button {
                            viewModel.applyTemplate(for: kind)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "wand.and.stars")
                                Text(L10n.tr("settings.context.applyTemplate"))
                            }
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Color(uiColor: ChatUIDesign.Color.offBlack))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Color(uiColor: ChatUIDesign.Color.warmCream))
                            .clipShape(RoundedRectangle(cornerRadius: ChatUIDesign.Radius.button))
                            .overlay(
                                RoundedRectangle(cornerRadius: ChatUIDesign.Radius.button)
                                    .strokeBorder(Color(uiColor: ChatUIDesign.Color.oatBorder), lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 24)
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
        ContextSettingsView(kind: .agents)
    }
}
