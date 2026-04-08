import ChatUI
import SwiftUI

struct ContextSettingsView: View {
    @Environment(\.appContainerStore) private var containerStore
    @State private var viewModel = ContextSettingsViewModel()
    @State private var templateTarget: AgentContextDocumentKind?
    @State private var resetTarget: AgentContextDocumentKind?

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 40) {
                ForEach(AgentContextDocumentKind.allCases) { kind in
                    sectionView(for: kind)
                }

                if let errorText = viewModel.errorText {
                    Text(errorText)
                        .font(.system(size: 14))
                        .foregroundStyle(.red)
                        .padding(.horizontal, 20)
                }
            }
            .padding(.vertical, 32)
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
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(for: kind)
            editorView(for: kind)
            sectionActions(for: kind)
        }
        .padding(.horizontal, 20)
    }

    private func editorView(for kind: AgentContextDocumentKind) -> some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: Binding(
                get: { viewModel.content(for: kind) },
                set: { viewModel.updateContent($0, for: kind) }
            ))
            .font(.system(size: 14, weight: .regular, design: .monospaced))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .scrollContentBackground(.hidden)
            .padding(12)

            if viewModel.content(for: kind).isEmpty {
                Text(L10n.tr("settings.context.emptyPlaceholder"))
                    .font(.system(size: 14))
                    .foregroundStyle(Color(uiColor: ChatUIDesign.Color.contentTertiary))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 20)
                    .allowsHitTesting(false)
            }
        }
        .frame(minHeight: 160, maxHeight: 240)
        .background(Color(uiColor: ChatUIDesign.Color.pureWhite))
        .clipShape(RoundedRectangle(cornerRadius: ChatUIDesign.Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: ChatUIDesign.Radius.card, style: .continuous)
                .strokeBorder(Color(uiColor: ChatUIDesign.Color.oatBorder), lineWidth: 1.0)
        )
    }

    private func sectionHeader(for kind: AgentContextDocumentKind) -> some View {
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
    }

    private func sectionActions(for kind: AgentContextDocumentKind) -> some View {
        HStack(alignment: .center, spacing: 12) {
            if let document = viewModel.document(for: kind), document.hasTemplateContent {
                Button {
                    templateTarget = kind
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.text")
                            .font(.system(size: 12, weight: .regular))
                        Text(L10n.tr("settings.context.applyTemplate"))
                            .font(.system(size: 14, weight: .regular))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .foregroundStyle(Color(uiColor: ChatUIDesign.Color.pureWhite))
                    .background(Color(uiColor: ChatUIDesign.Color.offBlack))
                    .clipShape(RoundedRectangle(cornerRadius: ChatUIDesign.Radius.button, style: .continuous))
                }
                .buttonStyle(.plain)
            }

            Spacer(minLength: 12)

            let isEmpty = viewModel.content(for: kind).isEmpty
            Button {
                resetTarget = kind
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 12, weight: .regular))
                    Text(L10n.tr("common.reset"))
                        .font(.system(size: 14, weight: .regular))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .foregroundStyle(isEmpty ? Color(uiColor: ChatUIDesign.Color.black50) : Color(uiColor: ChatUIDesign.Color.offBlack))
                .background(Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: ChatUIDesign.Radius.button, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: ChatUIDesign.Radius.button, style: .continuous)
                        .strokeBorder(Color(uiColor: ChatUIDesign.Color.oatBorder), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .disabled(isEmpty)
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

#Preview {
    NavigationStack {
        ContextSettingsView()
    }
}
