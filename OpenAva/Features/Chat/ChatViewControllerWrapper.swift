import ChatClient
import ChatUI
import OpenClawKit
import SwiftUI
import UIKit
import UserNotifications

#if targetEnvironment(macCatalyst)
    private final class CatalystChatViewController: ChatViewController {
        var onOpenModelSettings: (() -> Void)?
        private var commandObserver: NSObjectProtocol?

        override var canBecomeFirstResponder: Bool {
            true
        }

        private func installCommandObserverIfNeeded() {
            guard commandObserver == nil else { return }
            commandObserver = NotificationCenter.default.addObserver(
                forName: .openAvaCatalystGlobalCommand,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                self?.handleGlobalCommand(notification)
            }
        }

        deinit {
            if let commandObserver {
                NotificationCenter.default.removeObserver(commandObserver)
            }
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            installCommandObserverIfNeeded()
            becomeFirstResponder()
        }

        override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
            super.viewWillTransition(to: size, with: coordinator)
            coordinator.animate(alongsideTransition: { [weak self] _ in
                self?.view.setNeedsLayout()
                self?.view.layoutIfNeeded()
            })
        }

        private func handleGlobalCommand(_ notification: Notification) {
            guard let command = CatalystGlobalCommandCenter.resolve(notification) else { return }
            switch command {
            case .newConversation:
                handleNewConversationShortcut()
            case .openModelSettings:
                handleOpenModelSettingsShortcut()
            case .focusInput:
                handleFocusInputShortcut()
            }
        }

        @objc private func handleNewConversationShortcut() {
            chatInputDidTriggerCommand(chatInputView, command: "/new")
        }

        @objc private func handleOpenModelSettingsShortcut() {
            onOpenModelSettings?()
        }

        @objc private func handleFocusInputShortcut() {
            chatInputView.focus()
        }
    }
#endif

/// SwiftUI wrapper for ChatViewController from Common/ChatUI.
struct ChatViewControllerWrapper: UIViewControllerRepresentable {
    enum MenuAction {
        case openLLM
        case openContext
        case openCron
        case openSkills
        case openRemoteControl
        case runHeartbeatNow
    }

    let sessionID: String
    let workspaceRootURL: URL?
    let runtimeRootURL: URL?
    let chatClient: (any ChatClient)?
    let toolProvider: ToolProvider?
    let systemPrompt: String?
    let sessions: [ChatSession]
    let agents: [AgentProfile]
    let activeAgentID: UUID?
    let activeAgentName: String
    let activeAgentEmoji: String
    let selectedModelName: String
    let selectedProviderName: String
    let defaultSessionKey: String
    let currentSessionKey: String?
    /// Non-nil when an App Intent wants to auto-send a message through the real agentic loop.
    /// `pendingAutoSendID` is a unique token so the coordinator never submits the same request twice.
    let pendingAutoSendID: String?
    let pendingAutoSendMessage: String?
    let onMenuAction: ((MenuAction) -> Void)?
    let onSessionSwitch: ((String) -> Void)?
    let onAgentSwitch: ((UUID) -> Void)?
    let onCreateLocalAgent: (() -> Void)?
    let onDeleteCurrentAgent: (() -> Void)?
    let onRenameCurrentAgent: ((String) -> Bool)?
    let modelConfig: AppConfig.LLMModel?
    let autoCompactEnabled: Bool
    let onToggleAutoCompact: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onMenuAction: onMenuAction,
            sessions: sessions,
            agents: agents,
            activeAgentID: activeAgentID,
            activeAgentName: activeAgentName,
            activeAgentEmoji: activeAgentEmoji,
            selectedModelName: selectedModelName,
            selectedProviderName: selectedProviderName,
            defaultSessionKey: defaultSessionKey,
            currentSessionKey: currentSessionKey,
            autoCompactEnabled: autoCompactEnabled,
            onSessionSwitch: onSessionSwitch,
            onAgentSwitch: onAgentSwitch,
            onCreateLocalAgent: onCreateLocalAgent,
            onDeleteCurrentAgent: onDeleteCurrentAgent,
            onRenameCurrentAgent: onRenameCurrentAgent,
            onToggleAutoCompact: onToggleAutoCompact
        )
    }

    func makeUIViewController(context: Context) -> ChatViewController {
        let makeNewSessionID: @MainActor () -> String = {
            "chat-\(UUID().uuidString)"
        }

        let storageProvider: any StorageProvider
        let sessionDelegate: SessionDelegate?
        if let runtimeRootURL, activeAgentID != nil {
            // Reuse one provider per runtime root so chat history survives view recreation.
            storageProvider = TranscriptStorageProvider.provider(runtimeRootURL: runtimeRootURL)
            sessionDelegate = AgentSessionDelegate(
                sessionID: sessionID,
                workspaceRootURL: workspaceRootURL,
                runtimeRootURL: runtimeRootURL,
                baseSystemPrompt: systemPrompt,
                chatClient: chatClient,
                agentName: activeAgentName,
                agentEmoji: activeAgentEmoji
            )
        } else {
            // New install / no active agent: avoid touching any runtime-root based agent pipeline.
            storageProvider = DisposableStorageProvider.shared
            sessionDelegate = nil
        }

        // Create session configuration
        let sessionConfiguration = ConversationSession.Configuration(
            storage: storageProvider,
            tools: toolProvider,
            delegate: sessionDelegate,
            systemPrompt: systemPrompt ?? "You are a helpful assistant.",
            collapseReasoningWhenComplete: true
        )

        // Create models with ChatClient
        var models = ConversationSession.Models()
        if let chatClient {
            models.chat = ConversationSession.Model(
                client: chatClient,
                capabilities: [.visual, .tool],
                contextLength: modelConfig?.contextTokens ?? 128_000,
                autoCompactEnabled: autoCompactEnabled
            )
        }

        // Create and configure ChatViewController
        let inputConfiguration = ChatInputConfiguration(
            quickSettingItems: buildQuickSettingItems()
        )
        let viewConfiguration = ChatViewController.Configuration(
            input: inputConfiguration,
            newSessionIDProvider: makeNewSessionID
        )
        let chatViewController: ChatViewController

        #if targetEnvironment(macCatalyst)
            let catalystController = CatalystChatViewController(
                sessionID: sessionID,
                models: models,
                sessionConfiguration: sessionConfiguration,
                configuration: viewConfiguration
            )
            catalystController.onOpenModelSettings = { [weak coordinator = context.coordinator] in
                coordinator?.onMenuAction?(.openLLM)
            }
            chatViewController = catalystController
        #else
            chatViewController = ChatViewController(
                sessionID: sessionID,
                models: models,
                sessionConfiguration: sessionConfiguration,
                configuration: viewConfiguration
            )
        #endif

        // Configure for navigation bar integration
        chatViewController.prefersNavigationBarManaged = false
        // Route top-right menu interactions back to SwiftUI.
        chatViewController.menuDelegate = context.coordinator
        chatViewController.updateHeader(.init(
            agentName: activeAgentName,
            agentEmoji: activeAgentEmoji,
            modelName: selectedModelName,
            providerName: selectedProviderName
        ))

        return chatViewController
    }

    private func buildQuickSettingItems() -> [QuickSettingItem] {
        var items: [QuickSettingItem] = [
            // Localize quick command labels while preserving the slash command token.
            .command(id: "new-conversation", title: L10n.tr("chat.command.newConversation"), icon: "plus", command: "/new"),
            .command(id: "run-heartbeat", title: L10n.tr("chat.command.runHeartbeatNow"), icon: "bolt.heart", command: "/heartbeat"),
        ]

        let frequentSkills = buildFrequentSkillItems()
        items.append(contentsOf: frequentSkills)

        return items
    }

    private func buildFrequentSkillItems() -> [QuickSettingItem] {
        guard let workspaceRootURL else {
            return []
        }

        // Quick skills follow the available skill order directly.
        let availableSkills = AgentSkillsLoader
            .listSkills(filterUnavailable: true, visibility: .userInvocable, workspaceRootURL: workspaceRootURL)

        // Return all available skills without limit
        return availableSkills.map { skill in
            .skill(
                id: "skill-\(quickSettingSafeID(skill.name))",
                title: skill.displayName,
                icon: skill.emoji ?? "asterisk",
                prompt: SkillLaunchService.makeInvocationMessage(skillName: skill.name, task: nil),
                autoSubmit: false
            )
        }
    }

    private func quickSettingSafeID(_ value: String) -> String {
        value
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "/", with: "-")
    }

    func updateUIViewController(_ uiViewController: ChatViewController, context: Context) {
        // Keep callbacks and data updated when SwiftUI state changes.
        context.coordinator.onMenuAction = onMenuAction
        context.coordinator.sessions = sessions
        context.coordinator.agents = agents
        context.coordinator.activeAgentID = activeAgentID
        context.coordinator.activeAgentName = activeAgentName
        context.coordinator.activeAgentEmoji = activeAgentEmoji
        context.coordinator.selectedModelName = selectedModelName
        context.coordinator.selectedProviderName = selectedProviderName
        context.coordinator.defaultSessionKey = defaultSessionKey
        context.coordinator.currentSessionKey = currentSessionKey

        // Auto-send on behalf of the intent if this is a new request.
        if let id = pendingAutoSendID,
           let message = pendingAutoSendMessage,
           id != context.coordinator.processedAutoSendID
        {
            context.coordinator.processedAutoSendID = id
            // Use the same submission path as manual user input.
            let content = ChatInputContent(text: message)
            uiViewController.chatInputDidSubmit(uiViewController.chatInputView, object: content) { _ in }
        }

        context.coordinator.onSessionSwitch = onSessionSwitch
        context.coordinator.onAgentSwitch = onAgentSwitch
        context.coordinator.onCreateLocalAgent = onCreateLocalAgent
        context.coordinator.onDeleteCurrentAgent = onDeleteCurrentAgent
        context.coordinator.onRenameCurrentAgent = onRenameCurrentAgent
        context.coordinator.autoCompactEnabled = autoCompactEnabled
        context.coordinator.onToggleAutoCompact = onToggleAutoCompact
        uiViewController.updateAutoCompactEnabled(autoCompactEnabled)

        #if targetEnvironment(macCatalyst)
            if let catalystController = uiViewController as? CatalystChatViewController {
                catalystController.onOpenModelSettings = { [weak coordinator = context.coordinator] in
                    coordinator?.onMenuAction?(.openLLM)
                }
            }
        #endif

        uiViewController.menuDelegate = context.coordinator
        uiViewController.updateHeader(.init(
            agentName: activeAgentName,
            agentEmoji: activeAgentEmoji,
            modelName: selectedModelName,
            providerName: selectedProviderName
        ))
    }
}

extension ChatViewControllerWrapper {
    final class Coordinator: NSObject, ChatViewControllerMenuDelegate {
        /// Tracks the last auto-sent request ID to prevent re-submission on re-render.
        var processedAutoSendID: String?
        var onMenuAction: ((MenuAction) -> Void)?
        var sessions: [ChatSession]
        var agents: [AgentProfile]
        var activeAgentID: UUID?
        var activeAgentName: String
        var activeAgentEmoji: String
        var selectedModelName: String
        var selectedProviderName: String
        var defaultSessionKey: String
        var currentSessionKey: String?
        var onSessionSwitch: ((String) -> Void)?
        var onAgentSwitch: ((UUID) -> Void)?
        var onCreateLocalAgent: (() -> Void)?
        var onDeleteCurrentAgent: (() -> Void)?
        var onRenameCurrentAgent: ((String) -> Bool)?
        var autoCompactEnabled: Bool
        var onToggleAutoCompact: (() -> Void)?

        init(
            onMenuAction: ((MenuAction) -> Void)?,
            sessions: [ChatSession],
            agents: [AgentProfile],
            activeAgentID: UUID?,
            activeAgentName: String,
            activeAgentEmoji: String,
            selectedModelName: String,
            selectedProviderName: String,
            defaultSessionKey: String,
            currentSessionKey: String?,
            autoCompactEnabled: Bool,
            onSessionSwitch: ((String) -> Void)?,
            onAgentSwitch: ((UUID) -> Void)?,
            onCreateLocalAgent: (() -> Void)?,
            onDeleteCurrentAgent: (() -> Void)?,
            onRenameCurrentAgent: ((String) -> Bool)?,
            onToggleAutoCompact: (() -> Void)?
        ) {
            self.onMenuAction = onMenuAction
            self.sessions = sessions
            self.agents = agents
            self.activeAgentID = activeAgentID
            self.activeAgentName = activeAgentName
            self.activeAgentEmoji = activeAgentEmoji
            self.selectedModelName = selectedModelName
            self.selectedProviderName = selectedProviderName
            self.defaultSessionKey = defaultSessionKey
            self.currentSessionKey = currentSessionKey
            self.autoCompactEnabled = autoCompactEnabled
            self.onSessionSwitch = onSessionSwitch
            self.onAgentSwitch = onAgentSwitch
            self.onCreateLocalAgent = onCreateLocalAgent
            self.onDeleteCurrentAgent = onDeleteCurrentAgent
            self.onRenameCurrentAgent = onRenameCurrentAgent
            self.onToggleAutoCompact = onToggleAutoCompact
        }

        func chatViewControllerMenu(_ controller: ChatViewController) -> UIMenu? {
            let renameTitle = L10n.tr("chat.menu.renameAgent")
            let deleteTitle = L10n.tr("chat.menu.deleteAgent")

            // Keep stable order: chat configuration first, then agent management.
            let modelAction = UIAction(
                title: L10n.tr("settings.llm.navigationTitle"),
                image: UIImage(systemName: "cpu")
            ) { [weak self] _ in
                self?.onMenuAction?(.openLLM)
            }
            let contextAction = UIAction(
                title: L10n.tr("settings.context.navigationTitle"),
                image: UIImage(systemName: "doc.text")
            ) { [weak self] _ in
                self?.onMenuAction?(.openContext)
            }
            let skillsAction = UIAction(
                title: L10n.tr("settings.skills.navigationTitle"),
                image: UIImage(systemName: "square.stack.3d.up")
            ) { [weak self] _ in
                self?.onMenuAction?(.openSkills)
            }
            let cronAction = UIAction(
                title: L10n.tr("settings.cron.navigationTitle"),
                image: UIImage(systemName: "calendar.badge.clock")
            ) { [weak self] _ in
                self?.onMenuAction?(.openCron)
            }
            let remoteControlAction = UIAction(
                title: L10n.tr("settings.remoteControl.navigationTitle"),
                image: UIImage(systemName: "dot.radiowaves.left.and.right")
            ) { [weak self] _ in
                self?.onMenuAction?(.openRemoteControl)
            }
            let isBackgroundEnabled = BackgroundExecutionPreferences.shared.isEnabled
            let backgroundAction = UIAction(
                title: L10n.tr("settings.background.enabled"),
                image: UIImage(systemName: "arrow.down.app"),
                state: isBackgroundEnabled ? .on : .off
            ) { _ in
                let preferences = BackgroundExecutionPreferences.shared
                preferences.isEnabled.toggle()
                if preferences.isEnabled {
                    // Keep permission request aligned with settings page behavior.
                    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
                }
            }
            let autoCompactAction = UIAction(
                title: L10n.tr("chat.menu.autoCompact"),
                image: UIImage(systemName: "rectangle.compress.vertical"),
                state: autoCompactEnabled ? .on : .off
            ) { [weak self] _ in
                self?.onToggleAutoCompact?()
            }
            let renameAction = UIAction(
                title: renameTitle,
                image: UIImage(systemName: "pencil")
            ) { [weak self, weak controller] _ in
                guard let self, let controller else { return }
                self.presentRenameCurrentAgentAlert(from: controller)
            }
            let deleteAction = UIAction(
                title: deleteTitle,
                image: UIImage(systemName: "trash"),
                attributes: [.destructive]
            ) { [weak self, weak controller] _ in
                guard let self, let controller else { return }
                self.presentDeleteCurrentAgentAlert(from: controller)
            }

            let configurationMenu = UIMenu(
                // Keep title empty to remove the section header label in the menu.
                title: "",
                options: .displayInline,
                children: [
                    modelAction,
                    skillsAction,
                    contextAction,
                    cronAction,
                    remoteControlAction,
                ]
            )
            let agentManagementMenu = UIMenu(
                title: "",
                options: .displayInline,
                children: [backgroundAction, autoCompactAction, renameAction, deleteAction]
            )

            return UIMenu(children: [
                configurationMenu,
                agentManagementMenu,
            ])
        }

        private func presentDeleteCurrentAgentAlert(from controller: ChatViewController) {
            guard activeAgentID != nil else { return }
            let normalizedName = activeAgentName.trimmingCharacters(in: .whitespacesAndNewlines)
            let agentName = normalizedName.isEmpty ? L10n.tr("chat.menu.thisAgent") : "\"\(normalizedName)\""
            let alert = UIAlertController(
                title: L10n.tr("chat.menu.deleteAlert.title"),
                message: L10n.tr("chat.menu.deleteAlert.message", agentName),
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: L10n.tr("common.cancel"), style: .cancel))
            alert.addAction(UIAlertAction(title: L10n.tr("common.delete"), style: .destructive) { [weak self] _ in
                self?.onDeleteCurrentAgent?()
            })
            controller.present(alert, animated: true)
        }

        private func presentRenameCurrentAgentAlert(from controller: ChatViewController) {
            guard activeAgentID != nil else { return }
            let alert = UIAlertController(
                title: L10n.tr("chat.menu.renameAgentNamed", activeAgentName),
                message: L10n.tr("chat.menu.renameAlert.message"),
                preferredStyle: .alert
            )

            alert.addTextField { [activeAgentName] textField in
                textField.placeholder = L10n.tr("chat.menu.renameAlert.placeholder")
                textField.text = activeAgentName
                textField.clearButtonMode = .whileEditing
            }

            alert.addAction(UIAlertAction(title: L10n.tr("common.cancel"), style: .cancel))
            alert.addAction(UIAlertAction(title: L10n.tr("common.save"), style: .default) { [weak self, weak alert] _ in
                guard let self,
                      let rawName = alert?.textFields?.first?.text
                else {
                    return
                }

                let normalizedName = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !normalizedName.isEmpty else { return }

                let didRename = self.onRenameCurrentAgent?(normalizedName) ?? false
                if !didRename {
                    self.presentRenameFailedAlert(from: controller)
                }
            })

            controller.present(alert, animated: true)
        }

        private func presentRenameFailedAlert(from controller: ChatViewController) {
            let alert = UIAlertController(
                title: L10n.tr("chat.menu.renameFailed.title"),
                message: L10n.tr("chat.menu.renameFailed.message"),
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: L10n.tr("common.ok"), style: .default))
            controller.present(alert, animated: true)
        }

        func chatViewControllerLeadingButton(_: ChatViewController, button: UIButton) {
            button.showsMenuAsPrimaryAction = true
            button.menu = buildAgentMenu()
        }

        func chatViewControllerDidTapAgentTitle(_ controller: ChatViewController) {
            controller.presentLeadingMenu()
        }

        func chatViewControllerDidTapModelTitle(_ controller: ChatViewController) {
            _ = controller
            onMenuAction?(.openLLM)
        }

        func chatViewControllerHandleCommand(_ controller: ChatViewController, command: String) -> Bool {
            _ = controller
            switch command {
            case "/heartbeat":
                onMenuAction?(.runHeartbeatNow)
                return true
            default:
                return false
            }
        }

        func chatViewControllerRequestNewSessionID(_ controller: ChatViewController, from _: String) -> String? {
            _ = controller
            let newID = "chat-\(UUID().uuidString)"
            onSessionSwitch?(newID)
            return newID
        }

        private func buildAgentMenu() -> UIMenu {
            let agentActions: [UIAction]
            if agents.isEmpty {
                agentActions = [
                    UIAction(title: L10n.tr("chat.menu.noAgentsAvailable"), attributes: [.disabled]) { _ in },
                ]
            } else {
                agentActions = agents.map { agent in
                    let title = agent.name
                    let image = self.makeAgentMenuImage(for: agent)
                    let state: UIMenuElement.State = (agent.id == self.activeAgentID) ? .on : .off
                    return UIAction(title: title, image: image, state: state) { [weak self] _ in
                        self?.onAgentSwitch?(agent.id)
                    }
                }
            }

            // Keep creation entries in a separate inline section so they stay at the bottom.
            let createLocalAction = UIAction(
                title: L10n.tr("chat.menu.newLocalAgent"),
                image: UIImage(systemName: "plus")
            ) { [weak self] _ in
                self?.onCreateLocalAgent?()
            }
            // Entry is intentionally hidden until remote agent flow is fully tested.
            // let addRemoteAction = UIAction(
            //     title: "Add Remote Agent (Remote Gateway Agent)",
            //     image: UIImage(systemName: "network"))
            // { [weak self] _ in
            //     self?.onAddRemoteAgent?()
            // }

            let agentSection = UIMenu(title: "", options: .displayInline, children: agentActions)
            let entrySection = UIMenu(title: "", options: .displayInline, children: [createLocalAction])
            return UIMenu(title: "", children: [agentSection, entrySection])
        }

        private func makeAgentMenuImage(for agent: AgentProfile) -> UIImage? {
            let prefix = "agent:\(agent.id.uuidString)::"
            let isRunning = ConversationSessionManager.shared.hasExecutingSession(withPrefix: prefix)
            return makeEmojiMenuImage(from: agent.emoji, showsRunningIndicator: isRunning)
        }

        private func makeEmojiMenuImage(from emoji: String, showsRunningIndicator: Bool) -> UIImage? {
            let trimmed = emoji.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty, !showsRunningIndicator {
                return nil
            }

            let size = CGSize(width: 20, height: 20)
            let renderer = UIGraphicsImageRenderer(size: size)
            let image = renderer.image { context in
                if !trimmed.isEmpty {
                    let paragraph = NSMutableParagraphStyle()
                    paragraph.alignment = .center

                    let attributes: [NSAttributedString.Key: Any] = [
                        .font: UIFont.systemFont(ofSize: 16),
                        .paragraphStyle: paragraph,
                    ]

                    let text = trimmed as NSString
                    let textSize = text.size(withAttributes: attributes)
                    let rect = CGRect(
                        x: (size.width - textSize.width) / 2,
                        y: (size.height - textSize.height) / 2,
                        width: textSize.width,
                        height: textSize.height
                    )
                    text.draw(in: rect, withAttributes: attributes)
                }

                if showsRunningIndicator {
                    // Draw a small green dot to indicate there is an in-flight task.
                    let dotDiameter: CGFloat = 7
                    let dotRect = CGRect(
                        x: size.width - dotDiameter - 1,
                        y: size.height - dotDiameter - 1,
                        width: dotDiameter,
                        height: dotDiameter
                    )
                    context.cgContext.setFillColor(UIColor.systemGreen.cgColor)
                    context.cgContext.fillEllipse(in: dotRect)

                    context.cgContext.setStrokeColor(UIColor.systemBackground.cgColor)
                    context.cgContext.setLineWidth(1)
                    context.cgContext.strokeEllipse(in: dotRect.insetBy(dx: 0.5, dy: 0.5))
                }
            }

            return image.withRenderingMode(.alwaysOriginal)
        }
    }
}
