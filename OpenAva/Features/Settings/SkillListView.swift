import ChatUI
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
        skillList
            .navigationTitle(L10n.tr("settings.skills.navigationTitle"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        presentCreateEditor()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel(L10n.tr("settings.skills.addSkill"))
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

                            let outcome = try? saveSkill(
                                name: name,
                                content: content,
                                mode: presentation.mode,
                                targetSkill: presentation.skill
                            )
                            editorPresentation = nil
                            refreshSkills(force: true)
                            if let outcome {
                                showFeedback(for: outcome)
                            }
                        },
                        onCancel: {
                            editorPresentation = nil
                        }
                    )
                }
                #if targetEnvironment(macCatalyst)
                .frame(width: 640, height: 600)
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
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                SkillSection(
                    title: L10n.tr("settings.skills.workspace.header"),
                    detail: workspaceFooterText,
                    count: workspaceSkills.count
                ) {
                    workspaceSkillRows
                }

                SkillSection(
                    title: L10n.tr("settings.skills.builtin.header"),
                    detail: L10n.tr("settings.skills.builtin.footer"),
                    count: builtInSkills.count
                ) {
                    builtInSkillRows
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 24)
        }
        .scrollContentBackground(.hidden)
        .background(Color(uiColor: ChatUIDesign.Color.warmCream).ignoresSafeArea())
    }

    @ViewBuilder
    private var workspaceSkillRows: some View {
        if isLoading, workspaceSkills.isEmpty {
            SkillRowsCard {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
            }
        } else if workspaceSkills.isEmpty {
            EmptySkillsView(
                systemImage: "square.and.pencil",
                title: L10n.tr("settings.skills.emptyWorkspace.title"),
                actionTitle: L10n.tr("settings.skills.addSkill"),
                action: presentCreateEditor
            )
        } else {
            SkillRowsCard {
                ForEach(Array(workspaceSkills.enumerated()), id: \.element.id) { index, skill in
                    SkillRow(
                        skill: skill,
                        isEnabled: skillEnabledBinding(for: skill),
                        onOpen: {
                            presentEditEditor(for: skill)
                        },
                        onDelete: {
                            skillToDelete = skill
                        }
                    )
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
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button {
                            presentEditEditor(for: skill)
                        } label: {
                            Label(L10n.tr("common.edit"), systemImage: "pencil")
                        }
                        .tint(Color(uiColor: ChatUIDesign.Color.offBlack))

                        Button(role: .destructive) {
                            skillToDelete = skill
                        } label: {
                            Label(L10n.tr("common.delete"), systemImage: "trash")
                        }
                    }

                    if index < workspaceSkills.count - 1 {
                        SkillRowDivider()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var builtInSkillRows: some View {
        if builtInSkills.isEmpty {
            EmptySkillsView(
                systemImage: "shippingbox",
                title: L10n.tr("settings.skills.emptyBuiltin.title"),
                message: L10n.tr("settings.skills.emptyBuiltin.message")
            )
        } else {
            SkillRowsCard {
                ForEach(Array(builtInSkills.enumerated()), id: \.element.id) { index, skill in
                    SkillRow(
                        skill: skill,
                        isEnabled: skillEnabledBinding(for: skill),
                        onOpen: {
                            presentReadOnlyDetail(for: skill)
                        }
                    )
                    .contextMenu {
                        Button {
                            presentReadOnlyDetail(for: skill)
                        } label: {
                            Label(L10n.tr("common.edit"), systemImage: "doc.text.magnifyingglass")
                        }
                    }

                    if index < builtInSkills.count - 1 {
                        SkillRowDivider()
                    }
                }
            }
        }
    }

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
            SkillLauncherCatalogPublisher.publish(activeAgent: containerStore.activeAgent)
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
            for: skill.definition,
            workspaceRootURL: containerStore.activeAgentWorkspaceURL
        )

        guard let index = skills.firstIndex(where: { $0.id == skill.id }) else {
            refreshSkills(force: true)
            return
        }

        // Keep the list state in sync so the toggle does not wait for a full refresh.
        skills[index].isEnabled = isEnabled
        SkillLauncherCatalogPublisher.publish(activeAgent: containerStore.activeAgent)
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

    private static var defaultSkillTemplate: String {
        """
        ---
        user-invocable: true
        context: inline
        metadata:
          emoji: 🧩
        ---

        \(L10n.tr("settings.skills.editor.defaultTemplate.purpose"))
        """
    }
}

private struct SkillEditorPresentation: Identifiable {
    let mode: SkillEditorSheet.Mode
    let skill: SkillListItem?
    let initialContent: String

    var id: String {
        [mode.id, skill?.id ?? "new", String(initialContent.hashValue)].joined(separator: "-")
    }
}

private struct SkillSection<Content: View>: View {
    let title: String
    let detail: String
    let count: Int
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.system(size: 20, weight: .regular))
                        .tracking(-0.2)
                        .foregroundStyle(Color(uiColor: ChatUIDesign.Color.offBlack))

                    Text("\(count)")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color(uiColor: ChatUIDesign.Color.black60))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(Color(uiColor: ChatUIDesign.Color.pureWhite))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .strokeBorder(Color(uiColor: ChatUIDesign.Color.oatBorder), lineWidth: 1)
                        )
                }

                Spacer(minLength: 12)
            }

            Text(detail)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(Color(uiColor: ChatUIDesign.Color.black60))
                .fixedSize(horizontal: false, vertical: true)

            content()
        }
    }
}

private struct SkillRowsCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            content()
        }
        .background(
            RoundedRectangle(cornerRadius: ChatUIDesign.Radius.card, style: .continuous)
                .fill(Color(uiColor: ChatUIDesign.Color.pureWhite))
        )
        .overlay(
            RoundedRectangle(cornerRadius: ChatUIDesign.Radius.card, style: .continuous)
                .strokeBorder(Color(uiColor: ChatUIDesign.Color.oatBorder), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: ChatUIDesign.Radius.card, style: .continuous))
    }
}

private struct SkillRowDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color(uiColor: ChatUIDesign.Color.oatBorder))
            .frame(height: 1)
            .padding(.leading, 70)
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

    var definition: AgentSkillsLoader.SkillDefinition {
        AgentSkillsLoader.SkillDefinition(
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
    @State private var isEmojiPickerPresented = false
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
        Group {
            #if targetEnvironment(macCatalyst)
                VStack(spacing: 0) {
                    sheetTopBar()
                    formContent
                }
            #else
                formContent
                    .navigationTitle(mode.title)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(mode.supportsSaving ? L10n.tr("common.cancel") : L10n.tr("common.done")) {
                                cancelEditing()
                            }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            if mode.supportsSaving {
                                Button(mode.actionTitle) {
                                    commit()
                                }
                                .disabled(!canSave)
                            }
                        }
                    }
            #endif
        }
        .background(Color(uiColor: ChatUIDesign.Color.warmCream))
        .sheet(isPresented: $isEmojiPickerPresented) {
            NavigationStack {
                emojiPickerSheetContent
                    .navigationTitle(L10n.tr("agent.creation.emojiPicker.title"))
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button(L10n.tr("common.done")) {
                                isEmojiPickerPresented = false
                            }
                        }
                    }
            }
        }
    }

    private var formContent: some View {
        ScrollView {
            VStack(spacing: 24) {
                CustomSection {
                    if mode.isNameEditable {
                        labeledField(L10n.tr("settings.skills.editor.skillName")) {
                            VStack(alignment: .leading, spacing: 4) {
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
                                        .foregroundStyle(Color(uiColor: ChatUIDesign.Color.black60))
                                }
                            }
                        }
                    } else {
                        labeledField(L10n.tr("common.name")) {
                            Text(name)
                                .settingsInputFieldStyle(readOnly: true)
                                .foregroundStyle(Color(uiColor: ChatUIDesign.Color.black80))
                        }
                    }
                }

                if mode.isMetadataEditable {
                    CustomSection(footer: { Text(L10n.tr("settings.skills.editor.metadata.footer")) }) {
                        labeledField(L10n.tr("common.description")) {
                            TextField(L10n.tr("settings.skills.editor.description.placeholder"), text: $description)
                                .textInputAutocapitalization(.sentences)
                                .settingsInputFieldStyle()
                        }

                        labeledField(L10n.tr("settings.skills.editor.emoji")) {
                            editableEmojiField
                        }
                    }
                } else {
                    CustomSection(footer: { Text(L10n.tr("settings.skills.editor.readOnlyFooter")) }) {
                        labeledField(L10n.tr("common.description")) {
                            Text(description.isEmpty ? "-" : description)
                                .settingsInputFieldStyle(readOnly: true)
                                .foregroundStyle(Color(uiColor: ChatUIDesign.Color.black80))
                        }

                        labeledField(L10n.tr("settings.skills.editor.emoji")) {
                            Text(emoji.isEmpty ? "-" : emoji)
                                .settingsInputFieldStyle(readOnly: true)
                                .foregroundStyle(Color(uiColor: ChatUIDesign.Color.black80))
                        }
                    }
                }

                CustomSection {
                    labeledField(L10n.tr("settings.skills.editor.section.file")) {
                        TextEditor(text: $content)
                            .frame(minHeight: 300)
                            .font(.system(.body, design: .monospaced))
                            .disabled(!mode.supportsSaving)
                            .scrollContentBackground(.hidden)
                            .padding(8)
                            .background(
                                (!mode.supportsSaving) ? Color(uiColor: ChatUIDesign.Color.oatBorder).opacity(0.3) : Color(uiColor: ChatUIDesign.Color.pureWhite),
                                in: RoundedRectangle(cornerRadius: ChatUIDesign.Radius.card, style: .continuous)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: ChatUIDesign.Radius.card, style: .continuous)
                                    .strokeBorder(Color(uiColor: ChatUIDesign.Color.oatBorder), lineWidth: 1)
                            )
                    }
                }

                if let errorText {
                    Text(errorText)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 24)
        }
        #if !targetEnvironment(macCatalyst)
        .scrollDismissesKeyboard(.interactively)
        #endif
    }

    #if targetEnvironment(macCatalyst)
        private func sheetTopBar() -> some View {
            VStack(spacing: 0) {
                ZStack {
                    Text(mode.title)
                        .font(.system(size: 18, weight: .regular))
                        .foregroundStyle(Color(uiColor: ChatUIDesign.Color.offBlack))

                    HStack {
                        actionButton(
                            title: mode.supportsSaving ? L10n.tr("common.cancel") : L10n.tr("common.done"),
                            role: .secondary,
                            isDisabled: false,
                            action: cancelEditing
                        )
                        Spacer(minLength: 0)
                        if mode.supportsSaving {
                            actionButton(
                                title: mode.actionTitle,
                                role: .primary,
                                isDisabled: !canSave,
                                action: commit
                            )
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 12)

                Rectangle()
                    .fill(Color(uiColor: ChatUIDesign.Color.oatBorder))
                    .frame(height: 1)
            }
        }
    #endif

    private var editableEmojiField: some View {
        HStack(spacing: 10) {
            Button {
                isEmojiPickerPresented = true
            } label: {
                HStack(spacing: 10) {
                    Text(emoji.isEmpty ? L10n.tr("agent.creation.emojiPicker.title") : emoji)
                        .font(.system(size: emoji.isEmpty ? 15 : 24))
                        .foregroundStyle(
                            emoji.isEmpty
                                ? Color(uiColor: ChatUIDesign.Color.black50)
                                : Color(uiColor: ChatUIDesign.Color.offBlack)
                        )

                    Spacer(minLength: 8)

                    Image(systemName: "chevron.down")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color(uiColor: ChatUIDesign.Color.black50))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .settingsInputFieldStyle()

            if !emoji.isEmpty {
                Button {
                    emoji = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(Color(uiColor: ChatUIDesign.Color.black50))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.tr("common.delete"))
            }
        }
    }

    private var emojiPickerSheetContent: some View {
        EmojiPickerGrid(emojis: EmojiPickerCatalog.candidates) { selectedEmoji in
            emoji = selectedEmoji
            isEmojiPickerPresented = false
        }
        .background(Color(uiColor: ChatUIDesign.Color.warmCream))
    }

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
            VStack(alignment: .leading, spacing: 12) {
                if let title {
                    Text(title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color(uiColor: ChatUIDesign.Color.black60))
                }

                content()

                if let footer {
                    footer
                        .font(.system(size: 13))
                        .foregroundStyle(Color(uiColor: ChatUIDesign.Color.black50))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func labeledField<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color(uiColor: ChatUIDesign.Color.black80))
            content()
        }
    }

    private enum ActionButtonRole {
        case primary
        case secondary
    }

    private func actionButton(
        title: String,
        role: ActionButtonRole,
        isDisabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
        }
        .buttonStyle(PhysicalButtonStyle(role: role == .primary ? PhysicalButtonRole.primary : PhysicalButtonRole.secondary, isDisabled: isDisabled))
        .disabled(isDisabled)
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
    func settingsInputFieldStyle(readOnly: Bool = false) -> some View {
        frame(minHeight: 34)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                readOnly ? Color(uiColor: ChatUIDesign.Color.oatBorder).opacity(0.3) : Color(uiColor: ChatUIDesign.Color.pureWhite),
                in: RoundedRectangle(cornerRadius: ChatUIDesign.Radius.card, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: ChatUIDesign.Radius.card, style: .continuous)
                    .strokeBorder(Color(uiColor: ChatUIDesign.Color.oatBorder), lineWidth: 1)
            )
    }
}

private struct SkillRow: View {
    let skill: SkillListItem
    @Binding var isEnabled: Bool
    var onOpen: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            tappableContent

            VStack(alignment: .trailing, spacing: 10) {
                Toggle(L10n.tr("settings.skills.enabled"), isOn: $isEnabled)
                    .labelsHidden()
                    .tint(Color(uiColor: ChatUIDesign.Color.brandOrange))
                    .scaleEffect(0.85)

                if let onDelete {
                    Menu {
                        if let onOpen {
                            Button(action: onOpen) {
                                Label(L10n.tr("common.edit"), systemImage: "pencil")
                            }
                        }

                        Button(role: .destructive, action: onDelete) {
                            Label(L10n.tr("common.delete"), systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color(uiColor: ChatUIDesign.Color.black60))
                            .frame(width: 30, height: 30)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Color(uiColor: ChatUIDesign.Color.warmCream))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(Color(uiColor: ChatUIDesign.Color.oatBorder), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .animation(.easeInOut(duration: 0.2), value: isEnabled)
    }

    private var tappableContent: some View {
        Button {
            onOpen?()
        } label: {
            HStack(alignment: .top, spacing: 14) {
                skillIcon
                    .padding(.top, 2)
                skillSummary

                Spacer(minLength: 8)

                if onOpen != nil {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color(uiColor: ChatUIDesign.Color.contentTertiary))
                        .padding(.top, 4)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PhysicalRowButtonStyle())
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var skillIcon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(uiColor: ChatUIDesign.Color.black60).opacity(0.06))
                .frame(width: 40, height: 40)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color(uiColor: ChatUIDesign.Color.oatBorder), lineWidth: 1)
                )

            if let emoji = skill.emoji, !emoji.isEmpty {
                Text(emoji)
                    .font(.system(size: 20))
            } else {
                Image(systemName: skill.isAvailable ? "hammer.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(skill.isAvailable ? Color(uiColor: ChatUIDesign.Color.black60) : Color(uiColor: ChatUIDesign.Color.black50))
            }
        }
    }

    private var skillSummary: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 8) {
                Text(skill.displayName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color(uiColor: ChatUIDesign.Color.offBlack))
                    .lineLimit(1)

                if !skill.isWorkspace {
                    StatusBadge(
                        title: L10n.tr("settings.skills.readOnly"),
                        foreground: Color(uiColor: ChatUIDesign.Color.black60),
                        background: Color(uiColor: ChatUIDesign.Color.black60).opacity(0.06)
                    )
                }
            }

            if !skill.description.isEmpty {
                Text(skill.description)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(Color(uiColor: ChatUIDesign.Color.black60))
                    .lineLimit(2)
                    .padding(.bottom, 4)
                    .padding(.top, 2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(skill.name)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .tracking(0.2)
                    .foregroundStyle(Color(uiColor: ChatUIDesign.Color.black50))
                    .lineLimit(1)

                if !skill.isAvailable || !isEnabled {
                    HStack(spacing: 6) {
                        if !skill.isAvailable {
                            StatusBadge(
                                title: L10n.tr("settings.skills.unavailable"),
                                foreground: Color(uiColor: ChatUIDesign.Color.black60),
                                background: Color(uiColor: ChatUIDesign.Color.black60).opacity(0.06)
                            )
                        }

                        if !isEnabled {
                            StatusBadge(
                                title: L10n.tr("settings.skills.disabled"),
                                foreground: Color(uiColor: ChatUIDesign.Color.black60),
                                background: Color(uiColor: ChatUIDesign.Color.black60).opacity(0.06)
                            )
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct EmptySkillsView: View {
    let systemImage: String
    let title: String
    var message: String? = nil
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(Color(uiColor: ChatUIDesign.Color.black60))

            Text(title)
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(Color(uiColor: ChatUIDesign.Color.offBlack))

            if let message {
                Text(message)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(Color(uiColor: ChatUIDesign.Color.black60))
                    .multilineTextAlignment(.center)
            }

            if let actionTitle, let action {
                Button(action: action) {
                    Label(actionTitle, systemImage: "plus")
                }
                .buttonStyle(PhysicalButtonStyle(role: PhysicalButtonRole.card))
            }
        }
        .frame(maxWidth: .infinity, minHeight: 120)
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: ChatUIDesign.Radius.card, style: .continuous)
                .fill(Color(uiColor: ChatUIDesign.Color.pureWhite))
        )
        .overlay(
            RoundedRectangle(cornerRadius: ChatUIDesign.Radius.card, style: .continuous)
                .strokeBorder(Color(uiColor: ChatUIDesign.Color.oatBorder), lineWidth: 1)
        )
    }
}

private struct StatusBadge: View {
    let title: String
    let foreground: Color
    let background: Color

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(foreground)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(background)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(foreground.opacity(0.12), lineWidth: 1)
            )
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
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.green)
            }

            Text(banner.message)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color(uiColor: ChatUIDesign.Color.offBlack))

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(Color(uiColor: ChatUIDesign.Color.pureWhite))
        .clipShape(RoundedRectangle(cornerRadius: ChatUIDesign.Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: ChatUIDesign.Radius.card, style: .continuous)
                .strokeBorder(Color(uiColor: ChatUIDesign.Color.oatBorder), lineWidth: 1)
        )
        // Removed shadow to conform to OpenAvaDesign
    }
}

#Preview {
    NavigationStack {
        SkillListView()
    }
}
