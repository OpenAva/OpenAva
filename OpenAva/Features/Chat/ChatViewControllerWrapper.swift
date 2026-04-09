import ChatClient
import ChatUI
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
        let height = min(520, min(maxHeight, availableAbove))
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
    let teams: [TeamProfile]
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
    let onMenuAction: ((MenuAction) -> Void)?
    let onAgentSwitch: ((UUID) -> Void)?
    let onCreateLocalAgent: (() -> Void)?
    let onCreateLocalTeam: (() -> Void)?
    let onDeleteCurrentAgent: (() -> Void)?
    let onRenameCurrentAgent: ((String) -> Bool)?
    let onAddAgentToTeam: ((UUID) -> Void)?
    let onCreateAgentForTeam: ((UUID) -> Void)?
    let onDeleteTeam: ((UUID) -> Void)?
    let modelConfig: AppConfig.LLMModel?
    let autoCompactEnabled: Bool
    let onToggleAutoCompact: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onMenuAction: onMenuAction,
            teams: teams,
            agents: agents,
            activeAgentID: activeAgentID,
            activeAgentName: activeAgentName,
            activeAgentEmoji: activeAgentEmoji,
            selectedModelName: selectedModelName,
            selectedProviderName: selectedProviderName,
            autoCompactEnabled: autoCompactEnabled,
            onAgentSwitch: onAgentSwitch,
            onCreateLocalAgent: onCreateLocalAgent,
            onCreateLocalTeam: onCreateLocalTeam,
            onDeleteCurrentAgent: onDeleteCurrentAgent,
            onRenameCurrentAgent: onRenameCurrentAgent,
            onAddAgentToTeam: onAddAgentToTeam,
            onCreateAgentForTeam: onCreateAgentForTeam,
            onDeleteTeam: onDeleteTeam,
            onToggleAutoCompact: onToggleAutoCompact
        )
    }

    func makeUIViewController(context: Context) -> ChatViewController {
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
        let viewConfiguration = ChatViewController.Configuration(input: inputConfiguration)
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

        // Persist input draft per agent so it survives app restarts and is isolated between agents.
        if let agentID = activeAgentID {
            chatViewController.draftPersistenceKey = agentID.uuidString
        }

        // Configure for navigation bar integration
        chatViewController.prefersNavigationBarManaged = false
        chatViewController.definesPresentationContext = true
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
            .command(id: "context-usage", title: L10n.tr("chat.contextUsage.badgePlaceholder"), icon: "gauge", command: QuickCommand.context),
            .command(id: "run-heartbeat", title: L10n.tr("chat.command.runHeartbeatNow"), icon: "heartbeat", command: "/heartbeat"),
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
        context.coordinator.teams = teams
        context.coordinator.agents = agents
        context.coordinator.activeAgentID = activeAgentID
        context.coordinator.activeAgentName = activeAgentName
        context.coordinator.activeAgentEmoji = activeAgentEmoji
        context.coordinator.selectedModelName = selectedModelName
        context.coordinator.selectedProviderName = selectedProviderName

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

        context.coordinator.onAgentSwitch = onAgentSwitch
        context.coordinator.onCreateLocalAgent = onCreateLocalAgent
        context.coordinator.onCreateLocalTeam = onCreateLocalTeam
        context.coordinator.onDeleteCurrentAgent = onDeleteCurrentAgent
        context.coordinator.onRenameCurrentAgent = onRenameCurrentAgent
        context.coordinator.onAddAgentToTeam = onAddAgentToTeam
        context.coordinator.onCreateAgentForTeam = onCreateAgentForTeam
        context.coordinator.onDeleteTeam = onDeleteTeam
        context.coordinator.autoCompactEnabled = autoCompactEnabled
        context.coordinator.onToggleAutoCompact = onToggleAutoCompact
        context.coordinator.refreshLeadingMenu()
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
        var teams: [TeamProfile]
        var agents: [AgentProfile]
        var activeAgentID: UUID?
        var activeAgentName: String
        var activeAgentEmoji: String
        var selectedModelName: String
        var selectedProviderName: String
        var onAgentSwitch: ((UUID) -> Void)?
        var onCreateLocalAgent: (() -> Void)?
        var onCreateLocalTeam: (() -> Void)?
        var onDeleteCurrentAgent: (() -> Void)?
        var onRenameCurrentAgent: ((String) -> Bool)?
        var onAddAgentToTeam: ((UUID) -> Void)?
        var onCreateAgentForTeam: ((UUID) -> Void)?
        var onDeleteTeam: ((UUID) -> Void)?
        var autoCompactEnabled: Bool
        var onToggleAutoCompact: (() -> Void)?
        weak var leadingMenuButton: UIButton?
        private var swarmObserver: NSObjectProtocol?

        init(
            onMenuAction: ((MenuAction) -> Void)?,
            teams: [TeamProfile],
            agents: [AgentProfile],
            activeAgentID: UUID?,
            activeAgentName: String,
            activeAgentEmoji: String,
            selectedModelName: String,
            selectedProviderName: String,
            autoCompactEnabled: Bool,
            onAgentSwitch: ((UUID) -> Void)?,
            onCreateLocalAgent: (() -> Void)?,
            onCreateLocalTeam: (() -> Void)?,
            onDeleteCurrentAgent: (() -> Void)?,
            onRenameCurrentAgent: ((String) -> Bool)?,
            onAddAgentToTeam: ((UUID) -> Void)?,
            onCreateAgentForTeam: ((UUID) -> Void)?,
            onDeleteTeam: ((UUID) -> Void)?,
            onToggleAutoCompact: (() -> Void)?
        ) {
            self.onMenuAction = onMenuAction
            self.teams = teams
            self.agents = agents
            self.activeAgentID = activeAgentID
            self.activeAgentName = activeAgentName
            self.activeAgentEmoji = activeAgentEmoji
            self.selectedModelName = selectedModelName
            self.selectedProviderName = selectedProviderName
            self.autoCompactEnabled = autoCompactEnabled
            self.onAgentSwitch = onAgentSwitch
            self.onCreateLocalAgent = onCreateLocalAgent
            self.onCreateLocalTeam = onCreateLocalTeam
            self.onDeleteCurrentAgent = onDeleteCurrentAgent
            self.onRenameCurrentAgent = onRenameCurrentAgent
            self.onAddAgentToTeam = onAddAgentToTeam
            self.onCreateAgentForTeam = onCreateAgentForTeam
            self.onDeleteTeam = onDeleteTeam
            self.onToggleAutoCompact = onToggleAutoCompact
            super.init()
            swarmObserver = NotificationCenter.default.addObserver(
                forName: .openAvaTeamSwarmDidChange,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.refreshLeadingMenu()
            }
        }

        deinit {
            if let swarmObserver {
                NotificationCenter.default.removeObserver(swarmObserver)
            }
        }

        func refreshLeadingMenu() {
            leadingMenuButton?.menu = buildAgentMenu()
        }

        func chatViewControllerMenu(_ controller: ChatViewController) -> UIMenu? {
            let renameTitle = L10n.tr("chat.menu.renameAgent")
            let deleteTitle = L10n.tr("chat.menu.deleteAgent")

            // Keep stable order: chat configuration first, then chat controls and agent management.
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
                ]
            )
            let agentManagementMenu = UIMenu(
                title: "",
                options: .displayInline,
                children: [backgroundAction, autoCompactAction, remoteControlAction, renameAction, deleteAction]
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
            let image = standardizedMenuIcon(
                UIImage.chatInputIcon(named: "users"),
                canvasSize: CGSize(width: 20, height: 20),
                targetSize: CGSize(width: 17, height: 17)
            )
            if #available(iOS 15.0, *) {
                var configuration = button.configuration ?? .plain()
                configuration.image = image
                configuration.contentInsets = NSDirectionalEdgeInsets(top: 1, leading: 1, bottom: 1, trailing: 1)
                configuration.imagePadding = 0
                button.configuration = configuration
            } else {
                button.setImage(image, for: .normal)
                button.imageEdgeInsets = UIEdgeInsets(top: 1, left: 1, bottom: 1, right: 1)
            }
            button.tintColor = UIColor.label.withAlphaComponent(0.9)
            button.imageView?.contentMode = .scaleAspectFit
            button.contentHorizontalAlignment = .center
            button.contentVerticalAlignment = .center
            button.showsMenuAsPrimaryAction = true
            leadingMenuButton = button
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
            let groupedAgentIDs = Set(teams.flatMap(\.agentPoolIDs))
            let teamMenus = teams
                .sorted(by: compareTeams)
                .map(buildTeamSubmenu)

            let ungroupedActions = agents
                .filter { !groupedAgentIDs.contains($0.id) }
                .map(makeAgentAction)

            let fallbackMenu: UIMenu? = if teamMenus.isEmpty, ungroupedActions.isEmpty {
                UIMenu(
                    title: "",
                    options: .displayInline,
                    children: [UIAction(title: L10n.tr("chat.menu.noAgentsAvailable"), attributes: [.disabled]) { _ in }]
                )
            } else {
                nil
            }

            let createLocalAction = UIAction(
                title: L10n.tr("chat.menu.newLocalAgent"),
                image: standardizedMenuIcon(UIImage.chatInputIcon(named: "user.plus"))
            ) { [weak self] _ in
                self?.onCreateLocalAgent?()
            }
            let newTeamAction = UIAction(
                title: L10n.tr("chat.menu.newTeam"),
                image: standardizedMenuIcon(UIImage.chatInputIcon(named: "users"))
            ) { [weak self] _ in
                self?.onCreateLocalTeam?()
            }

            let contentChildren = teamMenus + ungroupedActions + [fallbackMenu].compactMap { $0 }
            let contentSection = UIMenu(title: "", options: .displayInline, children: contentChildren)
            let entrySection = UIMenu(title: "", options: .displayInline, children: [createLocalAction, newTeamAction])
            return UIMenu(title: "", children: [contentSection, entrySection])
        }

        private func buildTeamSubmenu(for team: TeamProfile) -> UIMenu {
            let snapshot = TeamSwarmCoordinator.shared.menuSnapshot(teamName: team.name)

            let memberActions = team.agentPoolIDs.compactMap { agentID in
                agents.first(where: { $0.id == agentID }).map { makeAgentAction(for: $0, team: team, snapshot: snapshot) }
            }

            let memberSection = UIMenu(
                title: "",
                options: .displayInline,
                children: memberActions.isEmpty
                    ? [UIAction(title: L10n.tr("chat.menu.team.noAgents"), attributes: [.disabled]) { _ in }]
                    : memberActions
            )

            var bottomChildren: [UIMenuElement] = []
            if let snapshot, snapshot.activeTaskCount > 0 {
                let taskLabel = UIAction(
                    title: String(format: L10n.tr("chat.menu.team.activeTasks"), snapshot.activeTaskCount),
                    image: UIImage(systemName: "checklist"),
                    attributes: [.disabled]
                ) { _ in }
                bottomChildren.append(UIMenu(title: "", options: .displayInline, children: [taskLabel]))
            }

            let addExistingAction = UIAction(
                title: L10n.tr("team.management.action.manageAgents"),
                image: UIImage(systemName: "person.2.badge.gearshape")
            ) { [weak self] _ in
                self?.onAddAgentToTeam?(team.id)
            }

            let createAndAddAction = UIAction(
                title: L10n.tr("team.management.action.createAndAdd"),
                image: UIImage(systemName: "plus.circle")
            ) { [weak self] _ in
                self?.onCreateAgentForTeam?(team.id)
            }

            let deleteTeamAction = UIAction(
                title: L10n.tr("chat.menu.deleteTeamNamed", team.name),
                image: UIImage(systemName: "trash"),
                attributes: [.destructive]
            ) { [weak self] _ in
                self?.onDeleteTeam?(team.id)
            }

            let managementSection = UIMenu(title: "", options: .displayInline, children: [
                addExistingAction,
                createAndAddAction,
                deleteTeamAction,
            ])
            bottomChildren.append(managementSection)

            return UIMenu(
                title: teamMenuTitle(for: team, snapshot: snapshot),
                image: teamMenuImage(for: team, snapshot: snapshot),
                children: [memberSection] + bottomChildren
            )
        }

        private func makeAgentAction(for agent: AgentProfile) -> UIAction {
            makeAgentAction(for: agent, team: nil, snapshot: nil)
        }

        private func makeAgentAction(for agent: AgentProfile, team _: TeamProfile?, snapshot: TeamSwarmCoordinator.TeamMenuSnapshot?) -> UIAction {
            var title = agent.name
            if let snapshot, let memberStatus = snapshot.memberStatuses[agent.id.uuidString] {
                let badge = statusBadge(for: memberStatus)
                if !badge.isEmpty {
                    if let summary = snapshot.memberSummaries[agent.id.uuidString] {
                        let truncated = summary.count > 40 ? String(summary.prefix(40)) + "…" : summary
                        title = "\(title) · \(truncated) \(badge)"
                    } else {
                        title = "\(title) \(badge)"
                    }
                }
            }
            let showsSwarmIndicator = snapshot?.memberStatuses[agent.id.uuidString] == .busy
            let image = makeAgentMenuImage(for: agent, showsSwarmBusy: showsSwarmIndicator)
            let state: UIMenuElement.State = (agent.id == activeAgentID) ? .on : .off
            return UIAction(title: title, image: image, identifier: nil, discoverabilityTitle: nil, attributes: [], state: state) { [weak self] _ in
                self?.onAgentSwitch?(agent.id)
            }
        }

        private func statusBadge(for status: TeamSwarmCoordinator.MemberStatus) -> String {
            switch status {
            case .busy: return "🟢"
            case .awaitingPlanApproval: return "🟡"
            case .failed: return "🔴"
            case .idle, .stopped: return ""
            }
        }

        private func teamMenuTitle(for team: TeamProfile, snapshot: TeamSwarmCoordinator.TeamMenuSnapshot?) -> String {
            guard let snapshot else { return team.name }
            var parts: [String] = []
            if snapshot.busyCount > 0 {
                parts.append(String(format: L10n.tr("chat.menu.team.busyCount"), snapshot.busyCount))
            }
            if snapshot.pendingApprovalCount > 0 {
                parts.append(String(format: L10n.tr("chat.menu.team.pendingCount"), snapshot.pendingApprovalCount))
            }
            if snapshot.failedCount > 0 {
                parts.append(String(format: L10n.tr("chat.menu.team.failedCount"), snapshot.failedCount))
            }
            if parts.isEmpty { return team.name }
            return "\(team.name) · \(parts.joined(separator: " · "))"
        }

        private func teamMenuImage(for team: TeamProfile, snapshot: TeamSwarmCoordinator.TeamMenuSnapshot?) -> UIImage? {
            let hasBusy = (snapshot?.busyCount ?? 0) > 0
            return makeEmojiMenuImage(from: team.emoji, showsRunningIndicator: hasBusy)
        }

        private func compareTeams(lhs: TeamProfile, rhs: TeamProfile) -> Bool {
            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt < rhs.createdAt
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
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

        private func makeAgentMenuImage(for agent: AgentProfile, showsSwarmBusy: Bool = false) -> UIImage? {
            let prefix = "agent:\(agent.id.uuidString)::"
            let isRunning = showsSwarmBusy || ConversationSessionManager.shared.hasExecutingSession(withPrefix: prefix)
            return makeEmojiMenuImage(from: agent.emoji, showsRunningIndicator: isRunning)
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
