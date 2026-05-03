import ChatClient
import ChatUI
import Foundation
import OpenClawKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import UserNotifications

#if targetEnvironment(macCatalyst)
    @MainActor
    private final class WorkspaceDocumentPickerDelegate: NSObject, UIDocumentPickerDelegate {
        private let onCompletion: (Result<[URL], Error>) -> Void

        init(onCompletion: @escaping (Result<[URL], Error>) -> Void) {
            self.onCompletion = onCompletion
            super.init()
        }

        func documentPicker(_: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onCompletion(.success(urls))
        }

        func documentPickerWasCancelled(_: UIDocumentPickerViewController) {
            onCompletion(.success([]))
        }
    }
#endif

struct ChatRootView: View {
    @Environment(\.appContainerStore) private var containerStore
    @Environment(\.appWindowCoordinator) private var windowCoordinator
    @Environment(\.openWindow) private var openWindow
    @Environment(\.scenePhase) private var scenePhase
    // Keep destination navigation state at root so config-driven ChatScreen
    // recreation does not pop pushed pages unexpectedly.
    @State private var destinationPath = NavigationPath()
    @State private var showsAgentOnboarding = false
    @State private var autoCompactEnabled: Bool = true
    @State private var showsLocalAgentCreation = false
    @State private var showsRemoteControl = false
    @State private var showsContextEditorForKind: AgentContextDocumentKind?
    @State private var showsWorkspaceImporter = false
    @State private var showsWorkspaceParentImporter = false
    @State private var showsCreateWorkspaceAlert = false
    @State private var newWorkspaceName = ""
    @State private var workspaceErrorMessage: String?
    #if targetEnvironment(macCatalyst)
        @State private var workspaceDocumentPickerDelegate: WorkspaceDocumentPickerDelegate?
    #endif
    @State private var didEvaluateOnboarding = false
    /// Pending message from an App Intent, consumed once by ChatViewControllerWrapper.
    @State private var pendingAutoSendID: String? = nil
    @State private var pendingAutoSendMessage: String? = nil
    @State private var menuRefreshToken: Int = 0

    private enum MenuDestination: Hashable {
        case llm
        case cron
        case skills
        case remoteControl
    }

    var body: some View {
        NavigationStack(path: $destinationPath) {
            rootContent
                .navigationDestination(for: MenuDestination.self) { destination in
                    destinationView(for: destination)
                }
        }
        .fullScreenCover(isPresented: $showsAgentOnboarding) {
            AgentOnboardingView(onComplete: {
                showsAgentOnboarding = false
            })
        }
        .fullScreenCover(isPresented: $showsLocalAgentCreation) {
            NavigationStack {
                AgentCreationView(onComplete: {
                    showsLocalAgentCreation = false
                })
            }
        }
        .sheet(isPresented: $showsRemoteControl) {
            #if targetEnvironment(macCatalyst)
                RemoteControlSettingsView(onDone: {
                    showsRemoteControl = false
                })
                .frame(width: 640, height: 600)
            #else
                NavigationStack {
                    RemoteControlSettingsView(onDone: {
                        showsRemoteControl = false
                    })
                }
                .presentationDetents([.medium, .large])
            #endif
        }
        .sheet(item: $showsContextEditorForKind) { kind in
            NavigationStack {
                ContextSettingsView(kind: kind)
            }
        }
        .fileImporter(
            isPresented: $showsWorkspaceImporter,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false,
            onCompletion: handleWorkspaceImport
        )
        .fileImporter(
            isPresented: $showsWorkspaceParentImporter,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false,
            onCompletion: handleWorkspaceParentSelection
        )
        .overlay {
            if showsCreateWorkspaceAlert {
                WorkspaceCreationAlertView(
                    isPresented: $showsCreateWorkspaceAlert,
                    workspaceName: $newWorkspaceName,
                    onCreate: {
                        createWorkspaceFromPendingName()
                    }
                )
                .zIndex(100)
            }
        }
        .alert(L10n.tr("common.error"), isPresented: Binding(
            get: { workspaceErrorMessage != nil },
            set: { if !$0 { workspaceErrorMessage = nil } }
        )) {
            Button(L10n.tr("common.ok"), role: .cancel) {}
        } message: {
            Text(workspaceErrorMessage ?? "")
        }
        .onAppear {
            normalizeSessionContextForVisibleMenu()
            autoCompactEnabled = containerStore.activeAgent?.autoCompactEnabled ?? true
            RemoteControlCoordinator.shared.bind(containerStore: containerStore)
            presentOnboardingIfNeeded()
            drainPendingAutoSend()
            updateHeartbeatService()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                drainPendingAutoSend()
            }
            updateHeartbeatService()
        }
        .onReceive(NotificationCenter.default.publisher(for: .OpenAvaIntentAutoSend)) { _ in
            drainPendingAutoSend()
        }
        .onChange(of: containerStore.agents) { _, _ in
            menuRefreshToken &+= 1
            normalizeSessionContextForVisibleMenu()
            updateHeartbeatService()
        }
        .onChange(of: containerStore.teams) { _, _ in
            menuRefreshToken &+= 1
            normalizeSessionContextForVisibleMenu()
        }
        .onChange(of: containerStore.activeAgent?.id) { _, newAgentID in
            if newAgentID == nil, !containerStore.hasAgent {
                showsAgentOnboarding = true
                HeartbeatRuntimeRegistry.shared.stopAll()
                return
            }
            drainPendingAutoSend()
            autoCompactEnabled = containerStore.activeAgent?.autoCompactEnabled ?? true
            updateHeartbeatService()
        }
        .onChange(of: containerStore.activeSessionContext) { _, _ in
            normalizeSessionContextForVisibleMenu()
            autoCompactEnabled = containerStore.activeAgent?.autoCompactEnabled ?? true
        }
        .onChange(of: containerAgent) { _, _ in
            updateHeartbeatService()
        }
        .onChange(of: containerStore.activeProjectWorkspace?.id) { _, _ in
            menuRefreshToken &+= 1
            didEvaluateOnboarding = false
            normalizeSessionContextForVisibleMenu()
            presentOnboardingIfNeeded()
            updateHeartbeatService()
        }
        .onChange(of: autoCompactEnabled) { _, _ in
            updateHeartbeatService()
        }
    }

    private var rootContent: some View {
        chatScreenView
    }

    private var isMainChatActive: Bool {
        #if targetEnvironment(macCatalyst)
            // On Catalyst, toggling showsSystemTopBar installs/uninstalls a titlebar toolbar, which
            // moves the window traffic lights. The remote control is an in-window overlay, so keep
            // the system top bar stable while it's shown.
            !showsAgentOnboarding &&
                !showsLocalAgentCreation &&
                destinationPath.isEmpty
        #else
            !showsAgentOnboarding &&
                !showsLocalAgentCreation &&
                !showsRemoteControl &&
                destinationPath.isEmpty
        #endif
    }

    private var chatScreenView: some View {
        let sessionKey = primarySessionKey
        let activeContext = visibleActiveSessionContext
        return ChatScreen(
            container: containerStore.container,
            scopedSessionID: scopedSessionID(
                for: sessionKey,
                context: activeContext
            ),
            teamSessionsRootURL: containerStore.teamSessionsRootURL,
            projectWorkspaces: containerStore.projectWorkspaces,
            activeProjectWorkspaceID: containerStore.activeProjectWorkspace?.id,
            activeProjectWorkspaceName: containerStore.activeProjectWorkspace?.resolvedName ?? "OpenAva",
            teams: visibleTeams,
            agents: containerStore.agents,
            activeContext: activeContext,
            activeAgentID: containerStore.activeAgent?.id,
            activeAgentName: currentActiveAgentName,
            activeAgentEmoji: currentActiveAgentEmoji,
            selectedModelName: currentSelectedModelName,
            selectedProviderName: resolveSelectedProviderName(),
            pendingAutoSendID: pendingAutoSendID,
            pendingAutoSendMessage: pendingAutoSendMessage,
            menuRefreshToken: menuRefreshToken,
            onConsumePendingAutoSend: consumePendingAutoSend,
            onMenuAction: handleMenuAction,
            onSessionSwitch: handleSessionSwitch,
            onModelSwitch: handleModelSwitch,
            onWorkspaceSwitch: handleWorkspaceSwitch,
            onOpenWorkspaceDirectory: openActiveWorkspaceDirectory,
            onImportWorkspace: openWorkspaceImporter,
            onCreateWorkspace: openWorkspaceCreation,
            onCreateLocalAgent: openLocalAgentCreation,
            onDeleteCurrentAgent: handleDeleteCurrentAgent,
            onRenameCurrentAgent: handleRenameCurrentAgent,
            autoCompactEnabled: autoCompactEnabled,
            showsSystemTopBar: isMainChatActive,
            onToggleAutoCompact: toggleAutoCompact
        )
        .id(containerAgent)
        #if targetEnvironment(macCatalyst)
            .toolbar(.hidden, for: .navigationBar)
            .ignoresSafeArea(edges: .top)
        #endif
    }

    /// Recreate the chat screen only when switching to another agent.
    private var containerAgent: String {
        let agent = containerStore.container.config.agent
        return agent.id ?? ""
    }

    private var resolvedDefaultSessionKey: String {
        let trimmed = containerStore.container.defaultSessionKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "main" : trimmed
    }

    private var primarySessionKey: String {
        resolvedDefaultSessionKey
    }

    private var visibleTeams: [TeamProfile] {
        containerStore.teams
    }

    private var visibleActiveSessionContext: ActiveSessionContext {
        switch containerStore.activeSessionContext {
        case .allAgentsTeam:
            return .allAgentsTeam
        case let .team(teamID):
            return activeTeamProfile(for: teamID) == nil ? .allAgentsTeam : .team(teamID)
        case let .agent(agentID):
            let agentExists = containerStore.agents.contains { $0.id == agentID }
            return agentExists ? .agent(agentID) : .allAgentsTeam
        }
    }

    private func presentOnboardingIfNeeded() {
        guard !didEvaluateOnboarding else { return }
        didEvaluateOnboarding = true
        if !containerStore.hasAgent {
            showsAgentOnboarding = true
        } else {
            showsAgentOnboarding = false
        }
    }

    private func normalizeSessionContextForVisibleMenu() {
        switch containerStore.activeSessionContext {
        case let .team(teamID) where activeTeamProfile(for: teamID) == nil:
            _ = containerStore.setActiveSessionContext(.allAgentsTeam)
        case let .agent(agentID) where !containerStore.agents.contains(where: { $0.id == agentID }):
            _ = containerStore.setActiveSessionContext(.allAgentsTeam)
        default:
            break
        }
    }

    /// Reads one pending launch request and resolves it into a chat message.
    private func drainPendingAutoSend() {
        guard let request = SkillLaunchService.dequeuePendingAutoSend(),
              request.id != pendingAutoSendID
        else { return }
        let id = request.id
        let message = request.message
        pendingAutoSendID = id
        pendingAutoSendMessage = message
    }

    private func consumePendingAutoSend(_ id: String) {
        guard pendingAutoSendID == id else { return }
        pendingAutoSendID = nil
        pendingAutoSendMessage = nil
    }

    private func handleSessionSwitch(_ context: ActiveSessionContext) {
        // Keep existing sessions alive so in-flight tasks can keep running
        // when users switch to another agent.
        guard containerStore.setActiveSessionContext(context) else { return }
    }

    private func handleModelSwitch(_ modelID: UUID) {
        containerStore.selectLLMModel(id: modelID)
    }

    private func handleWorkspaceSwitch(_ workspaceID: UUID) {
        guard containerStore.switchProjectWorkspace(workspaceID) else { return }
        menuRefreshToken &+= 1
    }

    private func openActiveWorkspaceDirectory() {
        guard let workspace = containerStore.activeProjectWorkspace else { return }
        let workspaceURL = ProjectWorkspaceStore.resolvedURL(for: workspace)
        UIApplication.shared.open(workspaceURL)
    }

    private func openWorkspaceImporter(_ presenter: UIViewController? = nil) {
        #if targetEnvironment(macCatalyst)
            if let presenter {
                let pickerDelegate = WorkspaceDocumentPickerDelegate { result in
                    handleWorkspaceImport(result)
                    workspaceDocumentPickerDelegate = nil
                }
                workspaceDocumentPickerDelegate = pickerDelegate

                let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
                picker.allowsMultipleSelection = false
                picker.delegate = pickerDelegate
                presenter.present(picker, animated: true)
                return
            }
        #endif

        showsWorkspaceImporter = true
    }

    private func openWorkspaceCreation() {
        newWorkspaceName = containerStore.activeProjectWorkspace?.resolvedName ?? "OpenAva"
        showsCreateWorkspaceAlert = true
    }

    private func createWorkspaceFromPendingName() {
        let name = newWorkspaceName.trimmingCharacters(in: .whitespacesAndNewlines)
        #if targetEnvironment(macCatalyst)
            guard !name.isEmpty else { return }
            showsWorkspaceParentImporter = true
        #else
            do {
                _ = try containerStore.createProjectWorkspace(named: name.isEmpty ? "OpenAva" : name)
                menuRefreshToken &+= 1
            } catch {
                workspaceErrorMessage = error.localizedDescription
            }
        #endif
    }

    private func handleWorkspaceImport(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            _ = try containerStore.importProjectWorkspace(at: url)
            menuRefreshToken &+= 1
        } catch {
            workspaceErrorMessage = error.localizedDescription
        }
    }

    private func handleWorkspaceParentSelection(_ result: Result<[URL], Error>) {
        do {
            guard let parentURL = try result.get().first else { return }
            let name = newWorkspaceName.trimmingCharacters(in: .whitespacesAndNewlines)
            _ = try containerStore.createProjectWorkspace(named: name.isEmpty ? "OpenAva" : name, inParentDirectory: parentURL)
            menuRefreshToken &+= 1
        } catch {
            workspaceErrorMessage = error.localizedDescription
        }
    }

    private func handleDeleteCurrentAgent() {
        guard let currentAgentID = containerStore.activeAgent?.id else { return }

        // Remove cached storage provider for the deleted agent's context root.
        if let supportRootURL = containerStore.activeAgent?.contextURL {
            TranscriptStorageProvider.removeProvider(supportRootURL: supportRootURL)
        }

        // Clear all sessions since session IDs no longer contain agent prefix.
        ConversationSessionManager.shared.removeAllSessions()

        guard containerStore.deleteAgent(currentAgentID) else { return }
        if !containerStore.hasAgent {
            showsAgentOnboarding = true
        }
    }

    private func handleRenameCurrentAgent(_ name: String) -> Bool {
        guard containerStore.activeAgent != nil else { return false }
        let oldSupportURL = containerStore.activeAgent?.contextURL
        guard containerStore.renameActiveAgent(to: name) else { return false }

        // Drop old transcript provider cache because the context path changed after rename.
        if let oldSupportURL {
            TranscriptStorageProvider.removeProvider(supportRootURL: oldSupportURL)
        }
        return true
    }

    private func scopedSessionID(for sessionKey: String, context: ActiveSessionContext) -> String {
        switch context {
        case .allAgentsTeam:
            return TeamSwarmCoordinator.mainSessionID
        case let .team(teamID):
            return "team-\(teamID.uuidString)-\(sessionKey)"
        case .agent:
            // Agent transcripts are already isolated by supportRootURL per agent.
            return sessionKey
        }
    }

    private func updateHeartbeatService() {
        let llmCollection = LLMConfigStore.loadCollection()
        let configurations = containerStore.agents.compactMap { agent -> HeartbeatRuntimeConfiguration? in
            guard let model = llmCollection.selectedModel(preferredID: agent.selectedModelID),
                  model.isConfigured
            else {
                return nil
            }

            return .init(
                agent: agent,
                agentID: agent.id.uuidString,
                mainSessionID: scopedSessionID(for: primarySessionKey, context: .agent(agent.id)),
                agentName: agent.name,
                agentEmoji: agent.emoji,
                workspaceRootURL: agent.workspaceURL,
                supportRootURL: agent.contextURL,
                modelConfig: model
            )
        }

        HeartbeatRuntimeRegistry.shared.sync(
            configurations: configurations,
            schedulingEnabled: scenePhase == .active
        )
    }

    private func openLocalAgentCreation() {
        #if targetEnvironment(macCatalyst)
            windowCoordinator.openAgentCreation()
            activateOrOpenWindow(id: AppWindowID.agentCreation)
        #else
            showsLocalAgentCreation = true
        #endif
    }

    private func handleMenuAction(_ action: ChatViewControllerWrapper.MenuAction) {
        if case .runHeartbeatNow = action {
            triggerHeartbeatNow()
            return
        }

        #if targetEnvironment(macCatalyst)
            let section: SettingsWindowSection? = switch action {
            case .openLLM:
                .llm
            case .openContext:
                nil // Context is now presented as a sheet, not a section in the settings window
            case .openCron:
                .cron
            case .openSkills:
                .skills
            case .openRemoteControl:
                nil
            case .runHeartbeatNow:
                nil
            }

            if case .openRemoteControl = action {
                showsRemoteControl = true
            } else if case let .openContext(kind) = action {
                showsContextEditorForKind = kind
            } else if let section {
                openWindow(id: AppWindowID.settings, value: section.rawValue)
            }
        #else
            switch action {
            case .openLLM:
                destinationPath.append(MenuDestination.llm)
            case let .openContext(kind):
                showsContextEditorForKind = kind
            case .openCron:
                destinationPath.append(MenuDestination.cron)
            case .openSkills:
                destinationPath.append(MenuDestination.skills)
            case .openRemoteControl:
                destinationPath.append(MenuDestination.remoteControl)
            case .runHeartbeatNow:
                break
            }
        #endif
    }

    #if targetEnvironment(macCatalyst)
        private func activateOrOpenWindow(id: String) {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            let existing = scenes.first(where: { scene in
                scene.session.stateRestorationActivity?.targetContentIdentifier == id
            })

            if let existing = existing {
                UIApplication.shared.requestSceneSessionActivation(existing.session, userActivity: nil, options: nil, errorHandler: nil)
            } else {
                let targetTitle: String
                switch id {
                case AppWindowID.settings:
                    targetTitle = L10n.tr("window.settings.title")
                case AppWindowID.agentCreation:
                    targetTitle = L10n.tr("window.agentCreation.title")
                default:
                    targetTitle = ""
                }
                if !targetTitle.isEmpty, let titleMatch = scenes.first(where: { $0.title == targetTitle }) {
                    UIApplication.shared.requestSceneSessionActivation(titleMatch.session, userActivity: nil, options: nil, errorHandler: nil)
                } else {
                    openWindow(id: id)
                }
            }
        }
    #endif

    private func triggerHeartbeatNow() {
        updateHeartbeatService()
        Task { @MainActor in
            guard let agentID = containerStore.activeAgent?.id.uuidString else { return }
            _ = await HeartbeatRuntimeRegistry.shared.requestRunNow(for: agentID)
        }
    }

    private func resolveSelectedProviderName() -> String {
        guard let selected = containerStore.container.config.selectedLLMModel else {
            return ""
        }
        if let provider = LLMProvider(rawValue: selected.provider) {
            return provider.displayName
        }
        return selected.provider
    }

    private func destinationView(for destination: MenuDestination) -> some View {
        Group {
            switch destination {
            case .llm:
                LLMListView()
                    .navigationTitle(L10n.tr("settings.llm.navigationTitle"))
            case .cron:
                CronListView()
                    .navigationTitle(L10n.tr("settings.cron.navigationTitle"))
            case .skills:
                SkillListView()
                    .navigationTitle(L10n.tr("settings.skills.navigationTitle"))
            case .remoteControl:
                RemoteControlSettingsView()
                    .navigationTitle(L10n.tr("settings.remoteControl.navigationTitle"))
            }
        }
        // Re-enable nav bar on pushed pages for standard back navigation.
        .toolbar(.visible, for: .navigationBar)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var currentActiveAgentName: String {
        switch visibleActiveSessionContext {
        case .allAgentsTeam:
            return L10n.tr("chat.menu.allAgentsTeam")
        case let .team(teamID):
            return activeTeamProfile(for: teamID)?.name ?? L10n.tr("chat.activeTeam.fallbackName")
        case .agent:
            return containerStore.activeAgent?.name ?? L10n.tr("chat.activeAgent.fallbackName")
        }
    }

    private var currentActiveAgentEmoji: String {
        switch visibleActiveSessionContext {
        case .allAgentsTeam:
            return "👥"
        case let .team(teamID):
            return activeTeamProfile(for: teamID)?.emoji ?? "👥"
        case .agent:
            return containerStore.activeAgent?.emoji ?? ""
        }
    }

    private func activeTeamProfile(for teamID: UUID) -> TeamProfile? {
        containerStore.teams.first { $0.id == teamID }
    }

    private var currentSelectedModelName: String {
        containerStore.container.config.selectedLLMModel?.name ?? L10n.tr("chat.selectedModel.notSelected")
    }

    private func toggleAutoCompact() {
        let newValue = !autoCompactEnabled
        guard containerStore.setAutoCompact(newValue) else { return }
        autoCompactEnabled = newValue
    }
}

private struct ChatScreen: View {
    private let container: AppContainer
    private let scopedSessionID: String
    private let teamSessionsRootURL: URL?
    private let projectWorkspaces: [ProjectWorkspaceProfile]
    private let activeProjectWorkspaceID: UUID?
    private let activeProjectWorkspaceName: String
    private let teams: [TeamProfile]
    private let agents: [AgentProfile]
    private let activeContext: ActiveSessionContext
    private let activeAgentID: UUID?
    private let activeAgentName: String
    private let activeAgentEmoji: String
    private let selectedModelName: String
    private let selectedProviderName: String
    private let pendingAutoSendID: String?
    private let pendingAutoSendMessage: String?
    private let menuRefreshToken: Int
    private let onConsumePendingAutoSend: ((String) -> Void)?
    private let onMenuAction: ((ChatViewControllerWrapper.MenuAction) -> Void)?
    private let onSessionSwitch: ((ActiveSessionContext) -> Void)?
    private let onModelSwitch: ((UUID) -> Void)?
    private let onWorkspaceSwitch: ((UUID) -> Void)?
    private let onOpenWorkspaceDirectory: (() -> Void)?
    private let onImportWorkspace: ((UIViewController?) -> Void)?
    private let onCreateWorkspace: (() -> Void)?
    private let onCreateLocalAgent: (() -> Void)?
    private let onDeleteCurrentAgent: (() -> Void)?
    private let onRenameCurrentAgent: ((String) -> Bool)?
    private let autoCompactEnabled: Bool
    private let showsSystemTopBar: Bool
    private let onToggleAutoCompact: (() -> Void)?

    @State private var showsRenameAlert = false
    @State private var renameText = ""

    init(
        container: AppContainer,
        scopedSessionID: String,
        teamSessionsRootURL: URL? = nil,
        projectWorkspaces: [ProjectWorkspaceProfile] = [],
        activeProjectWorkspaceID: UUID? = nil,
        activeProjectWorkspaceName: String = "OpenAva",
        teams: [TeamProfile],
        agents: [AgentProfile],
        activeContext: ActiveSessionContext,
        activeAgentID: UUID?,
        activeAgentName: String,
        activeAgentEmoji: String,
        selectedModelName: String,
        selectedProviderName: String,
        pendingAutoSendID: String? = nil,
        pendingAutoSendMessage: String? = nil,
        menuRefreshToken: Int = 0,
        onConsumePendingAutoSend: ((String) -> Void)? = nil,
        onMenuAction: ((ChatViewControllerWrapper.MenuAction) -> Void)? = nil,
        onSessionSwitch: ((ActiveSessionContext) -> Void)? = nil,
        onModelSwitch: ((UUID) -> Void)? = nil,
        onWorkspaceSwitch: ((UUID) -> Void)? = nil,
        onOpenWorkspaceDirectory: (() -> Void)? = nil,
        onImportWorkspace: ((UIViewController?) -> Void)? = nil,
        onCreateWorkspace: (() -> Void)? = nil,
        onCreateLocalAgent: (() -> Void)? = nil,
        onDeleteCurrentAgent: (() -> Void)? = nil,
        onRenameCurrentAgent: ((String) -> Bool)? = nil,
        autoCompactEnabled: Bool = true,
        showsSystemTopBar: Bool = true,
        onToggleAutoCompact: (() -> Void)? = nil
    ) {
        self.container = container
        self.scopedSessionID = scopedSessionID
        self.teamSessionsRootURL = teamSessionsRootURL
        self.projectWorkspaces = projectWorkspaces
        self.activeProjectWorkspaceID = activeProjectWorkspaceID
        self.activeProjectWorkspaceName = activeProjectWorkspaceName
        self.teams = teams
        self.agents = agents
        self.activeContext = activeContext
        self.activeAgentID = activeAgentID
        self.activeAgentName = activeAgentName
        self.activeAgentEmoji = activeAgentEmoji
        self.selectedModelName = selectedModelName
        self.selectedProviderName = selectedProviderName
        self.pendingAutoSendID = pendingAutoSendID
        self.pendingAutoSendMessage = pendingAutoSendMessage
        self.menuRefreshToken = menuRefreshToken
        self.onConsumePendingAutoSend = onConsumePendingAutoSend
        self.onMenuAction = onMenuAction
        self.onSessionSwitch = onSessionSwitch
        self.onModelSwitch = onModelSwitch
        self.onWorkspaceSwitch = onWorkspaceSwitch
        self.onOpenWorkspaceDirectory = onOpenWorkspaceDirectory
        self.onImportWorkspace = onImportWorkspace
        self.onCreateWorkspace = onCreateWorkspace
        self.onCreateLocalAgent = onCreateLocalAgent
        self.onDeleteCurrentAgent = onDeleteCurrentAgent
        self.onRenameCurrentAgent = onRenameCurrentAgent
        self.autoCompactEnabled = autoCompactEnabled
        self.showsSystemTopBar = showsSystemTopBar
        self.onToggleAutoCompact = onToggleAutoCompact
    }

    var body: some View {
        contentView
            .alert(L10n.tr("chat.menu.renameAgentNamed", activeAgentName), isPresented: $showsRenameAlert) {
                TextField(L10n.tr("chat.menu.renameAlert.placeholder"), text: $renameText)
                Button(L10n.tr("common.cancel"), role: .cancel) {}
                Button(L10n.tr("common.save")) {
                    let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !name.isEmpty else { return }
                    _ = onRenameCurrentAgent?(name)
                }
            } message: {
                Text(L10n.tr("chat.menu.renameAlert.message"))
            }
        #if !targetEnvironment(macCatalyst)
            .toolbar {
                if showsSystemTopBar {
                    iosToolbarContent
                }
            }
        #endif
    }

    #if !targetEnvironment(macCatalyst)
        @ToolbarContentBuilder
        private var iosToolbarContent: some ToolbarContent {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    agentMenuContent
                } label: {
                    Image(systemName: ChatTopBar.leadingMenuSystemImage)
                        .foregroundStyle(Color(uiColor: ChatUIDesign.Color.black60))
                }
            }
            ToolbarItem(placement: .principal) {
                Button {
                    onMenuAction?(.openLLM)
                } label: {
                    VStack(spacing: 1) {
                        Text(activeProjectWorkspaceName)
                            .font(.caption2)
                            .foregroundStyle(Color(uiColor: ChatUIDesign.Color.black50))
                            .lineLimit(1)
                        Text(topBarTitle.principalTitleText)
                            .font(Font(ChatUIDesign.Typography.agentTitle))
                            .foregroundStyle(Color(uiColor: ChatUIDesign.Color.offBlack))
                            .lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    configurationMenuContent
                } label: {
                    Image(systemName: ChatTopBar.trailingMenuSystemImage)
                        .foregroundStyle(Color(uiColor: ChatUIDesign.Color.black60))
                }
            }
        }

        private var topBarTitle: ChatTopBar.Title {
            ChatTopBar.title(
                displayName: activeAgentName,
                displayEmoji: activeAgentEmoji,
                modelName: selectedModelName,
                activeContext: activeContext
            )
        }

        private var topBarWorkspaceMenuEntries: [ChatTopBar.WorkspaceMenuEntry] {
            ChatTopBar.workspaceMenuEntries(workspaces: projectWorkspaces, activeWorkspaceID: activeProjectWorkspaceID)
        }

        private var topBarSessionMenuEntries: [ChatTopBar.SessionMenuEntry] {
            ChatTopBar.sessionMenuEntries(teams: teams, agents: agents, activeContext: activeContext)
        }

        private var topBarConfigurationSections: [ChatTopBar.ConfigurationSection] {
            ChatTopBar.configurationSections(
                autoCompactEnabled: autoCompactEnabled,
                isBackgroundEnabled: BackgroundExecutionPreferences.shared.isEnabled,
                includeBackgroundExecution: false,
                includeAgentManagement: isAgentContext
            )
        }

        private var isAgentContext: Bool {
            if case .agent = activeContext { return true }
            return false
        }

        private func shouldInsertDividerBeforeSessionEntry(at index: Int) -> Bool {
            guard index > 0, topBarSessionMenuEntries.indices.contains(index) else { return false }
            let entry = topBarSessionMenuEntries[index]
            switch entry.kind {
            case .agent:
                return !topBarSessionMenuEntries[..<index].contains { item in
                    if case .agent = item.kind { return true }
                    return false
                }
            case .createLocalAgent:
                return true
            case .allAgentsTeam, .team, .empty:
                return false
            }
        }

        @ViewBuilder
        private var agentMenuContent: some View {
            Section(L10n.tr("chat.workspace.sectionTitle")) {
                ForEach(topBarWorkspaceMenuEntries) { entry in
                    workspaceMenuEntryView(entry)
                }
            }
            Section(L10n.tr("chat.session.sectionTitle")) {
                sessionMenuContent
            }
        }

        private var sessionMenuContent: some View {
            ForEach(topBarSessionMenuEntries.indices, id: \.self) { index in
                let entry = topBarSessionMenuEntries[index]
                if shouldInsertDividerBeforeSessionEntry(at: index) {
                    Divider()
                }
                switch entry.kind {
                case .allAgentsTeam:
                    Button {
                        onSessionSwitch?(.allAgentsTeam)
                    } label: {
                        if entry.isSelected {
                            Label(entry.displayTitle, systemImage: "checkmark")
                        } else {
                            Text(entry.displayTitle)
                        }
                    }
                case let .team(teamID):
                    Button {
                        onSessionSwitch?(.team(teamID))
                    } label: {
                        if entry.isSelected {
                            Label(entry.displayTitle, systemImage: "checkmark")
                        } else {
                            Text(entry.displayTitle)
                        }
                    }
                case let .agent(agentID):
                    Button {
                        onSessionSwitch?(.agent(agentID))
                    } label: {
                        if entry.isSelected {
                            Label(entry.displayTitle, systemImage: "checkmark")
                        } else {
                            Text(entry.displayTitle)
                        }
                    }
                case .createLocalAgent:
                    Button {
                        onCreateLocalAgent?()
                    } label: {
                        Label(entry.title, systemImage: "plus")
                    }
                case .empty:
                    Text(entry.title)
                }
            }
        }

        @ViewBuilder
        private func workspaceMenuEntryView(_ entry: ChatTopBar.WorkspaceMenuEntry) -> some View {
            switch entry.kind {
            case let .workspace(workspaceID):
                Button {
                    onWorkspaceSwitch?(workspaceID)
                } label: {
                    if entry.isSelected {
                        Label(entry.displayTitle, systemImage: "checkmark")
                    } else {
                        Text(entry.displayTitle)
                    }
                }
            case .openActiveWorkspaceDirectory:
                Button {
                    onOpenWorkspaceDirectory?()
                } label: {
                    Label(entry.title, systemImage: "folder")
                }
            case .importWorkspace:
                Button {
                    onImportWorkspace?(nil)
                } label: {
                    Label(entry.title, systemImage: "folder.badge.plus")
                }
            case .createWorkspace:
                Button {
                    onCreateWorkspace?()
                } label: {
                    Label(entry.title, systemImage: "plus.square.on.square")
                }
            }
        }

        private var configurationMenuContent: some View {
            ForEach(topBarConfigurationSections) { section in
                Section {
                    ForEach(section.items) { item in
                        configurationMenuItemView(item)
                    }
                }
            }
        }

        @ViewBuilder
        private func configurationMenuItemView(_ item: ChatTopBar.ConfigurationItem) -> some View {
            switch item.kind {
            case let .destination(destination):
                Button {
                    handleTopBarConfigurationDestination(destination)
                } label: {
                    Label(item.title, systemImage: item.systemImage)
                }
            case let .backgroundExecution(enabled):
                Toggle(isOn: Binding(
                    get: { enabled },
                    set: { _ in
                        let preferences = BackgroundExecutionPreferences.shared
                        preferences.isEnabled.toggle()
                        if preferences.isEnabled {
                            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
                        }
                    }
                )) {
                    Label(item.title, systemImage: item.systemImage)
                }
            case let .autoCompact(enabled):
                Toggle(isOn: Binding(
                    get: { enabled },
                    set: { _ in onToggleAutoCompact?() }
                )) {
                    Label(item.title, systemImage: item.systemImage)
                }
            case .renameAgent:
                Button {
                    renameText = activeAgentName
                    showsRenameAlert = true
                } label: {
                    Label(item.title, systemImage: item.systemImage)
                }
            case .deleteAgent:
                Button(role: .destructive) {
                    onDeleteCurrentAgent?()
                } label: {
                    Label(item.title, systemImage: item.systemImage)
                }
            }
        }

        private func handleTopBarConfigurationDestination(_ destination: ChatTopBar.Destination) {
            let action: ChatViewControllerWrapper.MenuAction = switch destination {
            case .llm:
                .openLLM
            case .skills:
                .openSkills
            case .cron:
                .openCron
            case .remoteControl:
                .openRemoteControl
            }
            onMenuAction?(action)
        }
    #endif

    private var contentView: some View {
        chatControllerView
    }

    private var toolInvocationSessionID: String {
        switch activeContext {
        case .allAgentsTeam, .team:
            "global::\(scopedSessionID)"
        case .agent:
            "\(activeAgentID?.uuidString ?? "global")::\(scopedSessionID)"
        }
    }

    private var chatControllerView: some View {
        ChatViewControllerWrapper(
            sessionID: scopedSessionID,
            workspaceRootURL: container.config.agent.workspaceRootURL,
            supportRootURL: container.config.agent.supportRootURL,
            teamSessionsRootURL: teamSessionsRootURL,
            chatClient: container.services.chatClient,
            toolProvider: ToolRegistryProvider(
                toolRuntime: container.services.toolRuntime,
                invocationSessionID: toolInvocationSessionID
            ),
            systemPrompt: container.config.selectedLLMModel?.systemPrompt,
            teams: teams,
            agents: agents,
            activeContext: activeContext,
            activeAgentID: activeAgentID,
            activeAgentName: activeAgentName,
            activeAgentEmoji: activeAgentEmoji,
            selectedModelName: selectedModelName,
            selectedProviderName: selectedProviderName,
            pendingAutoSendID: pendingAutoSendID,
            pendingAutoSendMessage: pendingAutoSendMessage,
            menuRefreshToken: menuRefreshToken,
            onConsumePendingAutoSend: onConsumePendingAutoSend,
            onMenuAction: onMenuAction,
            onSessionSwitch: onSessionSwitch,
            onModelSwitch: onModelSwitch,
            projectWorkspaces: projectWorkspaces,
            activeProjectWorkspaceID: activeProjectWorkspaceID,
            activeProjectWorkspaceName: activeProjectWorkspaceName,
            onWorkspaceSwitch: onWorkspaceSwitch,
            onOpenWorkspaceDirectory: onOpenWorkspaceDirectory,
            onImportWorkspace: onImportWorkspace,
            onCreateWorkspace: onCreateWorkspace,
            onCreateLocalAgent: onCreateLocalAgent,
            onDeleteCurrentAgent: onDeleteCurrentAgent,
            onRenameCurrentAgent: onRenameCurrentAgent,
            modelConfig: container.config.selectedLLMModel,
            autoCompactEnabled: autoCompactEnabled,
            showsSystemTopBar: showsSystemTopBar,
            onToggleAutoCompact: onToggleAutoCompact
        )
        .id(scopedSessionID)
        .background(Color(uiColor: ChatUIDesign.Color.warmCream).ignoresSafeArea())
        .ignoresSafeArea()
        #if targetEnvironment(macCatalyst)
            .toolbar(.hidden, for: .navigationBar)
        #else
            .toolbar(showsSystemTopBar ? .visible : .hidden, for: .navigationBar)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
        #endif
    }
}

#Preview {
    ChatRootView()
        .environment(\.appContainerStore, AppContainerStore(container: .makeDefault()))
        .environment(\.appContainer, .makeDefault())
}

private struct WorkspaceCreationAlertView: View {
    @Binding var isPresented: Bool
    @Binding var workspaceName: String
    let onCreate: () -> Void

    @FocusState private var isTextFieldFocused: Bool

    var body: some View {
        ZStack {
            Color.black.opacity(0.3)
                .ignoresSafeArea()
                .onTapGesture {
                    isPresented = false
                }

            VStack(spacing: 24) {
                VStack(spacing: 8) {
                    Text(L10n.tr("chat.workspace.create"))
                        .font(.system(size: 20, weight: .regular))
                        .tracking(-0.2)
                        .foregroundStyle(Color(uiColor: ChatUIDesign.Color.offBlack))

                    Text(L10n.tr("chat.workspace.createMessage"))
                        .font(.system(size: 14))
                        .foregroundStyle(Color(uiColor: ChatUIDesign.Color.black60))
                        .multilineTextAlignment(.center)
                }

                TextField(L10n.tr("chat.workspace.namePlaceholder"), text: $workspaceName)
                    .focused($isTextFieldFocused)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        Color(uiColor: ChatUIDesign.Color.pureWhite),
                        in: RoundedRectangle(cornerRadius: ChatUIDesign.Radius.button, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: ChatUIDesign.Radius.button, style: .continuous)
                            .stroke(Color(uiColor: ChatUIDesign.Color.oatBorder), lineWidth: 1)
                    )

                HStack(spacing: 12) {
                    Button(action: { isPresented = false }) {
                        Text(L10n.tr("common.cancel"))
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Color(uiColor: ChatUIDesign.Color.offBlack))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: ChatUIDesign.Radius.button, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: ChatUIDesign.Radius.button, style: .continuous)
                                    .stroke(Color(uiColor: ChatUIDesign.Color.offBlack), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)

                    Button(action: {
                        onCreate()
                        isPresented = false
                    }) {
                        Text(L10n.tr("common.create"))
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Color(uiColor: ChatUIDesign.Color.pureWhite))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(
                                workspaceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    ? Color(uiColor: ChatUIDesign.Color.black50).opacity(0.3)
                                    : Color(uiColor: ChatUIDesign.Color.offBlack)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: ChatUIDesign.Radius.button, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(workspaceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(24)
            .frame(width: 320)
            .background(
                Color(uiColor: ChatUIDesign.Color.warmCream),
                in: RoundedRectangle(cornerRadius: ChatUIDesign.Radius.card, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: ChatUIDesign.Radius.card, style: .continuous)
                    .stroke(Color(uiColor: ChatUIDesign.Color.oatBorder), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.08), radius: 24, x: 0, y: 8)
            .padding(.bottom, 60)
        }
        .onAppear {
            isTextFieldFocused = true
        }
    }
}
