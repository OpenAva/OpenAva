//
//  ChatRootView.swift
//  OpenAva
//
//  Created by Codin on 2024.
//

import ChatClient
import ChatUI
import Foundation
import OpenClawKit
import SwiftUI
import UserNotifications
#if targetEnvironment(macCatalyst)
    import UIKit
#endif

struct ChatRootView: View {
    @Environment(\.appContainerStore) private var containerStore
    @Environment(\.appWindowCoordinator) private var windowCoordinator
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    // Keep destination navigation state at root so config-driven ChatScreen
    // recreation does not pop pushed pages unexpectedly.
    @State private var destinationPath = NavigationPath()
    @State private var showsAgentOnboarding = false
    @State private var autoCompactEnabled: Bool = true
    @State private var showsLocalAgentCreation = false
    @State private var showsRemoteControl = false
    @State private var agentCreationMode: AgentCreationViewModel.CreationMode = .singleAgent
    @State private var didEvaluateOnboarding = false
    /// Pending message from an App Intent, consumed once by ChatViewControllerWrapper.
    @State private var pendingAutoSendID: String? = nil
    @State private var pendingAutoSendMessage: String? = nil
    @State private var targetTeamID: UUID?
    @State private var teamToManageAgents: ManageAgentsSheetTarget?
    @State private var showsDeleteTeamAlert = false
    @State private var teamToDelete: UUID?

    private enum MenuDestination: Hashable {
        case llm
        case context
        case cron
        case skills
        case remoteControl
    }

    private struct ManageAgentsSheetTarget: Identifiable {
        let id: UUID
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
                AgentCreationView(initialMode: agentCreationMode, targetTeamID: targetTeamID, onComplete: {
                    showsLocalAgentCreation = false
                    targetTeamID = nil
                })
            }
        }
        .sheet(isPresented: $showsRemoteControl) {
            NavigationStack {
                RemoteControlSettingsView(onDone: {
                    showsRemoteControl = false
                })
            }
            .presentationDetents([.large])
            #if os(macOS) || targetEnvironment(macCatalyst)
                .frame(minWidth: 540, minHeight: 600)
            #endif
        }
        .sheet(item: $teamToManageAgents) { target in
            ManageTeamAgentsSheet(teamID: target.id)
        }
        .alert(isPresented: $showsDeleteTeamAlert) {
            Alert(
                title: Text(L10n.tr("team.management.delete.confirm.title")),
                message: Text(L10n.tr("team.management.delete.confirm.message")),
                primaryButton: .destructive(Text(L10n.tr("common.delete"))) {
                    if let id = teamToDelete {
                        containerStore.deleteTeam(id)
                    }
                    teamToDelete = nil
                },
                secondaryButton: .cancel(Text(L10n.tr("common.cancel"))) {
                    teamToDelete = nil
                }
            )
        }
        .onAppear {
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
        .onChange(of: containerStore.activeAgent?.id) { _, newAgentID in
            if newAgentID == nil, !containerStore.hasAgent {
                showsAgentOnboarding = true
                HeartbeatService.shared.stop()
                return
            }
            drainPendingAutoSend()
            autoCompactEnabled = containerStore.activeAgent?.autoCompactEnabled ?? true
            updateHeartbeatService()
        }
        .onChange(of: containerAgent) { _, _ in
            updateHeartbeatService()
        }
        .onChange(of: autoCompactEnabled) { _, _ in
            updateHeartbeatService()
        }
    }

    private var rootContent: some View {
        chatScreenView
    }

    private var chatScreenView: some View {
        let sessionKey = primarySessionKey
        return ChatScreen(
            container: containerStore.container,
            scopedSessionID: scopedSessionID(
                for: sessionKey,
                agentID: containerStore.activeAgent?.id
            ),
            teams: containerStore.teams,
            agents: containerStore.agents,
            activeAgentID: containerStore.activeAgent?.id,
            activeAgentName: currentActiveAgentName,
            activeAgentEmoji: currentActiveAgentEmoji,
            selectedModelName: currentSelectedModelName,
            selectedProviderName: resolveSelectedProviderName(),
            pendingAutoSendID: pendingAutoSendID,
            pendingAutoSendMessage: pendingAutoSendMessage,
            onMenuAction: handleMenuAction,
            onAgentSwitch: handleAgentSwitch,
            onCreateLocalAgent: openLocalAgentCreation,
            onCreateLocalTeam: openLocalTeamCreation,
            onDeleteCurrentAgent: handleDeleteCurrentAgent,
            onRenameCurrentAgent: handleRenameCurrentAgent,
            onAddAgentToTeam: handleAddAgentToTeam,
            onCreateAgentForTeam: handleCreateAgentForTeam,
            onDeleteTeam: handleDeleteTeamRequest,
            autoCompactEnabled: autoCompactEnabled,
            onToggleAutoCompact: toggleAutoCompact
        )
        .id(containerAgent)
        #if targetEnvironment(macCatalyst)
            .toolbar(.hidden, for: .navigationBar)
        #endif
            .ignoresSafeArea(edges: .top)
    }

    /// Recreate the chat screen when runtime config changes.
    private var containerAgent: String {
        let selectedModel = containerStore.container.config.selectedLLMModel
        let agent = containerStore.container.config.agent

        // Keep this split to avoid Swift type-checking timeouts.
        let modelKey = [
            selectedModel?.id.uuidString ?? "",
            selectedModel?.endpoint?.absoluteString ?? "",
            selectedModel?.model ?? "",
            selectedModel?.provider ?? "",
            String(selectedModel?.requestTimeoutMs ?? 0),
        ].joined(separator: "|")

        let agentKey = [
            agent.id ?? "",
            agent.name,
            agent.emoji,
            agent.workspaceRootURL?.path ?? "",
        ].joined(separator: "|")

        return [modelKey, agentKey].joined(separator: "|")
    }

    private var resolvedDefaultSessionKey: String {
        let trimmed = containerStore.container.defaultSessionKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "main" : trimmed
    }

    private var primarySessionKey: String {
        resolvedDefaultSessionKey
    }

    private func presentOnboardingIfNeeded() {
        guard !didEvaluateOnboarding else { return }
        didEvaluateOnboarding = true
        guard containerStore.hasAgent else {
            showsAgentOnboarding = true
            return
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

    private func handleAgentSwitch(_ agentID: UUID) {
        // Clear all sessions to prevent cross-agent session ID conflicts.
        // Transcripts are isolated by runtimeRootURL, so this is safe.
        ConversationSessionManager.shared.removeAllSessions()
        guard containerStore.setActiveAgent(agentID) else { return }
    }

    private func handleDeleteCurrentAgent() {
        guard let currentAgentID = containerStore.activeAgent?.id else { return }

        // Remove cached storage provider for the deleted agent's runtime root.
        if let runtimeRootURL = containerStore.activeAgent?.runtimeURL {
            TranscriptStorageProvider.removeProvider(runtimeRootURL: runtimeRootURL)
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
        let oldRuntimeURL = containerStore.activeAgent?.runtimeURL
        guard containerStore.renameActiveAgent(to: name) else { return false }

        // Drop old runtime provider cache because the runtime path changed after rename.
        if let oldRuntimeURL {
            TranscriptStorageProvider.removeProvider(runtimeRootURL: oldRuntimeURL)
        }
        return true
    }

    private func handleAddAgentToTeam(_ teamID: UUID) {
        teamToManageAgents = ManageAgentsSheetTarget(id: teamID)
    }

    private func handleCreateAgentForTeam(_ teamID: UUID) {
        #if targetEnvironment(macCatalyst)
            windowCoordinator.openAgentCreation(targetTeamID: teamID)
            activateOrOpenWindow(id: AppWindowID.agentCreation)
        #else
            targetTeamID = teamID
            agentCreationMode = .singleAgent
            showsLocalAgentCreation = true
        #endif
    }

    private func handleDeleteTeamRequest(_ teamID: UUID) {
        teamToDelete = teamID
        showsDeleteTeamAlert = true
    }

    private func scopedSessionID(for sessionKey: String, agentID _: UUID?) -> String {
        // Use sessionKey directly without agent prefix to allow easy agent directory migration.
        // Transcripts are already isolated by runtimeRootURL per agent.
        sessionKey
    }

    private func updateHeartbeatService() {
        guard scenePhase == .active,
              let activeAgent = containerStore.activeAgent,
              let workspaceRootURL = containerStore.container.config.agent.workspaceRootURL,
              let runtimeRootURL = containerStore.container.config.agent.runtimeRootURL,
              let selectedModel = containerStore.container.config.selectedLLMModel,
              let chatClient = containerStore.container.services.chatClient
        else {
            HeartbeatService.shared.stop()
            return
        }

        HeartbeatService.shared.reconfigure(
            .init(
                agentID: activeAgent.id.uuidString,
                mainSessionID: scopedSessionID(for: primarySessionKey, agentID: activeAgent.id),
                agentName: activeAgent.name,
                agentEmoji: activeAgent.emoji,
                workspaceRootURL: workspaceRootURL,
                runtimeRootURL: runtimeRootURL,
                baseSystemPrompt: selectedModel.systemPrompt,
                chatClient: chatClient,
                modelConfig: selectedModel,
                toolInvokeService: containerStore.container.services.localToolInvokeService,
                autoCompactEnabled: autoCompactEnabled
            )
        )
    }

    private func openLocalAgentCreation() {
        #if targetEnvironment(macCatalyst)
            windowCoordinator.openAgentCreation()
            activateOrOpenWindow(id: AppWindowID.agentCreation)
        #else
            agentCreationMode = .singleAgent
            showsLocalAgentCreation = true
        #endif
    }

    private func openLocalTeamCreation() {
        #if targetEnvironment(macCatalyst)
            windowCoordinator.openTeamCreation()
            activateOrOpenWindow(id: AppWindowID.agentCreation)
        #else
            agentCreationMode = .defaultTeam
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
                .context
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
            } else if let section {
                openWindow(id: AppWindowID.settings, value: section.rawValue)
            }
        #else
            switch action {
            case .openLLM:
                destinationPath.append(MenuDestination.llm)
            case .openContext:
                destinationPath.append(MenuDestination.context)
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
            _ = await HeartbeatService.shared.requestRunNow()
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
            case .context:
                ContextSettingsView()
                    .navigationTitle(L10n.tr("settings.context.navigationTitle"))
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
        containerStore.activeAgent?.name ?? L10n.tr("chat.activeAgent.fallbackName")
    }

    private var currentActiveAgentEmoji: String {
        containerStore.activeAgent?.emoji ?? ""
    }

    private var currentSelectedModelName: String {
        containerStore.container.config.selectedLLMModel?.name ?? L10n.tr("chat.selectedModel.notSelected")
    }

    private func toggleAutoCompact() {
        let newValue = !autoCompactEnabled
        containerStore.setAutoCompact(newValue)
        autoCompactEnabled = newValue
    }
}

private struct ChatScreen: View {
    private let container: AppContainer
    private let scopedSessionID: String
    private let teams: [TeamProfile]
    private let agents: [AgentProfile]
    private let activeAgentID: UUID?
    private let activeAgentName: String
    private let activeAgentEmoji: String
    private let selectedModelName: String
    private let selectedProviderName: String
    private let pendingAutoSendID: String?
    private let pendingAutoSendMessage: String?
    private let onMenuAction: ((ChatViewControllerWrapper.MenuAction) -> Void)?
    private let onAgentSwitch: ((UUID) -> Void)?
    private let onCreateLocalAgent: (() -> Void)?
    private let onCreateLocalTeam: (() -> Void)?
    private let onDeleteCurrentAgent: (() -> Void)?
    private let onRenameCurrentAgent: ((String) -> Bool)?
    private let onAddAgentToTeam: ((UUID) -> Void)?
    private let onCreateAgentForTeam: ((UUID) -> Void)?
    private let onDeleteTeam: ((UUID) -> Void)?
    private let autoCompactEnabled: Bool
    private let onToggleAutoCompact: (() -> Void)?

    @State private var showsRenameAlert = false
    @State private var renameText = ""

    init(
        container: AppContainer,
        scopedSessionID: String,
        teams: [TeamProfile],
        agents: [AgentProfile],
        activeAgentID: UUID?,
        activeAgentName: String,
        activeAgentEmoji: String,
        selectedModelName: String,
        selectedProviderName: String,
        pendingAutoSendID: String? = nil,
        pendingAutoSendMessage: String? = nil,
        onMenuAction: ((ChatViewControllerWrapper.MenuAction) -> Void)? = nil,
        onAgentSwitch: ((UUID) -> Void)? = nil,
        onCreateLocalAgent: (() -> Void)? = nil,
        onCreateLocalTeam: (() -> Void)? = nil,
        onDeleteCurrentAgent: (() -> Void)? = nil,
        onRenameCurrentAgent: ((String) -> Bool)? = nil,
        onAddAgentToTeam: ((UUID) -> Void)? = nil,
        onCreateAgentForTeam: ((UUID) -> Void)? = nil,
        onDeleteTeam: ((UUID) -> Void)? = nil,
        autoCompactEnabled: Bool = true,
        onToggleAutoCompact: (() -> Void)? = nil
    ) {
        self.container = container
        self.scopedSessionID = scopedSessionID
        self.teams = teams
        self.agents = agents
        self.activeAgentID = activeAgentID
        self.activeAgentName = activeAgentName
        self.activeAgentEmoji = activeAgentEmoji
        self.selectedModelName = selectedModelName
        self.selectedProviderName = selectedProviderName
        self.pendingAutoSendID = pendingAutoSendID
        self.pendingAutoSendMessage = pendingAutoSendMessage
        self.onMenuAction = onMenuAction
        self.onAgentSwitch = onAgentSwitch
        self.onCreateLocalAgent = onCreateLocalAgent
        self.onCreateLocalTeam = onCreateLocalTeam
        self.onDeleteCurrentAgent = onDeleteCurrentAgent
        self.onRenameCurrentAgent = onRenameCurrentAgent
        self.onAddAgentToTeam = onAddAgentToTeam
        self.onCreateAgentForTeam = onCreateAgentForTeam
        self.onDeleteTeam = onDeleteTeam
        self.autoCompactEnabled = autoCompactEnabled
        self.onToggleAutoCompact = onToggleAutoCompact
    }

    var body: some View {
        ChatViewControllerWrapper(
            sessionID: scopedSessionID,
            workspaceRootURL: container.config.agent.workspaceRootURL,
            runtimeRootURL: container.config.agent.runtimeRootURL,
            chatClient: container.services.chatClient,
            toolProvider: RegistryToolProvider(
                toolInvokeService: container.services.localToolInvokeService,
                invocationSessionID: "\(activeAgentID?.uuidString ?? "global")::\(scopedSessionID)"
            ),
            systemPrompt: container.config.selectedLLMModel?.systemPrompt,
            teams: teams,
            agents: agents,
            activeAgentID: activeAgentID,
            activeAgentName: activeAgentName,
            activeAgentEmoji: activeAgentEmoji,
            selectedModelName: selectedModelName,
            selectedProviderName: selectedProviderName,
            pendingAutoSendID: pendingAutoSendID,
            pendingAutoSendMessage: pendingAutoSendMessage,
            onMenuAction: onMenuAction,
            onAgentSwitch: onAgentSwitch,
            onCreateLocalAgent: onCreateLocalAgent,
            onCreateLocalTeam: onCreateLocalTeam,
            onDeleteCurrentAgent: onDeleteCurrentAgent,
            onRenameCurrentAgent: onRenameCurrentAgent,
            onAddAgentToTeam: onAddAgentToTeam,
            onCreateAgentForTeam: onCreateAgentForTeam,
            onDeleteTeam: onDeleteTeam,
            modelConfig: container.config.selectedLLMModel,
            autoCompactEnabled: autoCompactEnabled,
            onToggleAutoCompact: onToggleAutoCompact
        )
        .id(scopedSessionID)
        .background(Color(uiColor: ChatUIDesign.Color.warmCream).ignoresSafeArea())
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        #if targetEnvironment(macCatalyst)
            .toolbar(.hidden, for: .navigationBar)
        #endif
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
            .onReceive(NotificationCenter.default.publisher(for: .chatToolbarRenameRequested)) { _ in
                renameText = activeAgentName
                showsRenameAlert = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .chatToolbarHeartbeatRequested)) { _ in
                onMenuAction?(.runHeartbeatNow)
            }
            .onReceive(NotificationCenter.default.publisher(for: .chatToolbarOpenModelRequested)) { _ in
                onMenuAction?(.openLLM)
            }
    }
}

#Preview {
    ChatRootView()
        .environment(\.appContainerStore, AppContainerStore(container: .makeDefault()))
        .environment(\.appContainer, .makeDefault())
}
