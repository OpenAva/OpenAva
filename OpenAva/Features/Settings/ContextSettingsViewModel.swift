import Foundation
import Observation

@MainActor
@Observable
final class ContextSettingsViewModel {
    struct DocumentState: Identifiable {
        let kind: AgentContextDocumentKind
        var content: String
        let templateContent: String?

        var id: String {
            kind.id
        }

        var hasTemplateContent: Bool {
            guard let templateContent else { return false }
            return !templateContent.isEmpty
        }
    }

    var documents: [DocumentState] = ContextSettingsViewModel.emptyDocuments()

    var rootPath = ""
    var errorText: String?
    var hasLoaded = false
    private var workspaceRootURL: URL?

    func load(workspaceRootURL: URL? = nil) {
        guard let workspaceRootURL else {
            // Context files are agent-scoped and must live in the active agent workspace.
            self.workspaceRootURL = nil
            rootPath = ""
            errorText = L10n.tr("settings.context.error.noActiveAgent")
            hasLoaded = true
            documents = Self.emptyDocuments()
            return
        }

        if self.workspaceRootURL != workspaceRootURL {
            hasLoaded = false
        }
        self.workspaceRootURL = workspaceRootURL
        guard !hasLoaded else { return }
        errorText = nil

        do {
            // Load context from editable root directory.
            let rootURL = try AgentContextLoader.editableRootDirectory(workspaceRootURL: workspaceRootURL)
            rootPath = rootURL.path
            documents = try AgentContextDocumentKind.agentSettingsCases.map { kind in
                try DocumentState(
                    kind: kind,
                    content: AgentContextLoader.loadEditableContent(
                        for: kind,
                        workspaceRootURL: workspaceRootURL
                    ),
                    templateContent: AgentContextLoader.templateContent(for: kind)
                )
            }
        } catch {
            errorText = error.localizedDescription
        }
        hasLoaded = true
    }

    func content(for kind: AgentContextDocumentKind) -> String {
        documents.first(where: { $0.kind == kind })?.content ?? ""
    }

    func document(for kind: AgentContextDocumentKind) -> DocumentState? {
        documents.first(where: { $0.kind == kind })
    }

    func updateContent(_ content: String, for kind: AgentContextDocumentKind) {
        guard let index = documents.firstIndex(where: { $0.kind == kind }) else {
            return
        }
        documents[index].content = content
        // Auto-save on every change.
        autoSave(content: content, for: kind)
    }

    func applyTemplate(for kind: AgentContextDocumentKind) {
        guard let index = documents.firstIndex(where: { $0.kind == kind }),
              let templateContent = documents[index].templateContent
        else {
            return
        }
        documents[index].content = templateContent
        // Applying a template should immediately persist the starter content.
        autoSave(content: templateContent, for: kind)
    }

    /// Reset content to empty for the given document kind.
    func resetContent(for kind: AgentContextDocumentKind) {
        guard let index = documents.firstIndex(where: { $0.kind == kind }) else {
            return
        }
        documents[index].content = ""
        // Persist the reset immediately.
        autoSave(content: "", for: kind)
    }

    private func autoSave(content: String, for kind: AgentContextDocumentKind) {
        guard workspaceRootURL != nil else {
            errorText = L10n.tr("settings.context.error.noActiveAgent")
            return
        }
        errorText = nil
        do {
            // Persist content changes immediately.
            try AgentContextLoader.saveEditableContent(
                content,
                for: kind,
                workspaceRootURL: workspaceRootURL
            )
        } catch {
            errorText = error.localizedDescription
        }
    }

    private static func emptyDocuments() -> [DocumentState] {
        AgentContextDocumentKind.agentSettingsCases.map { kind in
            DocumentState(kind: kind, content: "", templateContent: AgentContextLoader.templateContent(for: kind))
        }
    }
}
