//
//  ChatRootView.swift
//  OpenAva
//
//  Created by Codin on 2024.
//

import ChatClient
import ChatUI
import Foundation
import SwiftUI

struct ChatRootView: View {
    @Environment(\.appContainerStore) private var containerStore
    @Environment(\.appWindowCoordinator) private var windowCoordinator
    @Environment(\.openWindow) private var openWindow
    @Environment(\.scenePhase) private var scenePhase
    // Keep destination navigation state at root so config-driven ChatScreen
    // recreation does not pop pushed pages unexpectedly.
    @State private var destinationPath = NavigationPath()
    @State private var showsAgentOnboarding = false
    @State private var showsLocalAgentCreation = false
    @State private var didEvaluateOnboarding = false
    @State private var currentSessionKey: String?
    @State private var sessions: [ChatSession] = []
    @State private var sessionsByAgentKey: [String: [ChatSession]] = [:]
    @State private var currentSessionKeyByAgentKey: [String: String] = [:]
    @State private var autoCompactEnabled = true
    /// Pending message from an App Intent, consumed once by ChatViewControllerWrapper.
    @State private var pendingAutoSendID: String? = nil
    @State private var pendingAutoSendMessage: String? = nil

    private enum MenuDestination: Hashable {
        case llm
        case context
        case cron
        case skills
    }

    var body: some View {
        NavigationStack(path: $destinationPath) {
            Group {
                ChatScreen(
                    container: containerStore.container,
                    scopedConversationID: scopedConversationID(
                        for: currentSessionKey ?? resolvedDefaultSessionKey,
                        agentID: containerStore.activeAgent?.id
                    ),
                    currentSessionKey: currentSessionKey ?? resolvedDefaultSessionKey,
                    defaultSessionKey: resolvedDefaultSessionKey,
                    sessions: sessions,
                    agents: containerStore.agents,
                    activeAgentID: containerStore.activeAgent?.id,
                    activeAgentName: currentActiveAgentName,
                    activeAgentEmoji: currentActiveAgentEmoji,
                    selectedModelName: currentSelectedModelName,
                    selectedProviderName: resolveSelectedProviderName(),
                    pendingAutoSendID: pendingAutoSendID,
                    pendingAutoSendMessage: pendingAutoSendMessage,
                    onMenuAction: handleMenuAction,
                    onSessionSwitch: handleSessionSwitch,
                    onAgentSwitch: handleAgentSwitch,
                    onCreateLocalAgent: openLocalAgentCreation,
                    onDeleteCurrentAgent: handleDeleteCurrentAgent,
                    onRenameCurrentAgent: handleRenameCurrentAgent,
                    autoCompactEnabled: autoCompactEnabled,
                    onToggleAutoCompact: toggleAutoCompact
                )
                .id(containerAgent + "|" + (currentSessionKey ?? ""))
                // Keep the host NavigationStack bar hidden to avoid duplicating
                // ChatViewController's own header on both iOS and macCatalyst.
                .toolbar(.hidden, for: .navigationBar)
            }
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
            AgentCreationView(onComplete: {
                showsLocalAgentCreation = false
                currentSessionKey = resolvedDefaultSessionKey
                refreshSessions()
            })
        }
        .onAppear {
            autoCompactEnabled = containerStore.activeAgent?.autoCompactEnabled ?? true
            presentOnboardingIfNeeded()
            restoreAgentScopedState(for: containerStore.activeAgent?.id)
            refreshSessions()
            drainPendingAutoSend(for: containerStore.activeAgent?.id)
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                drainPendingAutoSend(for: containerStore.activeAgent?.id)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .OpenAvaIntentAutoSend)) { _ in
            // Re-read from persistent queue so filtering always follows current agent.
            drainPendingAutoSend(for: containerStore.activeAgent?.id)
        }
        .onChange(of: containerStore.activeAgent?.id) { _, newAgentID in
            if newAgentID == nil, !containerStore.hasAgent {
                sessions = []
                currentSessionKey = resolvedDefaultSessionKey
                showsAgentOnboarding = true
                return
            }
            // Keep history panel in sync with the selected agent immediately.
            restoreAgentScopedState(for: newAgentID)
            refreshSessions(for: newAgentID)
            drainPendingAutoSend(for: newAgentID)
            autoCompactEnabled = containerStore.activeAgent?.autoCompactEnabled ?? true
        }
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

    private func presentOnboardingIfNeeded() {
        guard !didEvaluateOnboarding else { return }
        didEvaluateOnboarding = true
        guard containerStore.hasAgent else {
            showsAgentOnboarding = true
            return
        }
    }

    /// Reads one pending auto-send request for the currently active agent.
    private func drainPendingAutoSend(for activeAgentID: UUID?) {
        let activeConversationID = scopedConversationID(
            for: currentSessionKey ?? resolvedDefaultSessionKey,
            agentID: activeAgentID
        )
        guard let request = SkillInvocationService.dequeuePendingAutoSend(
            for: activeAgentID,
            activeConversationID: activeConversationID
        ),
            request.id != pendingAutoSendID
        else { return }
        let id = request.id
        let message = request.message
        pendingAutoSendID = id
        pendingAutoSendMessage = message
    }

    private func refreshSessions() {
        refreshSessions(for: containerStore.activeAgent?.id)
    }

    private func refreshSessions(for agentID: UUID?) {
        let expectedAgentID = agentID
        let agentKey = agentScopeKey(agentID)
        guard let activeAgent = containerStore.activeAgent,
              activeAgent.id == expectedAgentID
        else {
            sessions = []
            sessionsByAgentKey[agentKey] = []
            currentSessionKey = resolvedDefaultSessionKey
            currentSessionKeyByAgentKey[agentKey] = resolvedDefaultSessionKey
            return
        }
        let runtimeRootURL = activeAgent.runtimeURL
        // Read local sessions from TranscriptStorageProvider synchronously.
        let provider = TranscriptStorageProvider.provider(runtimeRootURL: runtimeRootURL)
        let loadedSessions = provider.listSessions()
        guard containerStore.activeAgent?.id == expectedAgentID else { return }

        sessions = loadedSessions
        sessionsByAgentKey[agentKey] = loadedSessions

        let preferredSession = preferredSessionKey(for: activeAgent, scopeKey: agentKey)
        let resolvedSessionKey: String
        if let preferredSession {
            resolvedSessionKey = preferredSession
        } else {
            resolvedSessionKey = resolvedDefaultSessionKey
        }

        currentSessionKey = resolvedSessionKey
        currentSessionKeyByAgentKey[agentKey] = resolvedSessionKey
        persistSelectedSessionKey(resolvedSessionKey, for: activeAgent.id)
    }

    private func handleSessionSwitch(_ sessionKey: String) {
        currentSessionKey = sessionKey
        currentSessionKeyByAgentKey[currentAgentScopeKey] = sessionKey
        persistSelectedSessionKey(sessionKey, for: containerStore.activeAgent?.id)
    }

    private func handleAgentSwitch(_ agentID: UUID) {
        saveAgentScopedState(for: containerStore.activeAgent?.id)
        // Clear all sessions to prevent cross-agent conversation ID conflicts.
        // Transcripts are isolated by runtimeRootURL, so this is safe.
        ConversationSessionManager.shared.removeAllSessions()
        guard containerStore.setActiveAgent(agentID) else { return }
        // onChange(of: activeAgentID) will restore and refresh the scoped history.
    }

    private func handleDeleteCurrentAgent() {
        guard let currentAgentID = containerStore.activeAgent?.id else { return }
        let deletedScopeKey = agentScopeKey(currentAgentID)
        sessionsByAgentKey.removeValue(forKey: deletedScopeKey)
        currentSessionKeyByAgentKey.removeValue(forKey: deletedScopeKey)

        // Remove cached storage provider for the deleted agent's runtime root.
        if let runtimeRootURL = containerStore.activeAgent?.runtimeURL {
            TranscriptStorageProvider.removeProvider(runtimeRootURL: runtimeRootURL)
        }

        // Clear all sessions since conversation IDs no longer contain agent prefix.
        ConversationSessionManager.shared.removeAllSessions()

        guard containerStore.deleteAgent(currentAgentID) else { return }
        if !containerStore.hasAgent {
            sessions = []
            currentSessionKey = resolvedDefaultSessionKey
            showsAgentOnboarding = true
        }
    }

    private func handleRenameCurrentAgent(_ name: String) -> Bool {
        guard let activeAgentID = containerStore.activeAgent?.id else { return false }
        let oldRuntimeURL = containerStore.activeAgent?.runtimeURL
        guard containerStore.renameActiveAgent(to: name) else { return false }

        // Drop old runtime provider cache because the runtime path changed after rename.
        if let oldRuntimeURL {
            TranscriptStorageProvider.removeProvider(runtimeRootURL: oldRuntimeURL)
        }
        refreshSessions(for: activeAgentID)
        return true
    }

    private var currentAgentScopeKey: String {
        agentScopeKey(containerStore.activeAgent?.id)
    }

    private func agentScopeKey(_ agentID: UUID?) -> String {
        agentID?.uuidString ?? "__no_active_agent__"
    }

    private func conversationScopePrefix(for agentID: UUID?) -> String {
        "agent:\(agentScopeKey(agentID))::"
    }

    private func scopedConversationID(for sessionKey: String, agentID _: UUID?) -> String {
        // Use sessionKey directly without agent prefix to allow easy agent directory migration.
        // Transcripts are already isolated by runtimeRootURL per agent.
        sessionKey
    }

    private func saveAgentScopedState(for agentID: UUID?) {
        let key = agentScopeKey(agentID)
        sessionsByAgentKey[key] = sessions
        if let currentSessionKey {
            currentSessionKeyByAgentKey[key] = currentSessionKey
        }
        persistSelectedSessionKey(currentSessionKey, for: agentID)
    }

    private func restoreAgentScopedState(for agentID: UUID?) {
        let key = agentScopeKey(agentID)
        sessions = sessionsByAgentKey[key] ?? []
        currentSessionKey = preferredSessionKey(for: containerStore.activeAgent, scopeKey: key)
            ?? resolvedDefaultSessionKey
    }

    private func preferredSessionKey(for agent: AgentProfile?, scopeKey: String) -> String? {
        if let sessionKey = currentSessionKeyByAgentKey[scopeKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !sessionKey.isEmpty
        {
            return sessionKey
        }
        if let sessionKey = agent?.selectedSessionKey?
            .trimmingCharacters(in: .whitespacesAndNewlines), !sessionKey.isEmpty
        {
            return sessionKey
        }
        return nil
    }

    private func persistSelectedSessionKey(_ sessionKey: String?, for agentID: UUID?) {
        guard let agentID else { return }
        _ = containerStore.setSelectedSessionKey(sessionKey, for: agentID)
    }

    private func openLocalAgentCreation() {
        #if targetEnvironment(macCatalyst)
            windowCoordinator.openAgentCreation()
            openWindow(id: AppWindowID.agentCreation)
        #else
            showsLocalAgentCreation = true
        #endif
    }

    private func handleMenuAction(_ action: ChatViewControllerWrapper.MenuAction) {
        #if targetEnvironment(macCatalyst)
            let section: SettingsWindowSection = switch action {
            case .openLLM:
                .llm
            case .openContext:
                .context
            case .openCron:
                .cron
            case .openSkills:
                .skills
            }
            windowCoordinator.openSettings(section)
            openWindow(id: AppWindowID.settings)
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
            }
        #endif
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
    private let scopedConversationID: String
    private let currentSessionKey: String
    private let defaultSessionKey: String
    private let sessions: [ChatSession]
    private let agents: [AgentProfile]
    private let activeAgentID: UUID?
    private let activeAgentName: String
    private let activeAgentEmoji: String
    private let selectedModelName: String
    private let selectedProviderName: String
    private let pendingAutoSendID: String?
    private let pendingAutoSendMessage: String?
    private let onMenuAction: ((ChatViewControllerWrapper.MenuAction) -> Void)?
    private let onSessionSwitch: ((String) -> Void)?
    private let onAgentSwitch: ((UUID) -> Void)?
    private let onCreateLocalAgent: (() -> Void)?
    private let onDeleteCurrentAgent: (() -> Void)?
    private let onRenameCurrentAgent: ((String) -> Bool)?
    private let autoCompactEnabled: Bool
    private let onToggleAutoCompact: (() -> Void)?

    init(
        container: AppContainer,
        scopedConversationID: String,
        currentSessionKey: String,
        defaultSessionKey: String,
        sessions: [ChatSession],
        agents: [AgentProfile],
        activeAgentID: UUID?,
        activeAgentName: String,
        activeAgentEmoji: String,
        selectedModelName: String,
        selectedProviderName: String,
        pendingAutoSendID: String? = nil,
        pendingAutoSendMessage: String? = nil,
        onMenuAction: ((ChatViewControllerWrapper.MenuAction) -> Void)? = nil,
        onSessionSwitch: ((String) -> Void)? = nil,
        onAgentSwitch: ((UUID) -> Void)? = nil,
        onCreateLocalAgent: (() -> Void)? = nil,
        onDeleteCurrentAgent: (() -> Void)? = nil,
        onRenameCurrentAgent: ((String) -> Bool)? = nil,
        autoCompactEnabled: Bool = true,
        onToggleAutoCompact: (() -> Void)? = nil
    ) {
        self.container = container
        self.scopedConversationID = scopedConversationID
        self.currentSessionKey = currentSessionKey
        self.defaultSessionKey = defaultSessionKey
        self.sessions = sessions
        self.agents = agents
        self.activeAgentID = activeAgentID
        self.activeAgentName = activeAgentName
        self.activeAgentEmoji = activeAgentEmoji
        self.selectedModelName = selectedModelName
        self.selectedProviderName = selectedProviderName
        self.pendingAutoSendID = pendingAutoSendID
        self.pendingAutoSendMessage = pendingAutoSendMessage
        self.onMenuAction = onMenuAction
        self.onSessionSwitch = onSessionSwitch
        self.onAgentSwitch = onAgentSwitch
        self.onCreateLocalAgent = onCreateLocalAgent
        self.onDeleteCurrentAgent = onDeleteCurrentAgent
        self.onRenameCurrentAgent = onRenameCurrentAgent
        self.autoCompactEnabled = autoCompactEnabled
        self.onToggleAutoCompact = onToggleAutoCompact
    }

    var body: some View {
        ChatViewControllerWrapper(
            conversationID: scopedConversationID,
            workspaceRootURL: container.config.agent.workspaceRootURL,
            runtimeRootURL: container.config.agent.runtimeRootURL,
            chatClient: container.services.chatClient,
            toolProvider: RegistryToolProvider(
                toolInvokeService: container.services.localToolInvokeService,
                // Combine agent and conversation scope to prevent cross-agent web_view collisions.
                invocationSessionID: "\(activeAgentID?.uuidString ?? "global")::\(scopedConversationID)"
            ),
            systemPrompt: container.config.selectedLLMModel?.systemPrompt,
            sessions: sessions,
            agents: agents,
            activeAgentID: activeAgentID,
            activeAgentName: activeAgentName,
            activeAgentEmoji: activeAgentEmoji,
            selectedModelName: selectedModelName,
            selectedProviderName: selectedProviderName,
            defaultSessionKey: defaultSessionKey,
            currentSessionKey: currentSessionKey,
            pendingAutoSendID: pendingAutoSendID,
            pendingAutoSendMessage: pendingAutoSendMessage,
            onMenuAction: onMenuAction,
            onSessionSwitch: onSessionSwitch,
            onAgentSwitch: onAgentSwitch,
            onCreateLocalAgent: onCreateLocalAgent,
            onDeleteCurrentAgent: onDeleteCurrentAgent,
            onRenameCurrentAgent: onRenameCurrentAgent,
            modelConfig: container.config.selectedLLMModel,
            autoCompactEnabled: autoCompactEnabled,
            onToggleAutoCompact: onToggleAutoCompact
        )
        .id(scopedConversationID)
    }
}

#Preview {
    ChatRootView()
        .environment(\.appContainerStore, AppContainerStore(container: .makeDefault()))
        .environment(\.appContainer, .makeDefault())
}
