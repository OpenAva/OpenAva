import ChatClient
import ChatUI
import MarkdownView
import OpenClawKit
import SwiftUI
import UIKit
import UserNotifications

private final class ContextUsagePanelOverlayController: UIViewController {
    private let snapshot: ContextUsageSnapshot
    private let modelName: String
    private let providerName: String?
    private weak var anchorView: UIView?

    private let dismissControl = UIControl()
    private let panelShadowView = UIView()
    private let panelContentView = UIView()
    private lazy var hostingController = UIHostingController(
        rootView: ChatContextUsagePanelView(
            snapshot: snapshot,
            modelName: modelName,
            providerName: providerName,
            onClose: { [weak self] in
                self?.dismiss(animated: true)
            },
            onManualCompact: onManualCompact
        )
    )
    private let onManualCompact: () -> Void

    init(
        snapshot: ContextUsageSnapshot,
        modelName: String,
        providerName: String?,
        anchorView: UIView,
        onManualCompact: @escaping () -> Void
    ) {
        self.snapshot = snapshot
        self.modelName = modelName
        self.providerName = providerName
        self.anchorView = anchorView
        self.onManualCompact = onManualCompact
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overCurrentContext
        modalTransitionStyle = .crossDissolve
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        dismissControl.backgroundColor = .clear
        dismissControl.addTarget(self, action: #selector(closePanel), for: .touchUpInside)
        dismissControl.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(dismissControl)

        panelShadowView.backgroundColor = .clear
        panelShadowView.layer.shadowColor = UIColor.black.cgColor
        panelShadowView.layer.shadowOpacity = 0.14
        panelShadowView.layer.shadowRadius = 24
        panelShadowView.layer.shadowOffset = CGSize(width: 0, height: 8)
        panelShadowView.translatesAutoresizingMaskIntoConstraints = true
        view.addSubview(panelShadowView)

        panelContentView.backgroundColor = .clear
        panelContentView.layer.cornerRadius = ChatUIDesign.Radius.card
        panelContentView.layer.cornerCurve = .continuous
        panelContentView.clipsToBounds = true
        panelContentView.translatesAutoresizingMaskIntoConstraints = false
        panelShadowView.addSubview(panelContentView)

        addChild(hostingController)
        hostingController.view.backgroundColor = .clear
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        panelContentView.addSubview(hostingController.view)
        hostingController.didMove(toParent: self)

        NSLayoutConstraint.activate([
            dismissControl.topAnchor.constraint(equalTo: view.topAnchor),
            dismissControl.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            dismissControl.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            dismissControl.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            panelContentView.topAnchor.constraint(equalTo: panelShadowView.topAnchor),
            panelContentView.leadingAnchor.constraint(equalTo: panelShadowView.leadingAnchor),
            panelContentView.trailingAnchor.constraint(equalTo: panelShadowView.trailingAnchor),
            panelContentView.bottomAnchor.constraint(equalTo: panelShadowView.bottomAnchor),
            hostingController.view.topAnchor.constraint(equalTo: panelContentView.topAnchor),
            hostingController.view.leadingAnchor.constraint(equalTo: panelContentView.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: panelContentView.trailingAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: panelContentView.bottomAnchor),
        ])
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        let horizontalInset: CGFloat = 16
        let verticalSpacing: CGFloat = 12
        let safeTop = view.safeAreaInsets.top + 8
        let safeBottom = view.safeAreaInsets.bottom + 8
        let maxWidth = max(280, view.bounds.width - horizontalInset * 2)
        let width = min(380, maxWidth)
        let maxHeight = max(240, view.bounds.height - safeTop - safeBottom)

        let anchorRect: CGRect
        if let anchorView {
            anchorRect = anchorView.convert(anchorView.bounds, to: view)
        } else {
            anchorRect = CGRect(
                x: (view.bounds.width - width) / 2,
                y: view.bounds.height - safeBottom - 44,
                width: width,
                height: 44
            )
        }

        let availableAbove = max(240, anchorRect.minY - safeTop - verticalSpacing)
        let height = min(440, min(maxHeight, availableAbove))
        let x = min(max(anchorRect.midX - width / 2, horizontalInset), view.bounds.width - horizontalInset - width)
        let y = max(safeTop, anchorRect.minY - height - verticalSpacing)

        panelShadowView.frame = CGRect(x: x, y: y, width: width, height: height)
        panelShadowView.layer.shadowPath = UIBezierPath(
            roundedRect: panelShadowView.bounds,
            cornerRadius: panelContentView.layer.cornerRadius
        ).cgPath
    }

    @objc private func closePanel() {
        dismiss(animated: true)
    }
}

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
                guard let command = CatalystGlobalCommandCenter.resolve(notification) else { return }
                Task { @MainActor [weak self] in
                    self?.handleGlobalCommand(command)
                }
            }
        }

        isolated deinit {
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

        private func handleGlobalCommand(_ command: CatalystGlobalCommand) {
            switch command {
            case .openModelSettings:
                handleOpenModelSettingsShortcut()
            case .focusInput:
                handleFocusInputShortcut()
            }
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
    private enum QuickCommand {
        static let compact = "/compact"
        static let context = "/context"
    }

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
    let agents: [AgentProfile]
    let activeAgentID: UUID?
    let activeAgentName: String
    let activeAgentEmoji: String
    let selectedModelName: String
    let selectedProviderName: String
    /// Non-nil when an App Intent wants to auto-send a message through the real agentic loop.
    /// `pendingAutoSendID` is a unique token so the coordinator never submits the same request twice.
    let pendingAutoSendID: String?
    let pendingAutoSendMessage: String?
    /// Forces `updateUIViewController` after menu data changes so menus pull fresh data.
    let menuRefreshToken: Int
    let onConsumePendingAutoSend: ((String) -> Void)?
    let onMenuAction: ((MenuAction) -> Void)?
    let onAgentSwitch: ((UUID) -> Void)?
    let onModelSwitch: ((UUID) -> Void)?
    let onCreateLocalAgent: (() -> Void)?
    let onDeleteCurrentAgent: (() -> Void)?
    let onRenameCurrentAgent: ((String) -> Bool)?
    let modelConfig: AppConfig.LLMModel?
    let autoCompactEnabled: Bool
    let showsSystemTopBar: Bool
    let onToggleAutoCompact: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onMenuAction: onMenuAction,
            agents: agents,
            activeAgentID: activeAgentID,
            activeAgentName: activeAgentName,
            activeAgentEmoji: activeAgentEmoji,
            selectedModelName: selectedModelName,
            selectedProviderName: selectedProviderName,
            autoCompactEnabled: autoCompactEnabled,
            onAgentSwitch: onAgentSwitch,
            onModelSwitch: onModelSwitch,
            onCreateLocalAgent: onCreateLocalAgent,
            onDeleteCurrentAgent: onDeleteCurrentAgent,
            onRenameCurrentAgent: onRenameCurrentAgent,
            onToggleAutoCompact: onToggleAutoCompact
        )
    }

    private func resolveSessionContext(agentCount: Int) -> (
        sessionConfiguration: ConversationSession.Configuration,
        models: ConversationSession.Models,
        providedSession: ConversationSession?,
        serializedExecutionContext: (agent: AgentProfile, modelConfig: AppConfig.LLMModel, invocationSessionID: String)?
    ) {
        let storageProvider: any StorageProvider
        let sessionDelegate: SessionDelegate?
        let providedSession: ConversationSession?
        let models: ConversationSession.Models
        var serializedExecutionContext: (agent: AgentProfile, modelConfig: AppConfig.LLMModel, invocationSessionID: String)?

        if let runtimeRootURL, activeAgentID != nil {
            if let agent = agents.first(where: { $0.id == activeAgentID }), let modelConfig {
                let invocationSessionID = "\(activeAgentID!.uuidString)::\(sessionID)"
                let resources = AgentMainSessionRegistry.shared.sessionResources(
                    for: agent,
                    modelConfig: modelConfig,
                    invocationSessionID: invocationSessionID,
                    agentCount: agentCount
                )
                storageProvider = resources.storageProvider
                sessionDelegate = resources.sessionDelegate
                providedSession = resources.session
                models = resources.session.models
                serializedExecutionContext = (agent, modelConfig, invocationSessionID)
            } else {
                storageProvider = TranscriptStorageProvider.provider(runtimeRootURL: runtimeRootURL)
                sessionDelegate = AgentSessionDelegate(
                    sessionID: sessionID,
                    runtimeRootURL: runtimeRootURL,
                    chatClient: chatClient,
                    agentName: activeAgentName,
                    agentEmoji: activeAgentEmoji
                )
                var fallbackModels = ConversationSession.Models()
                if let chatClient {
                    fallbackModels.chat = ConversationSession.Model(
                        client: chatClient,
                        capabilities: [.visual, .tool],
                        contextLength: modelConfig?.contextTokens ?? 128_000,
                        maxOutputTokens: modelConfig?.resolvedMaxOutputTokens ?? 20000,
                        autoCompactEnabled: autoCompactEnabled
                    )
                }
                providedSession = nil
                models = fallbackModels
            }
        } else {
            storageProvider = DisposableStorageProvider.shared
            sessionDelegate = nil
            providedSession = nil
            models = .init()
        }

        let sessionConfiguration = ConversationSession.Configuration(
            storage: storageProvider,
            tools: toolProvider,
            delegate: sessionDelegate,
            systemPromptProvider: {
                AgentContextLoader.composeSystemPrompt(
                    baseSystemPrompt: systemPrompt,
                    workspaceRootURL: workspaceRootURL,
                    agentCount: agentCount
                ) ?? systemPrompt ?? "You are a helpful assistant."
            },
            collapseReasoningWhenComplete: true
        )

        return (sessionConfiguration, models, providedSession, serializedExecutionContext)
    }

    func makeUIViewController(context: Context) -> UIViewController {
        let agentCount = max(agents.count, 1)
        let sessionContext = resolveSessionContext(agentCount: agentCount)

        // Create and configure ChatViewController
        let inputConfiguration = ChatInputConfiguration(
            quickSettingItems: buildQuickSettingItems()
        )
        let viewConfiguration = ChatViewController.Configuration(
            input: inputConfiguration,
            messageTheme: .default
        )
        let chatViewController: ChatViewController

        #if targetEnvironment(macCatalyst)
            let catalystController: CatalystChatViewController
            if let providedSession = sessionContext.providedSession {
                catalystController = CatalystChatViewController(
                    session: providedSession,
                    sessionID: sessionID,
                    models: sessionContext.models,
                    sessionConfiguration: sessionContext.sessionConfiguration,
                    configuration: viewConfiguration
                )
            } else {
                catalystController = CatalystChatViewController(
                    sessionID: sessionID,
                    models: sessionContext.models,
                    sessionConfiguration: sessionContext.sessionConfiguration,
                    configuration: viewConfiguration
                )
            }
            catalystController.onOpenModelSettings = { [weak coordinator = context.coordinator] in
                coordinator?.onMenuAction?(.openLLM)
            }
            chatViewController = catalystController
        #else
            if let providedSession = sessionContext.providedSession {
                chatViewController = ChatViewController(
                    session: providedSession,
                    sessionID: sessionID,
                    models: sessionContext.models,
                    sessionConfiguration: sessionContext.sessionConfiguration,
                    configuration: viewConfiguration
                )
            } else {
                chatViewController = ChatViewController(
                    sessionID: sessionID,
                    models: sessionContext.models,
                    sessionConfiguration: sessionContext.sessionConfiguration,
                    configuration: viewConfiguration
                )
            }
        #endif

        // Persist input draft per agent so it survives app restarts and is isolated between agents.
        if let agentID = activeAgentID {
            chatViewController.draftPersistenceKey = agentID.uuidString
        }

        chatViewController.definesPresentationContext = true
        chatViewController.showsSystemTopBar = showsSystemTopBar
        // Route top-right menu interactions back to SwiftUI.
        chatViewController.menuDelegate = context.coordinator
        context.coordinator.chatViewController = chatViewController
        if let serializedExecutionContext = sessionContext.serializedExecutionContext {
            chatViewController.promptSubmissionHandler = { _, _, prompt in
                do {
                    return try await AgentMainSessionRegistry.shared.submitToMainSession(
                        for: serializedExecutionContext.agent,
                        modelConfig: serializedExecutionContext.modelConfig,
                        invocationSessionID: serializedExecutionContext.invocationSessionID,
                        agentCount: agentCount
                    ) { resources in
                        guard let model = resources.session.models.chat else {
                            return false
                        }
                        return resources.session.submitPromptWithoutWaiting(
                            model: model,
                            prompt: prompt,
                            usingExistingReservation: true
                        )
                    }
                } catch {
                    return false
                }
            }
        } else {
            chatViewController.promptSubmissionHandler = nil
        }
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
            .command(id: "context-usage", title: L10n.tr("chat.contextUsage.badgePlaceholder"), icon: "gauge", command: QuickCommand.context),
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

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        let chatViewController = uiViewController as! ChatViewController

        // Keep callbacks and data updated when SwiftUI state changes.
        context.coordinator.onMenuAction = onMenuAction
        context.coordinator.agents = agents
        context.coordinator.activeAgentID = activeAgentID
        context.coordinator.activeAgentName = activeAgentName
        context.coordinator.activeAgentEmoji = activeAgentEmoji
        context.coordinator.selectedModelName = selectedModelName
        context.coordinator.selectedProviderName = selectedProviderName
        context.coordinator.onModelSwitch = onModelSwitch

        let agentCount = max(agents.count, 1)
        let sessionContext = resolveSessionContext(agentCount: agentCount)
        chatViewController.updateConversationRuntime(
            sessionID: sessionID,
            providedSession: sessionContext.providedSession,
            models: sessionContext.models,
            sessionConfiguration: sessionContext.sessionConfiguration
        )
        if let agentID = activeAgentID {
            chatViewController.draftPersistenceKey = agentID.uuidString
        } else {
            chatViewController.draftPersistenceKey = nil
        }
        if let serializedExecutionContext = sessionContext.serializedExecutionContext {
            chatViewController.promptSubmissionHandler = { _, _, prompt in
                do {
                    return try await AgentMainSessionRegistry.shared.submitToMainSession(
                        for: serializedExecutionContext.agent,
                        modelConfig: serializedExecutionContext.modelConfig,
                        invocationSessionID: serializedExecutionContext.invocationSessionID,
                        agentCount: agentCount
                    ) { resources in
                        guard let model = resources.session.models.chat else {
                            return false
                        }
                        return resources.session.submitPromptWithoutWaiting(
                            model: model,
                            prompt: prompt,
                            usingExistingReservation: true
                        )
                    }
                } catch {
                    return false
                }
            }
        } else {
            chatViewController.promptSubmissionHandler = nil
        }

        // Auto-send on behalf of the intent if this is a new request.
        if let id = pendingAutoSendID,
           let message = pendingAutoSendMessage,
           id != context.coordinator.processedAutoSendID
        {
            context.coordinator.processedAutoSendID = id
            // Use the same submission path as manual user input.
            let content = ChatInputContent(text: message)
            chatViewController.chatInputDidSubmit(chatViewController.chatInputView, object: content) { _ in }
            onConsumePendingAutoSend?(id)
        }

        context.coordinator.onAgentSwitch = onAgentSwitch
        context.coordinator.onModelSwitch = onModelSwitch
        context.coordinator.onCreateLocalAgent = onCreateLocalAgent
        context.coordinator.onDeleteCurrentAgent = onDeleteCurrentAgent
        context.coordinator.onRenameCurrentAgent = onRenameCurrentAgent
        context.coordinator.autoCompactEnabled = autoCompactEnabled
        context.coordinator.onToggleAutoCompact = onToggleAutoCompact
        context.coordinator.chatViewController = chatViewController
        chatViewController.menuDelegate = context.coordinator
        chatViewController.showsSystemTopBar = showsSystemTopBar
        chatViewController.refreshNavigationMenus()
        chatViewController.updateAutoCompactEnabled(autoCompactEnabled)

        #if targetEnvironment(macCatalyst)
            if let catalystController = chatViewController as? CatalystChatViewController {
                catalystController.onOpenModelSettings = { [weak coordinator = context.coordinator] in
                    coordinator?.onMenuAction?(.openLLM)
                }
            }
        #endif

        chatViewController.updateHeader(.init(
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
        var agents: [AgentProfile]
        var activeAgentID: UUID?
        var activeAgentName: String
        var activeAgentEmoji: String
        var selectedModelName: String
        var selectedProviderName: String
        var onAgentSwitch: ((UUID) -> Void)?
        var onModelSwitch: ((UUID) -> Void)?
        var onCreateLocalAgent: (() -> Void)?
        var onDeleteCurrentAgent: (() -> Void)?
        var onRenameCurrentAgent: ((String) -> Bool)?
        var autoCompactEnabled: Bool
        var onToggleAutoCompact: (() -> Void)?
        weak var chatViewController: ChatViewController?

        init(
            onMenuAction: ((MenuAction) -> Void)?,
            agents: [AgentProfile],
            activeAgentID: UUID?,
            activeAgentName: String,
            activeAgentEmoji: String,
            selectedModelName: String,
            selectedProviderName: String,
            autoCompactEnabled: Bool,
            onAgentSwitch: ((UUID) -> Void)?,
            onModelSwitch: ((UUID) -> Void)?,
            onCreateLocalAgent: (() -> Void)?,
            onDeleteCurrentAgent: (() -> Void)?,
            onRenameCurrentAgent: ((String) -> Bool)?,
            onToggleAutoCompact: (() -> Void)?
        ) {
            self.onMenuAction = onMenuAction
            self.agents = agents
            self.activeAgentID = activeAgentID
            self.activeAgentName = activeAgentName
            self.activeAgentEmoji = activeAgentEmoji
            self.selectedModelName = selectedModelName
            self.selectedProviderName = selectedProviderName
            self.autoCompactEnabled = autoCompactEnabled
            self.onAgentSwitch = onAgentSwitch
            self.onModelSwitch = onModelSwitch
            self.onCreateLocalAgent = onCreateLocalAgent
            self.onDeleteCurrentAgent = onDeleteCurrentAgent
            self.onRenameCurrentAgent = onRenameCurrentAgent
            self.onToggleAutoCompact = onToggleAutoCompact
            super.init()
        }

        func chatViewControllerModelMenu(_: ChatViewController) -> UIMenu? {
            let collection = LLMConfigStore.loadCollection()
            let models = collection.models

            var actions: [UIMenuElement] = []

            for model in models {
                let isSelected = model.name == self.selectedModelName
                let action = UIAction(title: model.name, state: isSelected ? .on : .off) { [weak self] _ in
                    self?.onModelSwitch?(model.id)
                }
                actions.append(action)
            }

            if actions.isEmpty {
                let emptyAction = UIAction(title: L10n.tr("settings.llmList.empty.title"), attributes: .disabled) { _ in }
                actions.append(emptyAction)
            }

            let addModelAction = UIAction(title: L10n.tr("settings.llmList.addModel"), image: UIImage(systemName: "plus")) { [weak self] _ in
                self?.onMenuAction?(.openLLM)
            }

            let section1 = UIMenu(options: .displayInline, children: actions)
            let section2 = UIMenu(options: .displayInline, children: [addModelAction])

            return UIMenu(children: [section1, section2])
        }

        func chatViewControllerMenu(_ controller: ChatViewController) -> UIMenu? {
            let sections = ChatTopBar.configurationSections(
                autoCompactEnabled: autoCompactEnabled,
                isBackgroundEnabled: BackgroundExecutionPreferences.shared.isEnabled,
                includeBackgroundExecution: true
            )
            let menus = sections.map { section in
                UIMenu(
                    title: "",
                    options: .displayInline,
                    children: section.items.compactMap { item in
                        self.makeConfigurationMenuElement(item, controller: controller)
                    }
                )
            }
            return UIMenu(children: menus)
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
            let image = makeActiveAgentButtonImage() ?? UIImage(systemName: ChatTopBar.leadingMenuSystemImage)
            if #available(iOS 15.0, *) {
                var configuration = button.configuration ?? .plain()
                configuration.image = image
                configuration.contentInsets = .zero
                configuration.imagePadding = 0
                button.configuration = configuration
            } else {
                button.setImage(image, for: .normal)
                button.imageEdgeInsets = .zero
            }
            button.tintColor = UIColor.label.withAlphaComponent(0.9)
            button.imageView?.contentMode = .scaleAspectFit
            button.contentHorizontalAlignment = .left
            button.contentVerticalAlignment = .center
            button.showsMenuAsPrimaryAction = true
            button.menu = buildAgentMenu()
        }

        func chatViewControllerDidTapModelTitle(_ controller: ChatViewController) {
            _ = controller
            onMenuAction?(.openContext)
        }

        func chatViewControllerHandleCommand(_ controller: ChatViewController, command: String) -> Bool {
            switch command {
            case "/heartbeat":
                onMenuAction?(.runHeartbeatNow)
                return true
            case QuickCommand.compact:
                Task { @MainActor [weak self, weak controller] in
                    guard let self, let controller else { return }
                    do {
                        try await controller.performManualCompact()
                    } catch {
                        self.presentCommandErrorAlert(
                            from: controller,
                            message: error.localizedDescription
                        )
                    }
                }
                return true
            case QuickCommand.context:
                Task { @MainActor [weak self, weak controller] in
                    guard let self, let controller else { return }
                    await self.presentContextUsagePanel(from: controller)
                }
                return true
            default:
                return false
            }
        }

        @MainActor
        private func presentCommandErrorAlert(from controller: ChatViewController, message: String) {
            let alert = UIAlertController(
                title: L10n.tr("common.error"),
                message: message,
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: L10n.tr("common.ok"), style: .default))
            controller.present(alert, animated: true)
        }

        @MainActor
        private func presentContextUsagePanel(from controller: ChatViewController) async {
            guard let snapshot = await controller.currentContextUsageSnapshot() else {
                presentCommandErrorAlert(from: controller, message: L10n.tr("chat.contextUsage.unavailable"))
                return
            }

            if let presentedController = controller.presentedViewController as? ContextUsagePanelOverlayController {
                presentedController.dismiss(animated: true)
                return
            }

            let model = selectedModelName.trimmingCharacters(in: .whitespacesAndNewlines)
            let provider = selectedProviderName.trimmingCharacters(in: .whitespacesAndNewlines)
            let anchorView: UIView = controller.quickSettingAnchorView(forCommand: QuickCommand.context) ?? controller.view
            let overlayController = ContextUsagePanelOverlayController(
                snapshot: snapshot,
                modelName: model,
                providerName: provider.isEmpty ? nil : provider,
                anchorView: anchorView,
                onManualCompact: { [weak self, weak controller] in
                    guard let self, let controller else { return }
                    Task { @MainActor in
                        (controller.presentedViewController as? ContextUsagePanelOverlayController)?
                            .dismiss(animated: true)
                        do {
                            try await controller.performManualCompact()
                            await self.presentContextUsagePanel(from: controller)
                        } catch {
                            self.presentCommandErrorAlert(
                                from: controller,
                                message: error.localizedDescription
                            )
                        }
                    }
                }
            )
            controller.present(overlayController, animated: true)
        }

        private func buildAgentMenu() -> UIMenu {
            let entries = ChatTopBar.agentMenuEntries(agents: agents, activeAgentID: activeAgentID)
            var primaryChildren: [UIMenuElement] = []
            var secondaryChildren: [UIMenuElement] = []

            for entry in entries {
                guard let element = makeAgentMenuElement(for: entry) else { continue }
                switch entry.kind {
                case .createLocalAgent:
                    secondaryChildren.append(element)
                case .agent, .empty:
                    primaryChildren.append(element)
                }
            }

            var sections: [UIMenu] = []
            if !primaryChildren.isEmpty {
                sections.append(UIMenu(title: "", options: .displayInline, children: primaryChildren))
            }
            if !secondaryChildren.isEmpty {
                sections.append(UIMenu(title: "", options: .displayInline, children: secondaryChildren))
            }
            return UIMenu(title: "", children: sections)
        }

        private func makeAgentMenuElement(for entry: ChatTopBar.AgentMenuEntry) -> UIMenuElement? {
            switch entry.kind {
            case let .agent(agentID):
                let image = makeAgentMenuImage(for: agentID, fallbackEmoji: entry.emoji)
                let state: UIMenuElement.State = entry.isSelected ? .on : .off
                return UIAction(
                    title: entry.title,
                    image: image,
                    identifier: nil,
                    discoverabilityTitle: nil,
                    attributes: [],
                    state: state
                ) { [weak self] _ in
                    self?.onAgentSwitch?(agentID)
                }
            case .createLocalAgent:
                return UIAction(
                    title: entry.title,
                    image: standardizedMenuIcon(UIImage.chatInputIcon(named: "user.plus"))
                ) { [weak self] _ in
                    self?.onCreateLocalAgent?()
                }
            case .empty:
                return UIAction(title: entry.title, attributes: [.disabled]) { _ in }
            }
        }

        private func makeConfigurationMenuElement(
            _ item: ChatTopBar.ConfigurationItem,
            controller: ChatViewController
        ) -> UIMenuElement? {
            switch item.kind {
            case let .destination(destination):
                return UIAction(
                    title: item.title,
                    image: UIImage(systemName: item.systemImage)
                ) { [weak self] _ in
                    self?.onMenuAction?(self?.menuAction(for: destination) ?? .openLLM)
                }
            case let .backgroundExecution(enabled):
                return UIAction(
                    title: item.title,
                    image: UIImage(systemName: item.systemImage),
                    state: enabled ? .on : .off
                ) { _ in
                    let preferences = BackgroundExecutionPreferences.shared
                    preferences.isEnabled.toggle()
                    if preferences.isEnabled {
                        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
                    }
                }
            case let .autoCompact(enabled):
                return UIAction(
                    title: item.title,
                    image: UIImage(systemName: item.systemImage),
                    state: enabled ? .on : .off
                ) { [weak self] _ in
                    self?.onToggleAutoCompact?()
                }
            case .renameAgent:
                return UIAction(
                    title: item.title,
                    image: UIImage(systemName: item.systemImage)
                ) { [weak self, weak controller] _ in
                    guard let self, let controller else { return }
                    self.presentRenameCurrentAgentAlert(from: controller)
                }
            case .deleteAgent:
                return UIAction(
                    title: item.title,
                    image: UIImage(systemName: item.systemImage),
                    attributes: item.isDestructive ? [.destructive] : []
                ) { [weak self, weak controller] _ in
                    guard let self, let controller else { return }
                    self.presentDeleteCurrentAgentAlert(from: controller)
                }
            }
        }

        private func menuAction(for destination: ChatTopBar.Destination) -> MenuAction {
            switch destination {
            case .llm:
                .openLLM
            case .skills:
                .openSkills
            case .context:
                .openContext
            case .cron:
                .openCron
            case .remoteControl:
                .openRemoteControl
            }
        }

        private func standardizedMenuIcon(
            _ image: UIImage?,
            canvasSize: CGSize = CGSize(width: 20, height: 20),
            targetSize: CGSize = CGSize(width: 15, height: 15)
        ) -> UIImage? {
            guard let image else { return nil }
            let renderer = UIGraphicsImageRenderer(size: canvasSize)
            let rendered = renderer.image { _ in
                let drawRect = aspectFitRect(contentSize: image.size, in: CGRect(origin: .zero, size: targetSize))
                    .offsetBy(
                        dx: (canvasSize.width - targetSize.width) / 2,
                        dy: (canvasSize.height - targetSize.height) / 2
                    )
                image.draw(in: drawRect)
            }
            return rendered.withRenderingMode(image.renderingMode)
        }

        private func aspectFitRect(contentSize: CGSize, in bounds: CGRect) -> CGRect {
            guard contentSize.width > 0, contentSize.height > 0 else { return bounds }
            let scale = min(bounds.width / contentSize.width, bounds.height / contentSize.height)
            let fittedSize = CGSize(width: contentSize.width * scale, height: contentSize.height * scale)
            return CGRect(
                x: bounds.minX + (bounds.width - fittedSize.width) / 2,
                y: bounds.minY + (bounds.height - fittedSize.height) / 2,
                width: fittedSize.width,
                height: fittedSize.height
            )
        }

        private func loadAgentAvatarImage(for profile: AgentProfile) -> UIImage? {
            guard let data = try? Data(contentsOf: profile.avatarURL), let image = UIImage(data: data) else {
                return nil
            }
            return image
        }

        private func makeActiveAgentButtonImage() -> UIImage? {
            guard let activeAgentID,
                  let profile = agents.first(where: { $0.id == activeAgentID }),
                  let avatarImage = loadAgentAvatarImage(for: profile)
            else {
                return nil
            }

            let canvasSize = CGSize(width: 24, height: 24)
            let renderer = UIGraphicsImageRenderer(size: canvasSize)
            return renderer.image { _ in
                let rect = CGRect(origin: .zero, size: canvasSize)
                UIBezierPath(ovalIn: rect).addClip()
                avatarImage.draw(in: rect)
            }.withRenderingMode(.alwaysOriginal)
        }

        private func makeAvatarMenuImage(for profile: AgentProfile, showsRunningIndicator: Bool) -> UIImage? {
            guard let avatarImage = loadAgentAvatarImage(for: profile) else {
                return nil
            }

            let size = CGSize(width: 17, height: 17)
            let renderer = UIGraphicsImageRenderer(size: size)
            let image = renderer.image { context in
                let rect = CGRect(origin: .zero, size: size)
                UIBezierPath(roundedRect: rect, cornerRadius: 4).addClip()
                avatarImage.draw(in: rect)

                if showsRunningIndicator {
                    let dotDiameter: CGFloat = 5.5
                    let dotRect = CGRect(
                        x: size.width - dotDiameter - 1,
                        y: size.height - dotDiameter - 1,
                        width: dotDiameter,
                        height: dotDiameter
                    )
                    context.cgContext.setFillColor(UIColor.systemGreen.cgColor)
                    context.cgContext.fillEllipse(in: dotRect)

                    context.cgContext.setStrokeColor(ChatUIDesign.Color.warmCream.cgColor)
                    context.cgContext.setLineWidth(1)
                    context.cgContext.strokeEllipse(in: dotRect.insetBy(dx: 0.5, dy: 0.5))
                }
            }

            return image.withRenderingMode(.alwaysOriginal)
        }

        private func makeAgentMenuImage(for agentID: UUID, fallbackEmoji: String) -> UIImage? {
            let prefix = "agent:\(agentID.uuidString)::"
            let isRunning = ConversationSessionManager.shared.hasActiveQuery(withPrefix: prefix)
            if let profile = agents.first(where: { $0.id == agentID }),
               let avatarImage = makeAvatarMenuImage(for: profile, showsRunningIndicator: isRunning)
            {
                return avatarImage
            }
            return makeEmojiMenuImage(from: fallbackEmoji, showsRunningIndicator: isRunning)
        }

        private func makeEmojiMenuImage(from emoji: String, showsRunningIndicator: Bool) -> UIImage? {
            let trimmed = emoji.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty, !showsRunningIndicator {
                return nil
            }

            let size = CGSize(width: 17, height: 17)
            let renderer = UIGraphicsImageRenderer(size: size)
            let image = renderer.image { context in
                if !trimmed.isEmpty {
                    let paragraph = NSMutableParagraphStyle()
                    paragraph.alignment = .center

                    let attributes: [NSAttributedString.Key: Any] = [
                        .font: UIFont.systemFont(ofSize: 14),
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
                    let dotDiameter: CGFloat = 5.5
                    let dotRect = CGRect(
                        x: size.width - dotDiameter - 1,
                        y: size.height - dotDiameter - 1,
                        width: dotDiameter,
                        height: dotDiameter
                    )
                    context.cgContext.setFillColor(UIColor.systemGreen.cgColor)
                    context.cgContext.fillEllipse(in: dotRect)

                    context.cgContext.setStrokeColor(ChatUIDesign.Color.warmCream.cgColor)
                    context.cgContext.setLineWidth(1)
                    context.cgContext.strokeEllipse(in: dotRect.insetBy(dx: 0.5, dy: 0.5))
                }
            }

            return image.withRenderingMode(.alwaysOriginal)
        }
    }
}
