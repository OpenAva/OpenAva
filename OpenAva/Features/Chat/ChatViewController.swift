//
//  ChatViewController.swift
//  ChatUI
//

import ChatUI
import Combine
import OSLog
import UIKit

#if targetEnvironment(macCatalyst)
    import AppKit
#endif

private let logger = Logger(subsystem: "com.day1-labs.openava", category: "chat.stop.ui")

/// A complete chat view controller that provides message display and user input.
///
/// Usage:
///
///     let vc = ChatViewController(sessionID: "conv-1", sessionConfiguration: configuration)
///     present(vc, animated: true)
///
@MainActor
open class ChatViewController: UIViewController {
    #if targetEnvironment(macCatalyst)
        @MainActor
        private final class CatalystTitlebarToolbarCoordinator: NSObject, NSToolbarDelegate {
            private enum Item {
                static let leading = NSToolbarItem.Identifier("openava.chat.leading")
                static let title = NSToolbarItem.Identifier("openava.chat.title")
                static let trailing = NSToolbarItem.Identifier("openava.chat.trailing")
            }

            private let toolbar = NSToolbar(identifier: "openava.chat.titlebar")
            let leadingBarButtonItem: UIBarButtonItem
            let titleBarButtonItem: UIBarButtonItem
            let trailingBarButtonItem: UIBarButtonItem

            init(leadingBarButtonItem: UIBarButtonItem, titleBarButtonItem: UIBarButtonItem, trailingBarButtonItem: UIBarButtonItem) {
                self.leadingBarButtonItem = leadingBarButtonItem
                self.titleBarButtonItem = titleBarButtonItem
                self.trailingBarButtonItem = trailingBarButtonItem

                super.init()
                toolbar.delegate = self
                toolbar.allowsUserCustomization = false
                toolbar.displayMode = .iconOnly
                if #available(iOS 16.0, *) {
                    toolbar.centeredItemIdentifiers = [Item.title]
                }
            }

            func install(on titlebar: UITitlebar) {
                titlebar.titleVisibility = .hidden
                titlebar.toolbarStyle = .automatic
                titlebar.separatorStyle = .none
                if titlebar.toolbar !== toolbar {
                    titlebar.toolbar = toolbar
                }
            }

            func toolbarAllowedItemIdentifiers(_: NSToolbar) -> [NSToolbarItem.Identifier] {
                [
                    Item.leading,
                    Item.title,
                    Item.trailing,
                    .flexibleSpace,
                ]
            }

            func toolbarDefaultItemIdentifiers(_: NSToolbar) -> [NSToolbarItem.Identifier] {
                [
                    Item.leading,
                    .flexibleSpace,
                    Item.title,
                    .flexibleSpace,
                    Item.trailing,
                ]
            }

            func toolbar(
                _: NSToolbar,
                itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                willBeInsertedIntoToolbar _: Bool
            ) -> NSToolbarItem? {
                switch itemIdentifier {
                case Item.leading:
                    return NSToolbarItem(itemIdentifier: Item.leading, barButtonItem: leadingBarButtonItem)
                case Item.title:
                    return NSToolbarItem(itemIdentifier: Item.title, barButtonItem: titleBarButtonItem)
                case Item.trailing:
                    return NSToolbarItem(itemIdentifier: Item.trailing, barButtonItem: trailingBarButtonItem)
                default:
                    return nil
                }
            }
        }
    #endif

    private enum QuickCommand {
        static let contextUsage = "/context"
    }

    public struct HeaderState: Equatable {
        public var agentName: String
        public var agentEmoji: String?
        public var modelName: String
        public var providerName: String?

        public init(agentName: String, agentEmoji: String? = nil, modelName: String, providerName: String? = nil) {
            self.agentName = agentName
            self.agentEmoji = agentEmoji
            self.modelName = modelName
            self.providerName = providerName
        }
    }

    public private(set) var sessionID: String
    public let conversationModels: ConversationSession.Models
    public let sessionConfiguration: ConversationSession.Configuration
    public var configuration: Configuration

    public var inputConfiguration: ChatInputConfiguration {
        get { configuration.input }
        set {
            configuration.input = newValue
            chatInputView.configuration = newValue
        }
    }

    public private(set) var chatInputView = ChatInputView()
    public private(set) var messageListView = MessageListView()
    public weak var menuDelegate: ChatViewControllerMenuDelegate? {
        didSet {
            guard isViewLoaded else { return }
            configureNavigationItems()
        }
    }

    private lazy var avatarButton: UIButton = .init(type: .system)
    private let navigationTitleView = ChatNavigationTitleView()
    private weak var currentSession: ConversationSession?
    private var headerState: HeaderState = .init(agentName: "Assistant", agentEmoji: nil, modelName: "Not Selected")
    private lazy var dismissKeyboardTapGesture: UITapGestureRecognizer = {
        let gesture = UITapGestureRecognizer(target: self, action: #selector(handleBackgroundTapToDismiss))
        gesture.cancelsTouchesInView = false
        return gesture
    }()

    private var cancellables = Set<AnyCancellable>()
    private var sessionCancellables = Set<AnyCancellable>()
    private var keyboardHeight: CGFloat = 0
    private var latestContextUsageSnapshot: ContextUsageSnapshot?
    private var contextUsageRefreshTask: Task<Void, Never>?

    private var draftInputObject: ChatInputContent?

    private var isExecutingCurrentTurn = false {
        didSet {
            guard oldValue != isExecutingCurrentTurn else { return }
            guard isViewLoaded else { return }
            logger.notice(
                "ui executing state changed session=\(self.sessionID, privacy: .public) executing=\(String(self.isExecutingCurrentTurn), privacy: .public)"
            )
            chatInputView.setExecuting(isExecutingCurrentTurn)
        }
    }

    private lazy var titleBarButtonItem = UIBarButtonItem(title: "", style: .plain, target: self, action: #selector(handleTitleTap))

    private static func toolbarIcon(_ name: String, fallback: String) -> UIImage? {
        let base = UIImage.chatInputIcon(named: name) ?? UIImage(systemName: fallback)
        let targetSize = CGSize(width: 18, height: 18)
        guard let base, base.size.width > targetSize.width else { return base }
        let renderer = UIGraphicsImageRenderer(size: targetSize)
        return renderer.image { _ in base.draw(in: CGRect(origin: .zero, size: targetSize)) }
            .withRenderingMode(.alwaysTemplate)
    }

    private lazy var leadingBarButtonItem = UIBarButtonItem(
        image: Self.toolbarIcon("users", fallback: "person.2"),
        style: .plain,
        target: nil,
        action: nil
    )

    private lazy var trailingBarButtonItem = UIBarButtonItem(
        image: Self.toolbarIcon("menu", fallback: "ellipsis"),
        style: .plain,
        target: nil,
        action: nil
    )

    #if targetEnvironment(macCatalyst)
        private lazy var catalystTitlebarToolbarCoordinator = CatalystTitlebarToolbarCoordinator(
            leadingBarButtonItem: leadingBarButtonItem,
            titleBarButtonItem: titleBarButtonItem,
            trailingBarButtonItem: trailingBarButtonItem
        )
    #endif

    /// When set, the input draft is persisted to UserDefaults under this key so it survives
    /// app restarts. Should be unique per agent to isolate drafts between agents.
    public var draftPersistenceKey: String?

    private static let draftDefaultsPrefix = "chat.inputDraft."

    private func persistDraft(_ object: ChatInputContent) {
        guard let key = draftPersistenceKey else { return }
        let storageKey = Self.draftDefaultsPrefix + key
        if object.hasEmptyContent {
            UserDefaults.standard.removeObject(forKey: storageKey)
        } else if let data = try? JSONEncoder().encode(object) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    private func loadPersistedDraft() -> ChatInputContent? {
        guard let key = draftPersistenceKey else { return nil }
        let storageKey = Self.draftDefaultsPrefix + key
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return nil }
        return try? JSONDecoder().decode(ChatInputContent.self, from: data)
    }

    private func clearPersistedDraft() {
        guard let key = draftPersistenceKey else { return }
        UserDefaults.standard.removeObject(forKey: Self.draftDefaultsPrefix + key)
    }

    public init(
        sessionID: String = UUID().uuidString,
        models: ConversationSession.Models = .init(),
        sessionConfiguration: ConversationSession.Configuration = .init(storage: DisposableStorageProvider.shared),
        configuration: Configuration
    ) {
        self.sessionID = sessionID
        conversationModels = models
        self.sessionConfiguration = sessionConfiguration
        self.configuration = configuration
        super.init(nibName: nil, bundle: nil)
        chatInputView.configuration = self.configuration.input
    }

    @available(*, unavailable)
    public required init?(coder _: NSCoder) {
        fatalError()
    }

    override public func viewDidLoad() {
        super.viewDidLoad()
        view.layoutIfNeeded()

        view.backgroundColor = ChatUIDesign.Color.warmCream
        chatInputView.usesAutoLayoutHeightConstraint = false
        chatInputView.translatesAutoresizingMaskIntoConstraints = true
        messageListView.translatesAutoresizingMaskIntoConstraints = true

        configureSystemTopBarViews()

        view.addSubview(messageListView)
        view.addSubview(chatInputView)
        messageListView.addGestureRecognizer(dismissKeyboardTapGesture)
        messageListView.theme = configuration.messageTheme

        configureSession(for: sessionID)
        chatInputView.delegate = self
        chatInputView.bind(sessionID: sessionID)
        configureNavigationItems()
        applyHeaderStateToTitleView()

        setupKeyboardObservation()
        setupInputHeightObservation()
        setupActivationObservation()
    }

    override public func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutViews()
        updateCatalystTitlebarToolbarIfNeeded()
    }

    override open func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        configureNavigationItems()
    }

    override open func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        updateCatalystTitlebarToolbarIfNeeded()
    }

    private func layoutViews() {
        let safeArea = view.safeAreaInsets
        let inputHeight = chatInputView.heightPublisher.value
        let bottomPadding = max(safeArea.bottom, 0)
        let inputExtension = bottomPadding
        let totalInputHeight = inputHeight + inputExtension

        chatInputView.bottomBackgroundExtension = inputExtension

        let inputY = view.bounds.height - totalInputHeight - keyboardHeight
        chatInputView.frame = CGRect(
            x: 0,
            y: max(inputY, safeArea.top),
            width: view.bounds.width,
            height: totalInputHeight
        )

        messageListView.frame = CGRect(
            x: 0,
            y: 0,
            width: view.bounds.width,
            height: chatInputView.frame.minY
        )
        messageListView.contentSafeAreaInsets = UIEdgeInsets(top: safeArea.top, left: 0, bottom: 0, right: 0)
    }

    private func setupKeyboardObservation() {
        NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)
            .compactMap { $0.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect }
            .sink { [weak self] frame in
                guard let self else { return }
                let converted = view.convert(frame, from: nil)
                keyboardHeight = max(view.bounds.height - converted.minY - view.safeAreaInsets.bottom, 0)
                UIView.animate(withDuration: 0.25) {
                    self.layoutViews()
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)
            .sink { [weak self] _ in
                self?.keyboardHeight = 0
                UIView.animate(withDuration: 0.25) {
                    self?.layoutViews()
                }
            }
            .store(in: &cancellables)
    }

    @objc private func handleBackgroundTapToDismiss() {
        view.endEditing(true)
    }

    private func setupInputHeightObservation() {
        chatInputView.heightPublisher
            .removeDuplicates()
            .sink { [weak self] _ in
                UIView.animate(withDuration: 0.2) {
                    self?.layoutViews()
                }
            }
            .store(in: &cancellables)
    }

    private func setupActivationObservation() {
        #if targetEnvironment(macCatalyst)
            NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
                .sink { [weak self] _ in
                    guard let self else { return }
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.isViewLoaded else { return }
                        self.keyboardHeight = 0
                        self.chatInputView.setNeedsLayout()
                        self.chatInputView.layoutIfNeeded()
                        self.messageListView.setNeedsLayout()
                        self.messageListView.layoutIfNeeded()
                        self.layoutViews()
                        self.updateCatalystTitlebarToolbarIfNeeded()
                    }
                }
                .store(in: &cancellables)
        #endif
    }

    private func configureNavigationItems() {
        configureLeadingMenuButton()

        leadingBarButtonItem.image = resolvedButtonImage(from: avatarButton)
        leadingBarButtonItem.menu = avatarButton.menu
        trailingBarButtonItem.menu = menuDelegate?.chatViewControllerMenu(self)

        let item = navigationItem
        item.leftBarButtonItem = UIBarButtonItem(customView: avatarButton)
        item.rightBarButtonItem = trailingBarButtonItem
        updateCatalystTitlebarToolbarIfNeeded()

        if isViewLoaded {
            view.setNeedsLayout()
        }
    }

    private func bindNavigationTitleUpdates(session: ConversationSession) {
        sessionCancellables.removeAll()
        isExecutingCurrentTurn = session.currentTask != nil
        session.messagesDidChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] messages, scrolling in
                self?.messageListView.showsInterruptedRetryAction = session.showsInterruptedRetryAction
                self?.messageListView.render(messages: messages, scrolling: scrolling)
                self?.scheduleContextUsageRefresh()
            }
            .store(in: &sessionCancellables)
        session.usageDidChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.scheduleContextUsageRefresh()
            }
            .store(in: &sessionCancellables)
        scheduleContextUsageRefresh()
    }

    /// Updates `autoCompactEnabled` on the active session's chat model without recreating the session.
    public func updateAutoCompactEnabled(_ enabled: Bool) {
        currentSession?.models.chat?.autoCompactEnabled = enabled
        scheduleContextUsageRefresh()
    }

    @MainActor
    public func currentContextUsageSnapshot() async -> ContextUsageSnapshot? {
        guard let session = currentSession, let model = session.models.chat else {
            return nil
        }
        let snapshot = await session.contextUsageSnapshot(for: model)
        latestContextUsageSnapshot = snapshot
        updateContextQuickSetting(with: snapshot)
        return snapshot
    }

    @MainActor
    public func performManualCompact() async throws {
        guard let session = currentSession, let model = session.models.chat else { return }
        try await session.compact(model: model)
        scheduleContextUsageRefresh()
    }

    @MainActor
    public func quickSettingAnchorView(forCommand command: String) -> UIView? {
        chatInputView.quickSettingButton(forCommand: command)
    }

    private func configureSession(for id: String) {
        sessionID = id
        let session = ConversationSessionManager.shared.session(for: id, configuration: sessionConfiguration)
        applyConversationModels(conversationModels, to: session)
        currentSession = session
        isExecutingCurrentTurn = session.currentTask != nil
        messageListView.prepareForNewSession()
        messageListView.onToggleReasoningCollapse = { [weak self] messageID in
            guard let self, let conversationMessage = self.currentSession?.message(for: messageID) else { return }
            for (index, part) in conversationMessage.parts.enumerated() {
                if case var .reasoning(reasoningPart) = part {
                    reasoningPart.isCollapsed.toggle()
                    conversationMessage.parts[index] = .reasoning(reasoningPart)
                    self.currentSession?.notifyMessagesDidChange(scrolling: false)
                    return
                }
            }
        }
        messageListView.onToggleToolResultCollapse = { [weak self] messageID, toolCallID in
            guard let self, let conversationMessage = self.currentSession?.message(for: messageID) else { return }
            var didToggle = false
            for (index, part) in conversationMessage.parts.enumerated() {
                guard case var .toolResult(toolResult) = part,
                      toolResult.toolCallID == toolCallID
                else {
                    continue
                }
                toolResult.isCollapsed.toggle()
                conversationMessage.parts[index] = .toolResult(toolResult)
                didToggle = true
            }
            guard didToggle else { return }
            self.currentSession?.notifyMessagesDidChange(scrolling: false)
        }
        messageListView.onRetryInterruptedInference = { [weak self] in
            guard let self, let session = self.currentSession else { return }
            session.retryInterruptedInference(messageListView: self.messageListView)
        }
        messageListView.onRollbackUserQuery = { [weak self] messageID, queryText in
            guard let self, let session = self.currentSession else { return }
            session.delete(after: messageID) { [weak self] in
                guard let self else { return }
                // Also remove the selected user message itself.
                session.delete(messageID)
                self.draftInputObject = ChatInputContent(text: queryText)
                self.chatInputView.refill(withText: queryText, attachments: [])
                self.chatInputView.focus()
            }
        }
        bindNavigationTitleUpdates(session: session)
    }

    private func scheduleContextUsageRefresh() {
        contextUsageRefreshTask?.cancel()
        guard let session = currentSession, let model = session.models.chat else {
            latestContextUsageSnapshot = nil
            updateContextQuickSetting(with: nil)
            return
        }

        contextUsageRefreshTask = Task { @MainActor [weak self, weak session] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard let self, let session, self.currentSession === session, !Task.isCancelled else { return }
            let snapshot = await session.contextUsageSnapshot(for: model)
            guard !Task.isCancelled else { return }
            latestContextUsageSnapshot = snapshot
            updateContextQuickSetting(with: snapshot)
        }
    }

    private func updateContextQuickSetting(with snapshot: ContextUsageSnapshot?) {
        let title = snapshot.map {
            String(format: String.localized("Context %lld%%"), locale: .current, Int64($0.usedPercentage))
        } ?? String.localized("Context --%")
        chatInputView.updateQuickSettingCommand(command: QuickCommand.contextUsage, title: title, icon: "gauge")
    }

    private func resetInputState() {
        draftInputObject = nil
        clearPersistedDraft()
        chatInputView.resetValues()
        chatInputView.clearTemporaryStorage()
    }

    public func updateHeader(_ state: HeaderState) {
        guard headerState != state else { return }
        headerState = state
        applyHeaderStateToTitleView()
    }

    public func refreshNavigationMenus() {
        configureNavigationItems()
    }

    public func presentLeadingMenu() {
        avatarButton.sendActions(for: .touchUpInside)
    }

    private func applyHeaderStateToTitleView() {
        let agent = headerState.agentName.trimmingCharacters(in: .whitespacesAndNewlines)
        let emoji = (headerState.agentEmoji ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let model = resolvedHeaderModelTitle(from: headerState)
        let agentText = emoji.isEmpty ? (agent.isEmpty ? "Assistant" : agent) : "\(emoji) \(agent)"
        let title = "\(agentText) · \(model)"
        
        navigationTitleView.agentTitle = agent.isEmpty ? "Assistant" : agent
        navigationTitleView.agentEmoji = emoji
        navigationTitleView.modelTitle = model

        navigationItem.title = title
        navigationItem.titleView = navigationTitleView
        titleBarButtonItem.title = title
        if isViewLoaded {
            view.setNeedsLayout()
        }
    }

    private func resolvedHeaderModelTitle(from state: HeaderState) -> String {
        let model = state.modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.isEmpty ? "Not Selected" : model
    }

    private func configureSystemTopBarViews() {
        navigationTitleView.onAgentTap = { [weak self] in
            guard let self else { return }
            self.menuDelegate?.chatViewControllerDidTapAgentTitle(self)
        }
        navigationTitleView.onModelTap = { [weak self] in
            guard let self else { return }
            self.menuDelegate?.chatViewControllerDidTapModelTitle(self)
        }
        applyHeaderStateToTitleView()
    }

    @objc private func handleTitleTap() {
        menuDelegate?.chatViewControllerDidTapModelTitle(self)
    }

    private func updateCatalystTitlebarToolbarIfNeeded() {
        #if targetEnvironment(macCatalyst)
            guard let titlebar = view.window?.windowScene?.titlebar else { return }
            catalystTitlebarToolbarCoordinator.install(on: titlebar)
        #endif
    }

    private func configureLeadingMenuButton() {
        avatarButton.menu = nil
        let image = UIImage.chatInputIcon(named: "users") ?? UIImage(systemName: "person.2")
        if #available(iOS 15.0, *) {
            var configuration = avatarButton.configuration ?? .plain()
            configuration.image = image
            configuration.contentInsets = .zero
            configuration.imagePadding = 0
            avatarButton.configuration = configuration
        } else {
            avatarButton.setImage(image, for: .normal)
        }
        avatarButton.tintColor = ChatUIDesign.Color.black60
        avatarButton.imageView?.contentMode = .scaleAspectFit
        avatarButton.contentHorizontalAlignment = .left
        avatarButton.contentVerticalAlignment = .center
        avatarButton.showsMenuAsPrimaryAction = true
        menuDelegate?.chatViewControllerLeadingButton(self, button: avatarButton)
    }

    private func resolvedButtonImage(from button: UIButton) -> UIImage? {
        if #available(iOS 15.0, *), let image = button.configuration?.image {
            return image
        }
        return button.image(for: .normal)
    }
}

// MARK: - Chat Input

extension ChatViewController: ChatInputDelegate {
    public func chatInputDidSubmit(_: ChatInputView, object: ChatInputContent, completion: @escaping @Sendable (Bool) -> Void) {
        guard let session = currentSession, let model = session.models.chat else {
            logger.notice("submit ignored session=\(self.sessionID, privacy: .public) reason=no_active_session_or_model")
            completion(false)
            return
        }
        logger.notice(
            "submit accepted session=\(session.id, privacy: .public) textLength=\(object.text.count) attachments=\(object.attachments.count) hasTask=\(String(session.currentTask != nil), privacy: .public)"
        )
        let userInput = makeUserInput(from: object)
        draftInputObject = nil
        clearPersistedDraft()
        messageListView.markNextUpdateAsUserInitiated()
        isExecutingCurrentTurn = true
        session.runInference(model: model, messageListView: messageListView, input: userInput) {
            Task { @MainActor [weak self] in
                logger.notice("submit completion session=\(session.id, privacy: .public)")
                self?.isExecutingCurrentTurn = false
            }
            completion(true)
        }
    }

    public func chatInputDidRequestStop(_: ChatInputView) {
        logger.notice(
            "stop tapped session=\(self.sessionID, privacy: .public) hasSession=\(String(self.currentSession != nil), privacy: .public) hasTask=\(String(self.currentSession?.currentTask != nil), privacy: .public)"
        )
        currentSession?.interruptCurrentTurn(reason: .userStop)
        isExecutingCurrentTurn = false
    }

    public func chatInputDidUpdateObject(_: ChatInputView, object: ChatInputContent) {
        draftInputObject = object
        persistDraft(object)
    }

    public func chatInputDidRequestObjectForRestore(_: ChatInputView) -> ChatInputContent? {
        if let inMemory = draftInputObject { return inMemory }
        let persisted = loadPersistedDraft()
        draftInputObject = persisted
        return persisted
    }

    public func chatInputDidReportError(_: ChatInputView, error: String) {
        let alert = UIAlertController(title: String.localized("Error"), message: error, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String.localized("OK"), style: .default))
        present(alert, animated: true)
    }

    public func chatInputDidTriggerCommand(_: ChatInputView, command: String) {
        let normalized = command.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if menuDelegate?.chatViewControllerHandleCommand(self, command: normalized) == true {
            return
        }
        let alert = UIAlertController(
            title: String.localized("Unsupported command"),
            message: command,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: String.localized("OK"), style: .default))
        present(alert, animated: true)
    }

    public func chatInputDidTriggerSkill(_ input: ChatInputView, prompt: String, autoSubmit: Bool) {
        if autoSubmit {
            return
        }
        input.refill(withText: prompt, attachments: [])
        input.focus()
    }
}
