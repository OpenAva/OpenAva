import Foundation
import SwiftUI

struct SkillListView: View {
    @Environment(\.appContainerStore) private var containerStore
    @State private var skills: [SkillListItem] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    @State private var editorPresentation: SkillEditorPresentation?
    @State private var feedbackBanner: SkillFeedbackBanner?

    @State private var skillToDelete: SkillListItem?

    var body: some View {
        Group {
            #if targetEnvironment(macCatalyst)
                Group {
                    if let presentation = editorPresentation {
                        HStack(spacing: 0) {
                            skillList
                                .frame(minWidth: 300, idealWidth: 340)

                            skillDetail(for: presentation)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background(Color.white)
                        }
                        .background(Color.white)
                    } else {
                        skillList
                    }
                }
                .navigationTitle(L10n.tr("settings.skills.navigationTitle"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button {
                            presentCreateEditor()
                        } label: {
                            Label(L10n.tr("settings.skills.addSkill"), systemImage: "plus")
                        }
                    }
                }
                .background(Color.white)
            #else
                skillList
                    .navigationTitle(L10n.tr("settings.skills.navigationTitle"))
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Button {
                                presentCreateEditor()
                            } label: {
                                Label(L10n.tr("settings.skills.addSkill"), systemImage: "plus")
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .sheet(item: $editorPresentation) { presentation in
                        NavigationStack {
                            SkillEditorSheet(
                                mode: presentation.mode,
                                initialName: presentation.skill?.displayName ?? "",
                                initialContent: presentation.initialContent,
                                onSave: { name, content in
                                    guard presentation.mode.supportsSaving else {
                                        editorPresentation = nil
                                        return
                                    }

                                    let outcome = try saveSkill(
                                        name: name,
                                        content: content,
                                        mode: presentation.mode,
                                        targetSkill: presentation.skill
                                    )
                                    editorPresentation = nil
                                    refreshSkills(force: true)
                                    showFeedback(for: outcome)
                                },
                                onCancel: {
                                    editorPresentation = nil
                                }
                            )
                        }
                    }
            #endif
        }
        .confirmationDialog(
            L10n.tr("settings.skills.delete.confirmTitle"),
            isPresented: deleteDialogBinding,
            titleVisibility: .visible,
            presenting: skillToDelete
        ) { skill in
            Button(L10n.tr("common.delete"), role: .destructive) {
                removeSkill(skill)
            }
            Button(L10n.tr("common.cancel"), role: .cancel) {
                skillToDelete = nil
            }
        } message: { skill in
            Text(L10n.tr("settings.skills.delete.message", skill.displayName))
        }
        .alert(L10n.tr("settings.skills.error.title"), isPresented: errorAlertBinding) {
            Button(L10n.tr("common.ok"), role: .cancel) {
                errorMessage = nil
            }
        } message: {
            Text(errorMessage ?? L10n.tr("common.unknownError"))
        }
        .refreshable {
            refreshSkills(force: true)
        }
        .task {
            refreshSkills(force: false)
        }
        .onChange(of: containerStore.activeAgent?.id.uuidString ?? "") { _, _ in
            refreshSkills(force: true)
        }
        .safeAreaInset(edge: .bottom) {
            if let feedbackBanner {
                FeedbackBannerView(banner: feedbackBanner)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: feedbackBanner?.id)
    }

    private var skillList: some View {
        List {
            #if targetEnvironment(macCatalyst)
                Text(L10n.tr("settings.skills.workspace.header"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(nil)
                    .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 6, trailing: 12))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)

                workspaceSkillRows

                if !workspaceSkills.isEmpty {
                    Text(workspaceFooterText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 12, trailing: 12))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }

                Text(L10n.tr("settings.skills.builtin.header"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(nil)
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 6, trailing: 12))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)

                builtInSkillRows

                Text(L10n.tr("settings.skills.builtin.footer"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 10, trailing: 12))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            #else
                Section {
                    workspaceSkillRows
                } header: {
                    Text(L10n.tr("settings.skills.workspace.header"))
                } footer: {
                    if !workspaceSkills.isEmpty {
                        Text(workspaceFooterText)
                    }
                }

                Section {
                    builtInSkillRows
                } header: {
                    Text(L10n.tr("settings.skills.builtin.header"))
                } footer: {
                    Text(L10n.tr("settings.skills.builtin.footer"))
                }
            #endif
        }
        #if targetEnvironment(macCatalyst)
        .listStyle(.plain)
        #else
        .listStyle(.insetGrouped)
        #endif
        .scrollContentBackground(.hidden)
        .background(Color.white)
    }

    @ViewBuilder
    private var workspaceSkillRows: some View {
        if isLoading, workspaceSkills.isEmpty {
            ProgressView()
                .frame(maxWidth: .infinity)
                .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        } else if workspaceSkills.isEmpty {
            EmptySkillsView(
                message: L10n.tr("settings.skills.emptyWorkspace.message")
            )
            .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        } else {
            ForEach(workspaceSkills) { skill in
                SkillRow(
                    skill: skill,
                    isEnabled: skillEnabledBinding(for: skill),
                    onOpen: {
                        presentEditEditor(for: skill)
                    }
                )
                .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        skillToDelete = skill
                    } label: {
                        Label(L10n.tr("common.delete"), systemImage: "trash")
                    }
                }
                .contextMenu {
                    Button {
                        presentEditEditor(for: skill)
                    } label: {
                        Label(L10n.tr("common.edit"), systemImage: "pencil")
                    }

                    Button(role: .destructive) {
                        skillToDelete = skill
                    } label: {
                        Label(L10n.tr("common.delete"), systemImage: "trash")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var builtInSkillRows: some View {
        if builtInSkills.isEmpty {
            EmptySkillsView(message: L10n.tr("settings.skills.emptyBuiltin.message"))
                .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        } else {
            ForEach(builtInSkills) { skill in
                SkillRow(
                    skill: skill,
                    isEnabled: skillEnabledBinding(for: skill),
                    onOpen: {
                        presentReadOnlyDetail(for: skill)
                    }
                )
                .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .contextMenu {
                    Button {
                        presentReadOnlyDetail(for: skill)
                    } label: {
                        Label(L10n.tr("common.edit"), systemImage: "doc.text.magnifyingglass")
                    }
                }
            }
        }
    }

    #if targetEnvironment(macCatalyst)
        private func skillDetail(for presentation: SkillEditorPresentation) -> some View {
            SkillEditorSheet(
                mode: presentation.mode,
                initialName: presentation.skill?.displayName ?? "",
                initialContent: presentation.initialContent,
                onSave: { name, content in
                    guard presentation.mode.supportsSaving else {
                        editorPresentation = nil
                        return
                    }

                    let outcome = try saveSkill(
                        name: name,
                        content: content,
                        mode: presentation.mode,
                        targetSkill: presentation.skill
                    )
                    refreshSkills(force: true)
                    showFeedback(for: outcome)
                },
                onCancel: {
                    editorPresentation = nil
                },
                presentationStyle: .embedded
            )
            .id(presentation.id)
        }
    #endif

    private var workspaceSkills: [SkillListItem] {
        skills.filter(\.isWorkspace)
    }

    private var workspaceFooterText: String {
        #if targetEnvironment(macCatalyst)
            L10n.tr("settings.skills.workspace.footer.mac")
        #else
            L10n.tr("settings.skills.workspace.footer")
        #endif
    }

    private var builtInSkills: [SkillListItem] {
        skills.filter { !$0.isWorkspace }
    }

    private var deleteDialogBinding: Binding<Bool> {
        Binding(
            get: { skillToDelete != nil },
            set: { isPresented in
                if !isPresented {
                    skillToDelete = nil
                }
            }
        )
    }

    private var errorAlertBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    errorMessage = nil
                }
            }
        )
    }

    private func presentCreateEditor() {
        editorPresentation = SkillEditorPresentation(
            mode: .create,
            skill: nil,
            initialContent: Self.defaultSkillTemplate
        )
    }

    private func presentEditEditor(for skill: SkillListItem) {
        do {
            let content = try String(contentsOfFile: skill.path, encoding: .utf8)
            editorPresentation = SkillEditorPresentation(
                mode: .edit,
                skill: skill,
                initialContent: content
            )
        } catch {
            showError(error)
        }
    }

    private func presentReadOnlyDetail(for skill: SkillListItem) {
        do {
            let content = try String(contentsOfFile: skill.path, encoding: .utf8)
            editorPresentation = SkillEditorPresentation(
                mode: .view,
                skill: skill,
                initialContent: content
            )
        } catch {
            showError(error)
        }
    }

    private func refreshSkills(force: Bool) {
        if isLoading, !force {
            return
        }

        isLoading = true
        defer { self.isLoading = false }

        do {
            _ = try workspaceSkillsDirectory()

            let workspaceRoot = containerStore.activeAgentWorkspaceURL
            let allSkills = AgentSkillsLoader.listSkills(
                filterUnavailable: false,
                includeDisabled: true,
                workspaceRootURL: workspaceRoot
            )
            let availableNames = Set(AgentSkillsLoader.listSkills(
                filterUnavailable: true,
                includeDisabled: true,
                workspaceRootURL: workspaceRoot
            ).map(\.name))
            skills = allSkills.map { skill in
                SkillListItem(
                    name: skill.name,
                    displayName: skill.displayName,
                    path: skill.path,
                    source: skill.source,
                    description: skill.description,
                    emoji: skill.emoji,
                    isAvailable: availableNames.contains(skill.name),
                    isEnabled: AgentSkillToggleStore.isEnabled(skill, workspaceRootURL: workspaceRoot)
                )
            }
        } catch {
            showError(error)
        }
    }

    private func saveSkill(
        name: String,
        content: String,
        mode: SkillEditorSheet.Mode,
        targetSkill: SkillListItem?
    ) throws -> SkillSaveOutcome {
        switch mode {
        case .create:
            try createSkill(name: name, content: content)
            return .created(name)
        case .edit:
            guard let target = targetSkill else {
                throw SkillManagementError.missingEditTarget
            }
            try updateSkill(target, content: content)
            return .saved(target.displayName)
        case .view:
            throw SkillManagementError.readOnlySkill
        }
    }

    private func createSkill(name: String, content: String) throws {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        try validateSkillName(normalizedName)

        let skillsRoot = try workspaceSkillsDirectory()
        let skillDirectory = skillsRoot.appendingPathComponent(normalizedName, isDirectory: true)
        let fileManager = FileManager.default

        guard !fileManager.fileExists(atPath: skillDirectory.path) else {
            throw SkillManagementError.skillAlreadyExists(normalizedName)
        }

        try fileManager.createDirectory(at: skillDirectory, withIntermediateDirectories: true)
        let skillFile = skillDirectory.appendingPathComponent("SKILL.md", isDirectory: false)
        try content.write(to: skillFile, atomically: true, encoding: .utf8)
    }

    private func updateSkill(_ skill: SkillListItem, content: String) throws {
        guard skill.isWorkspace else {
            throw SkillManagementError.readOnlySkill
        }

        let skillFile = URL(fileURLWithPath: skill.path, isDirectory: false)
        try ensurePathInWorkspaceSkills(skillFile.deletingLastPathComponent())
        try content.write(to: skillFile, atomically: true, encoding: .utf8)
    }

    private func removeSkill(_ skill: SkillListItem) {
        do {
            guard skill.isWorkspace else {
                throw SkillManagementError.readOnlySkill
            }

            let skillDirectory = URL(fileURLWithPath: skill.path, isDirectory: false).deletingLastPathComponent()
            // Protect against deleting files outside the workspace skills directory.
            try ensurePathInWorkspaceSkills(skillDirectory)

            try FileManager.default.removeItem(at: skillDirectory)
            skillToDelete = nil
            refreshSkills(force: true)
            showFeedback(for: .deleted(skill.displayName))
        } catch {
            showError(error)
        }
    }

    private func validateSkillName(_ name: String) throws {
        guard !name.isEmpty else {
            throw SkillManagementError.invalidName(L10n.tr("settings.skills.error.invalidName.empty"))
        }

        let pattern = "^[A-Za-z0-9][A-Za-z0-9_-]*$"
        guard name.range(of: pattern, options: .regularExpression) != nil else {
            throw SkillManagementError.invalidName(L10n.tr("settings.skills.error.invalidName.format"))
        }
    }

    private func workspaceSkillsDirectory() throws -> URL {
        let rootURL = try AgentContextLoader.editableRootDirectory(
            workspaceRootURL: containerStore.activeAgentWorkspaceURL
        )
        let skillsURL = rootURL.appendingPathComponent("skills", isDirectory: true)
        try FileManager.default.createDirectory(at: skillsURL, withIntermediateDirectories: true)
        return skillsURL
    }

    private func ensurePathInWorkspaceSkills(_ candidateDirectory: URL) throws {
        let workspaceSkillsRoot = try workspaceSkillsDirectory().standardizedFileURL.path
        let candidatePath = candidateDirectory.standardizedFileURL.path
        guard candidatePath.hasPrefix(workspaceSkillsRoot + "/") else {
            throw SkillManagementError.invalidSkillPath
        }
    }

    private func showError(_ error: Error) {
        errorMessage = error.localizedDescription
    }

    private func skillEnabledBinding(for skill: SkillListItem) -> Binding<Bool> {
        Binding(
            get: {
                skills.first(where: { $0.id == skill.id })?.isEnabled ?? skill.isEnabled
            },
            set: { isEnabled in
                updateSkillEnabledState(for: skill, isEnabled: isEnabled)
            }
        )
    }

    private func updateSkillEnabledState(for skill: SkillListItem, isEnabled: Bool) {
        AgentSkillToggleStore.setEnabled(
            isEnabled,
            for: skill.record,
            workspaceRootURL: containerStore.activeAgentWorkspaceURL
        )

        guard let index = skills.firstIndex(where: { $0.id == skill.id }) else {
            refreshSkills(force: true)
            return
        }

        // Keep the list state in sync so the toggle does not wait for a full refresh.
        skills[index].isEnabled = isEnabled
        showFeedback(for: isEnabled ? .enabled(skill.displayName) : .disabled(skill.displayName))
    }

    private func showFeedback(for outcome: SkillSaveOutcome) {
        let banner = SkillFeedbackBanner(outcome: outcome)
        feedbackBanner = banner

        Task {
            try? await Task.sleep(for: .seconds(2))
            guard feedbackBanner?.id == banner.id else {
                return
            }

            await MainActor.run {
                feedbackBanner = nil
            }
        }
    }

    private static let defaultSkillTemplate = """
    ---
    description: Briefly describe what this skill does.
    metadata:
      emoji: 🧩
    ---

    # Purpose

    Describe when and why this skill should be used.

    # Steps

    1. Add clear execution steps.
    2. Keep outputs actionable.
    """
}

private struct SkillEditorPresentation: Identifiable {
    let mode: SkillEditorSheet.Mode
    let skill: SkillListItem?
    let initialContent: String

    var id: String {
        [mode.id, skill?.id ?? "new", String(initialContent.hashValue)].joined(separator: "-")
    }
}

private enum SkillSaveOutcome {
    case created(String)
    case saved(String)
    case deleted(String)
    case enabled(String)
    case disabled(String)
}

private struct SkillFeedbackBanner: Identifiable {
    let id = UUID()
    let message: String
    let systemImage: String

    init(outcome: SkillSaveOutcome) {
        switch outcome {
        case let .created(name):
            message = L10n.tr("settings.skills.feedback.created", name)
        case let .saved(name):
            message = L10n.tr("settings.skills.feedback.saved", name)
        case let .deleted(name):
            message = L10n.tr("settings.skills.feedback.deleted", name)
        case let .enabled(name):
            message = L10n.tr("settings.skills.feedback.enabled", name)
        case let .disabled(name):
            message = L10n.tr("settings.skills.feedback.disabled", name)
        }

        systemImage = "checkmark.circle.fill"
    }
}

private struct SkillListItem: Identifiable, Equatable {
    let name: String
    let displayName: String
    let path: String
    let source: String
    let description: String
    let emoji: String?
    let isAvailable: Bool
    var isEnabled: Bool

    var id: String {
        "\(source)-\(name)"
    }

    var isWorkspace: Bool {
        source == "workspace"
    }

    var record: AgentSkillsLoader.SkillRecord {
        AgentSkillsLoader.SkillRecord(
            name: name,
            displayName: displayName,
            path: path,
            source: source,
            description: description,
            emoji: emoji
        )
    }
}

private enum SkillManagementError: LocalizedError {
    case missingEditTarget
    case readOnlySkill
    case invalidName(String)
    case skillAlreadyExists(String)
    case invalidSkillPath

    var errorDescription: String? {
        switch self {
        case .missingEditTarget:
            return L10n.tr("settings.skills.error.missingEditTarget")
        case .readOnlySkill:
            return L10n.tr("settings.skills.error.readOnly")
        case let .invalidName(reason):
            return L10n.tr("settings.skills.error.invalidName", reason)
        case let .skillAlreadyExists(name):
            return L10n.tr("settings.skills.error.alreadyExists", name)
        case .invalidSkillPath:
            return L10n.tr("settings.skills.error.invalidPath")
        }
    }
}

private struct SkillEditorSheet: View {
    enum Mode {
        case create
        case edit
        case view

        var id: String {
            switch self {
            case .create:
                return "create"
            case .edit:
                return "edit"
            case .view:
                return "view"
            }
        }

        var title: String {
            switch self {
            case .create:
                return L10n.tr("settings.skills.editor.newTitle")
            case .edit:
                return L10n.tr("settings.skills.editor.editTitle")
            case .view:
                return L10n.tr("settings.skills.editor.viewTitle")
            }
        }

        var actionTitle: String {
            switch self {
            case .create:
                return L10n.tr("common.create")
            case .edit:
                return L10n.tr("common.save")
            case .view:
                return L10n.tr("common.done")
            }
        }

        var isNameEditable: Bool {
            switch self {
            case .create:
                return true
            case .edit:
                return false
            case .view:
                return false
            }
        }

        var isMetadataEditable: Bool {
            switch self {
            case .create, .edit:
                return true
            case .view:
                return false
            }
        }

        var isContentEditable: Bool {
            switch self {
            case .create, .edit:
                return true
            case .view:
                return false
            }
        }

        var supportsSaving: Bool {
            switch self {
            case .create, .edit:
                return true
            case .view:
                return false
            }
        }
    }

    enum PresentationStyle {
        case modal
        case embedded
    }

    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var description: String
    @State private var emoji: String
    @State private var content: String
    @State private var errorText: String?

    let mode: Mode
    let onSave: (String, String) throws -> Void
    let onCancel: (() -> Void)?
    let presentationStyle: PresentationStyle

    init(
        mode: Mode,
        initialName: String,
        initialContent: String,
        onSave: @escaping (String, String) throws -> Void,
        onCancel: (() -> Void)? = nil,
        presentationStyle: PresentationStyle = .modal
    ) {
        self.mode = mode
        self.onSave = onSave
        self.onCancel = onCancel
        self.presentationStyle = presentationStyle
        _name = State(initialValue: initialName)
        _description = State(initialValue: Self.frontmatterValue(for: "description", in: initialContent) ?? "")
        _emoji = State(initialValue: Self.frontmatterValue(for: "metadata.emoji", in: initialContent) ?? Self.frontmatterValue(for: "emoji", in: initialContent) ?? "")
        _content = State(initialValue: initialContent)
    }

    var body: some View {
        Form {
            Section(L10n.tr("settings.skills.editor.section.skill")) {
                if mode.isNameEditable {
                    TextField(L10n.tr("settings.skills.editor.skillName"), text: $name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .settingsInputFieldStyle()

                    if let nameValidationMessage {
                        Text(nameValidationMessage)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    } else {
                        Text(L10n.tr("settings.skills.error.invalidName.format"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    LabeledContent(L10n.tr("common.name")) {
                        Text(name)
                    }
                }
            }

            if mode.isMetadataEditable {
                Section {
                    LabeledContent(L10n.tr("common.description")) {
                        TextField("", text: $description)
                            .textInputAutocapitalization(.sentences)
                            .settingsInputFieldStyle()
                    }

                    LabeledContent(L10n.tr("settings.skills.editor.emoji")) {
                        TextField("", text: $emoji)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .settingsInputFieldStyle()
                    }
                } header: {
                    Text(L10n.tr("settings.skills.editor.section.metadata"))
                } footer: {
                    Text(L10n.tr("settings.skills.editor.metadata.footer"))
                }
            } else {
                Section {
                    LabeledContent(L10n.tr("common.description")) {
                        Text(description.isEmpty ? L10n.tr("common.unknown") : description)
                            .foregroundStyle(.secondary)
                    }

                    LabeledContent(L10n.tr("settings.skills.editor.emoji")) {
                        Text(emoji.isEmpty ? L10n.tr("common.unknown") : emoji)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text(L10n.tr("settings.skills.editor.section.metadata"))
                } footer: {
                    Text(L10n.tr("settings.skills.editor.readOnlyFooter"))
                }
            }

            Section {
                TextEditor(text: $content)
                    .frame(minHeight: 280)
                    .font(.body.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .disabled(!mode.isContentEditable)
                    .padding(8)
                    .background(
                        Color(uiColor: .secondarySystemBackground),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
            } header: {
                Text(L10n.tr("settings.skills.editor.section.file"))
            } footer: {
                Text(mode.isContentEditable ? L10n.tr("settings.skills.editor.file.footer") : L10n.tr("settings.skills.editor.readOnlyFileFooter"))
            }

            if let errorText {
                Section {
                    Text(errorText)
                        .foregroundStyle(.red)
                }
            }
        }
        #if targetEnvironment(macCatalyst)
        .scrollContentBackground(.hidden)
        .background(Color.white)
        #endif
        .navigationTitle(mode.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(mode.supportsSaving ? L10n.tr("common.cancel") : L10n.tr("common.done")) {
                    cancelEditing()
                }
            }

            if mode.supportsSaving {
                ToolbarItem(placement: .confirmationAction) {
                    Button(mode.actionTitle) {
                        commit()
                    }
                    .disabled(!canSave)
                }
            }
        }
    }

    private var canSave: Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if mode.isNameEditable {
            return !trimmedName.isEmpty && nameValidationMessage == nil && !trimmedContent.isEmpty
        }
        return !trimmedContent.isEmpty
    }

    private var nameValidationMessage: String? {
        guard mode.isNameEditable else {
            return nil
        }

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedName.isEmpty {
            return L10n.tr("settings.skills.error.invalidName.empty")
        }

        let pattern = "^[A-Za-z0-9][A-Za-z0-9_-]*$"
        if trimmedName.range(of: pattern, options: .regularExpression) == nil {
            return L10n.tr("settings.skills.error.invalidName.formatShort")
        }

        return nil
    }

    private func commit() {
        errorText = nil
        do {
            let contentToSave = applyEditableMetadata(to: content)
            try onSave(name, contentToSave)
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func cancelEditing() {
        onCancel?()
        if presentationStyle == .modal {
            dismiss()
        }
    }

    private func applyEditableMetadata(to content: String) -> String {
        // Keep frontmatter metadata aligned with form inputs.
        var normalized = content.replacingOccurrences(of: "\r\n", with: "\n")

        normalized = Self.upsertFrontmatterValue(
            in: normalized,
            key: "description",
            value: description.trimmingCharacters(in: .whitespacesAndNewlines)
        )

        normalized = Self.upsertFrontmatterValue(
            in: normalized,
            key: "metadata.emoji",
            value: emoji.trimmingCharacters(in: .whitespacesAndNewlines)
        )

        return normalized
    }

    private static func frontmatterValue(for key: String, in content: String) -> String? {
        if key.contains(".") {
            return nestedFrontmatterValue(for: key, in: content)
        }

        let normalized = content.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else {
            return nil
        }

        for line in lines.dropFirst() {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            if trimmedLine == "---" {
                break
            }

            guard let separatorIndex = trimmedLine.firstIndex(of: ":") else {
                continue
            }

            let rawKey = trimmedLine[..<separatorIndex].trimmingCharacters(in: .whitespaces).lowercased()
            guard rawKey == key.lowercased() else {
                continue
            }

            let valueStart = trimmedLine.index(after: separatorIndex)
            return trimmedLine[valueStart...]
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }

        return nil
    }

    private static func nestedFrontmatterValue(for keyPath: String, in content: String) -> String? {
        let components = keyPath
            .split(separator: ".", maxSplits: 1)
            .map(String.init)
        guard components.count == 2 else {
            return nil
        }

        let parentKey = components[0].lowercased()
        let childKey = components[1].lowercased()
        let normalized = content.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else {
            return nil
        }

        var index = 1
        while index < lines.count {
            let line = lines[index]
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            if trimmedLine == "---" {
                break
            }

            guard let separatorIndex = trimmedLine.firstIndex(of: ":") else {
                index += 1
                continue
            }

            let key = trimmedLine[..<separatorIndex].trimmingCharacters(in: .whitespaces).lowercased()
            guard key == parentKey else {
                index += 1
                continue
            }

            let valueStart = trimmedLine.index(after: separatorIndex)
            let parentInlineValue = trimmedLine[valueStart...].trimmingCharacters(in: .whitespaces)
            guard parentInlineValue.isEmpty else {
                return nil
            }

            index += 1
            while index < lines.count {
                let nestedLine = lines[index]
                let nestedTrimmed = nestedLine.trimmingCharacters(in: .whitespaces)
                if nestedTrimmed == "---" || leadingWhitespaceCount(in: nestedLine) == 0 {
                    return nil
                }

                guard let nestedSeparator = nestedTrimmed.firstIndex(of: ":") else {
                    index += 1
                    continue
                }

                let nestedKey = nestedTrimmed[..<nestedSeparator].trimmingCharacters(in: .whitespaces).lowercased()
                if nestedKey == childKey {
                    let valueStart = nestedTrimmed.index(after: nestedSeparator)
                    return nestedTrimmed[valueStart...]
                        .trimmingCharacters(in: .whitespaces)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                }

                index += 1
            }
        }

        return nil
    }

    private static func upsertFrontmatterValue(in content: String, key: String, value: String) -> String {
        let lines = content.components(separatedBy: "\n")

        var bodyLines = lines
        var metadataLines: [String] = []

        if lines.first?.trimmingCharacters(in: .whitespaces) == "---" {
            var endIndex: Int?
            for index in 1 ..< lines.count where lines[index].trimmingCharacters(in: .whitespaces) == "---" {
                endIndex = index
                break
            }

            if let endIndex {
                metadataLines = Array(lines[1 ..< endIndex])
                bodyLines = Array(lines[(endIndex + 1)...])
            }
        }

        var didUpdate = false
        var updatedMetadata = metadataLines.map { line -> String in
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            guard let separatorIndex = trimmedLine.firstIndex(of: ":") else {
                return line
            }

            let rawKey = trimmedLine[..<separatorIndex].trimmingCharacters(in: .whitespaces).lowercased()
            guard rawKey == key.lowercased() else {
                return line
            }

            didUpdate = true
            return "\(key): \(value)"
        }

        if key.contains(".") {
            let components = key
                .split(separator: ".", maxSplits: 1)
                .map(String.init)
            if components.count == 2 {
                updatedMetadata = upsertNestedFrontmatterValue(
                    in: updatedMetadata,
                    parentKey: components[0],
                    childKey: components[1],
                    value: value
                )
                return (["---"] + updatedMetadata + ["---"] + bodyLines).joined(separator: "\n")
            }
        }

        if !didUpdate {
            updatedMetadata.append("\(key): \(value)")
        }

        return (["---"] + updatedMetadata + ["---"] + bodyLines).joined(separator: "\n")
    }

    private static func upsertNestedFrontmatterValue(
        in metadataLines: [String],
        parentKey: String,
        childKey: String,
        value: String
    ) -> [String] {
        let normalizedParent = parentKey.lowercased()
        let normalizedChild = childKey.lowercased()
        var lines = metadataLines

        func lineKey(_ line: String) -> String? {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let separator = trimmed.firstIndex(of: ":") else {
                return nil
            }
            return trimmed[..<separator].trimmingCharacters(in: .whitespaces).lowercased()
        }

        var parentIndex: Int?
        for index in lines.indices {
            if lineKey(lines[index]) == normalizedParent {
                parentIndex = index
                break
            }
        }

        if parentIndex == nil {
            lines.append("\(parentKey):")
            lines.append("  \(childKey): \(value)")
            return lines
        }

        guard let parentIndex else {
            return lines
        }

        let parentIndent = leadingWhitespaceCount(in: lines[parentIndex])
        let childIndent = String(repeating: " ", count: parentIndent + 2)
        var scanIndex = parentIndex + 1
        var blockEnd = lines.count
        var childLineIndex: Int?

        while scanIndex < lines.count {
            let candidate = lines[scanIndex]
            if candidate.trimmingCharacters(in: .whitespaces).isEmpty {
                scanIndex += 1
                continue
            }

            let indent = leadingWhitespaceCount(in: candidate)
            if indent <= parentIndent {
                blockEnd = scanIndex
                break
            }

            if indent == parentIndent + 2, lineKey(candidate) == normalizedChild {
                childLineIndex = scanIndex
            }

            scanIndex += 1
        }

        if let childLineIndex {
            lines[childLineIndex] = "\(childIndent)\(childKey): \(value)"
        } else {
            lines.insert("\(childIndent)\(childKey): \(value)", at: blockEnd)
        }

        return lines
    }

    private static func leadingWhitespaceCount(in line: String) -> Int {
        line.prefix { $0 == " " || $0 == "\t" }.count
    }
}

private extension View {
    func settingsInputFieldStyle() -> some View {
        padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                Color(uiColor: .secondarySystemBackground),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
    }
}

private struct SkillRow: View {
    let skill: SkillListItem
    @Binding var isEnabled: Bool
    var onOpen: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 14) {
            tappableContent

            HStack(spacing: 10) {
                if onOpen != nil {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }

                Toggle(L10n.tr("settings.skills.enabled"), isOn: $isEnabled)
                    .labelsHidden()
            }
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.6)
        )
        .animation(.easeInOut(duration: 0.2), value: isEnabled)
    }

    private var tappableContent: some View {
        HStack(spacing: 14) {
            skillIcon
            skillSummary
            Spacer(minLength: 8)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            onOpen?()
        }
    }

    private var skillIcon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: skill.isAvailable
                            ? [Color.accentColor.opacity(0.18), Color.accentColor.opacity(0.07)]
                            : [Color.orange.opacity(0.18), Color.orange.opacity(0.07)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 46, height: 46)
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(
                            skill.isAvailable
                                ? Color.accentColor.opacity(0.15)
                                : Color.orange.opacity(0.2),
                            lineWidth: 0.5
                        )
                )

            if let emoji = skill.emoji, !emoji.isEmpty {
                Text(emoji)
                    .font(.system(size: 22))
            } else {
                Image(systemName: skill.isAvailable ? "hammer.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(skill.isAvailable ? Color.accentColor : .orange)
            }
        }
    }

    private var skillSummary: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 7) {
                Text(skill.displayName)
                    .font(.system(.body, design: .default, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                if !skill.isWorkspace {
                    StatusBadge(
                        title: L10n.tr("settings.skills.readOnly"),
                        foreground: .secondary,
                        background: Color.secondary.opacity(0.1)
                    )
                }
            }

            if !skill.description.isEmpty {
                Text(skill.description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            if !skill.isAvailable || !isEnabled {
                HStack(spacing: 5) {
                    if !skill.isAvailable {
                        StatusBadge(
                            title: L10n.tr("settings.skills.unavailable"),
                            foreground: .orange,
                            background: Color.orange.opacity(0.12)
                        )
                    }

                    if !isEnabled {
                        StatusBadge(
                            title: L10n.tr("settings.skills.disabled"),
                            foreground: .secondary,
                            background: Color.secondary.opacity(0.1)
                        )
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct EmptySkillsView: View {
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkles.rectangle.stack")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(.tertiary)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }
}

private struct StatusBadge: View {
    let title: String
    let foreground: Color
    let background: Color

    var body: some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

private struct FeedbackBannerView: View {
    let banner: SkillFeedbackBanner

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.green.opacity(0.15))
                    .frame(width: 30, height: 30)

                Image(systemName: banner.systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.green)
            }

            Text(banner.message)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.07), radius: 14, y: 5)
    }
}

#Preview {
    NavigationStack {
        SkillListView()
    }
}
