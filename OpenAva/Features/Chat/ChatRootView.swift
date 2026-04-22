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
    @State private var didEvaluateOnboarding = false
    /// Pending message from an App Intent, consumed once by ChatViewControllerWrapper.
    @State private var pendingAutoSendID: String? = nil
    @State private var pendingAutoSendMessage: String? = nil
    @State private var menuRefreshToken: Int = 0

    private enum MenuDestination: Hashable {
        case llm
        case context
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
        .onChange(of: containerStore.agents) { _, _ in
            menuRefreshToken &+= 1
            updateHeartbeatService()
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
        return ChatScreen(
            container: containerStore.container,
            scopedSessionID: scopedSessionID(
                for: sessionKey,
                agentID: containerStore.activeAgent?.id
            ),
            agents: containerStore.agents,
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
            onAgentSwitch: handleAgentSwitch,
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

    private func consumePendingAutoSend(_ id: String) {
        guard pendingAutoSendID == id else { return }
        pendingAutoSendID = nil
        pendingAutoSendMessage = nil
    }

    private func handleAgentSwitch(_ agentID: UUID) {
        // Keep existing sessions alive so in-flight tasks can keep running
        // when users switch to another agent.
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

    private func scopedSessionID(for sessionKey: String, agentID _: UUID?) -> String {
        // Use sessionKey directly without agent prefix to allow easy agent directory migration.
        // Transcripts are already isolated by runtimeRootURL per agent.
        sessionKey
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
                mainSessionID: scopedSessionID(for: primarySessionKey, agentID: agent.id),
                agentName: agent.name,
                agentEmoji: agent.emoji,
                workspaceRootURL: agent.workspaceURL,
                runtimeRootURL: agent.runtimeURL,
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
    private let agents: [AgentProfile]
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
    private let onAgentSwitch: ((UUID) -> Void)?
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
        agents: [AgentProfile],
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
        onAgentSwitch: ((UUID) -> Void)? = nil,
        onCreateLocalAgent: (() -> Void)? = nil,
        onDeleteCurrentAgent: (() -> Void)? = nil,
        onRenameCurrentAgent: ((String) -> Bool)? = nil,
        autoCompactEnabled: Bool = true,
        showsSystemTopBar: Bool = true,
        onToggleAutoCompact: (() -> Void)? = nil
    ) {
        self.container = container
        self.scopedSessionID = scopedSessionID
        self.agents = agents
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
        self.onAgentSwitch = onAgentSwitch
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
            .onReceive(NotificationCenter.default.publisher(for: .chatToolbarRenameRequested)) { _ in
                renameText = activeAgentName
                showsRenameAlert = true
            }
    }

    @ViewBuilder
    private var contentView: some View {
        #if targetEnvironment(macCatalyst)
            chatControllerView
        #else
            chatControllerView
                .safeAreaInset(edge: .top, spacing: 0) {
                    TopoBotNavigationBar(
                        agentName: activeAgentName,
                        agentEmoji: activeAgentEmoji,
                        modelName: selectedModelName,
                        agents: agents,
                        activeAgentID: activeAgentID,
                        autoCompactEnabled: autoCompactEnabled,
                        onTapModel: { onMenuAction?(.openLLM) },
                        onMenuAction: onMenuAction,
                        onAgentSwitch: onAgentSwitch,
                        onCreateLocalAgent: onCreateLocalAgent,
                        onDeleteCurrentAgent: onDeleteCurrentAgent,
                        onToggleAutoCompact: onToggleAutoCompact
                    )
                }
        #endif
    }

    private var chatControllerView: some View {
        ChatViewControllerWrapper(
            sessionID: scopedSessionID,
            workspaceRootURL: container.config.agent.workspaceRootURL,
            runtimeRootURL: container.config.agent.runtimeRootURL,
            chatClient: container.services.chatClient,
            toolProvider: ToolRegistryProvider(
                toolRuntime: container.services.toolRuntime,
                invocationSessionID: "\(activeAgentID?.uuidString ?? "global")::\(scopedSessionID)"
            ),
            systemPrompt: container.config.selectedLLMModel?.systemPrompt,
            agents: agents,
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
            onAgentSwitch: onAgentSwitch,
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
        .toolbar(.hidden, for: .navigationBar)
    }
}

#Preview {
    ChatRootView()
        .environment(\.appContainerStore, AppContainerStore(container: .makeDefault()))
        .environment(\.appContainer, .makeDefault())
}
