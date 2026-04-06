//
//  ChatViewController.swift
//  LanguageModelChatUI
//

import Combine
import UIKit

/// A complete chat view controller that provides message display and user input.
///
/// Usage:
///
///     let vc = ChatViewController(sessionID: "conv-1", sessionConfiguration: configuration)
///     present(vc, animated: true)
///
open class ChatViewController: UIViewController {
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

    private enum Layout {
        static let topBarHorizontalInset: CGFloat = 16
        static let topBarTopSpacing: CGFloat = 2
        static let topBarBottomSpacing: CGFloat = 2
        static let topBarTouchSize: CGFloat = 34
        static let topBarTitleSpacing: CGFloat = 10
        static let topBarDividerHeight: CGFloat = 1
        static let topBarAvatarSize: CGFloat = 24
    }

    public private(set) var sessionID: String
    public let conversationModels: ConversationSession.Models
    public let sessionConfiguration: ConversationSession.Configuration
    public var configuration: Configuration

    /// When `true`, the controller assumes it is embedded inside a
    /// `UINavigationController` and hides its own top bar, instead
    /// placing the title in the navigation bar (always inline/compact)
    /// and moving the menu to a toolbar bar-button item.
    public var prefersNavigationBarManaged: Bool = false {
        didSet {
            guard isViewLoaded else { return }
            applyNavigationBarManagedMode()
        }
    }

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

    private let topBarBackgroundView = UIView()
    private let topBarBlurView = UIVisualEffectView(effect: UIBlurEffect(style: .regular))
    private let topBarDividerView = SeparatorView()
    private let topBarContentView = UIView()
    private let titleAvatarContainerView = UIView()
    private lazy var avatarButton: UIButton = .init(type: .system)
    private lazy var menuButton: UIButton = .init(type: .system)
    private let navigationTitleView = ChatAgentModelTitleView()
    private weak var currentSession: ConversationSession?
    private var resolvedTitleMetadata: ConversationTitleMetadata = .init(title: String.localized("Chat"))
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
        configuration: Configuration = .init()
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

        view.backgroundColor = .systemBackground
        topBarBackgroundView.backgroundColor = .clear

        configureTopBarViews()

        view.addSubview(topBarBackgroundView)
        view.addSubview(messageListView)
        view.addSubview(chatInputView)
        messageListView.addGestureRecognizer(dismissKeyboardTapGesture)
        messageListView.theme = configuration.messageTheme

        configureSession(for: sessionID)
        chatInputView.delegate = self
        chatInputView.bind(sessionID: sessionID)
        configureNavigationItems()
        refreshNavigationTitle()
        applyHeaderStateToTitleView()

        setupKeyboardObservation()
        setupInputHeightObservation()

        applyNavigationBarManagedMode()
    }

    override public func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutViews()
    }

    private func layoutViews() {
        let safeArea = view.safeAreaInsets
        let inputHeight = chatInputView.heightPublisher.value
        let bottomPadding = max(safeArea.bottom, 0)
        let topBarHeight = layoutTopBar(safeAreaTop: safeArea.top)
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

        if prefersNavigationBarManaged {
            // Extend the list view behind the translucent navigation bar.
            // Content is offset via contentSafeAreaInsets so it starts below the bar,
            // but scrolls underneath it for the glass morphism effect.
            messageListView.frame = CGRect(
                x: 0,
                y: 0,
                width: view.bounds.width,
                height: chatInputView.frame.minY
            )
            messageListView.contentSafeAreaInsets = UIEdgeInsets(
                top: safeArea.top,
                left: 0,
                bottom: 0,
                right: 0
            )
        } else {
            messageListView.frame = CGRect(
                x: 0,
                y: topBarHeight,
                width: view.bounds.width,
                height: chatInputView.frame.minY - topBarHeight
            )
            messageListView.contentSafeAreaInsets = .zero
        }
    }

    @discardableResult
    private func layoutTopBar(safeAreaTop: CGFloat) -> CGFloat {
        if prefersNavigationBarManaged {
            topBarBackgroundView.frame = .zero
            return safeAreaTop
        }
        let contentY = safeAreaTop + Layout.topBarTopSpacing
        let leadingInset: CGFloat = Layout.topBarHorizontalInset
        let contentHeight = max(Layout.topBarTouchSize, navigationTitleView.intrinsicContentSize.height)
        let iconSide = Layout.topBarAvatarSize

        topBarContentView.frame = CGRect(
            x: 0,
            y: contentY,
            width: view.bounds.width,
            height: contentHeight
        )

        topBarBackgroundView.frame = CGRect(
            x: 0,
            y: 0,
            width: view.bounds.width,
            height: topBarContentView.frame.maxY + Layout.topBarBottomSpacing
        )
        topBarBlurView.frame = topBarBackgroundView.bounds
        topBarDividerView.frame = CGRect(
            x: 0,
            y: topBarBackgroundView.bounds.height - Layout.topBarDividerHeight,
            width: topBarBackgroundView.bounds.width,
            height: Layout.topBarDividerHeight
        )

        let avatarY = (contentHeight - iconSide) / 2
        titleAvatarContainerView.frame = CGRect(
            x: leadingInset,
            y: 0,
            width: Layout.topBarTouchSize,
            height: contentHeight
        )
        avatarButton.frame = CGRect(x: 0, y: avatarY, width: iconSide, height: iconSide)
        let menuY = (contentHeight - Layout.topBarTouchSize) / 2
        menuButton.frame = CGRect(
            x: topBarContentView.bounds.width - Layout.topBarHorizontalInset - Layout.topBarTouchSize,
            y: menuY,
            width: Layout.topBarTouchSize,
            height: Layout.topBarTouchSize
        )

        let titleSize = navigationTitleView.intrinsicContentSize
        let leadingReservedWidth = titleAvatarContainerView.frame.maxX + Layout.topBarTitleSpacing
        let trailingReservedWidth = topBarContentView.bounds.width - menuButton.frame.minX + Layout.topBarTitleSpacing
        let symmetricReservedWidth = max(leadingReservedWidth, trailingReservedWidth)
        let availableWidth = max(0, topBarContentView.bounds.width - symmetricReservedWidth * 2)
        let titleWidth = min(titleSize.width, availableWidth)
        let titleHeight = min(contentHeight, titleSize.height)

        navigationTitleView.frame = CGRect(
            x: (topBarContentView.bounds.width - titleWidth) / 2,
            y: (contentHeight - titleHeight) / 2,
            width: titleWidth,
            height: titleHeight
        )

        return topBarBackgroundView.frame.maxY
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

    private func configureNavigationItems() {
        if prefersNavigationBarManaged {
            // In managed mode, title and menu live in the navigation bar.
            navigationItem.title = headerState.agentName
            navigationItem.largeTitleDisplayMode = .inline

            if let menu = menuDelegate?.chatViewControllerMenu(self) {
                let barButton = UIBarButtonItem(
                    image: UIImage(systemName: "ellipsis.circle"),
                    menu: menu
                )
                navigationItem.rightBarButtonItem = barButton
            } else {
                navigationItem.rightBarButtonItem = nil
            }

            // Hide the custom top bar menu button since nav bar owns it now.
            menuButton.isHidden = true
        } else {
            navigationItem.titleView = nil
            navigationItem.leftBarButtonItem = nil
            navigationItem.rightBarButtonItem = nil

            // Re-apply leading button configuration when delegate data changes.
            menuDelegate?.chatViewControllerLeadingButton(self, button: avatarButton)

            if let menu = menuDelegate?.chatViewControllerMenu(self) {
                menuButton.menu = menu
                menuButton.isHidden = false
            } else {
                menuButton.menu = nil
                menuButton.isHidden = true
            }
        }

        if isViewLoaded {
            view.setNeedsLayout()
        }
    }

    private func applyNavigationBarManagedMode() {
        let managed = prefersNavigationBarManaged
        topBarBackgroundView.isHidden = managed
        if managed {
            navigationItem.largeTitleDisplayMode = .inline
            if let nav = navigationController {
                nav.navigationBar.prefersLargeTitles = false
            }
        }
        configureNavigationItems()
        view.setNeedsLayout()
    }

    private func bindNavigationTitleUpdates(session: ConversationSession) {
        sessionCancellables.removeAll()
        session.messagesDidChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in
                self?.refreshNavigationTitle()
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
        chatInputView.quickSettingBar.button(forCommand: command)
    }

    private func configureSession(for id: String) {
        sessionID = id
        let session = ConversationSessionManager.shared.session(for: id, configuration: sessionConfiguration)
        applyConversationModels(conversationModels, to: session)
        currentSession = session
        messageListView.session = session
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
        chatInputView.quickSettingBar.updateCommand(command: QuickCommand.contextUsage, title: title, icon: "gauge")
    }

    @MainActor
    private func switchSession(to id: String) {
        draftInputObject = nil
        clearPersistedDraft()
        chatInputView.resetValues()
        chatInputView.storage.removeAll()
        chatInputView.bind(sessionID: id)
        configureSession(for: id)
        messageListView.updateList()
        refreshNavigationTitle()
    }

    private func resolveTitle(from metadata: ConversationTitleMetadata?) -> String {
        guard currentSession != nil else { return String.localized("Chat") }
        if let storedTitle = metadata?.title {
            let normalized = storedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty, normalized != "Untitled" else { return String.localized("Chat") }
            return storedTitle
        }
        return String.localized("Chat")
    }

    private func refreshNavigationTitle() {
        let storedTitleMetadata = ConversationTitleMetadata(storageValue: currentSession?.storageProvider.title(for: sessionID))
        let resolvedTitle = resolveTitle(from: storedTitleMetadata)

        resolvedTitleMetadata = .init(title: resolvedTitle, avatar: storedTitleMetadata?.avatar ?? ConversationTitleMetadata.defaultAvatar)
        // Keep hamburger menu icon instead of emoji avatar
        let hamburgerImage = UIImage(systemName: "line.3.horizontal")
        let symbolConfig = UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        #if targetEnvironment(macCatalyst)
            applyCatalystMenuButtonStyle(avatarButton, image: hamburgerImage, symbolConfiguration: symbolConfig)
        #else
            avatarButton.setImage(hamburgerImage, for: .normal)
            avatarButton.setPreferredSymbolConfiguration(symbolConfig, forImageIn: .normal)
        #endif
        avatarButton.tintColor = UIColor.secondaryLabel.withAlphaComponent(0.5)
        if prefersNavigationBarManaged {
            navigationItem.title = headerState.agentName
        }
        if isViewLoaded {
            view.setNeedsLayout()
        }
    }

    public func updateHeader(_ state: HeaderState) {
        guard headerState != state else { return }
        headerState = state
        applyHeaderStateToTitleView()
    }

    public func presentLeadingMenu() {
        avatarButton.sendActions(for: .touchUpInside)
    }

    public func presentTrailingMenu() {
        menuButton.sendActions(for: .touchUpInside)
    }

    private func applyHeaderStateToTitleView() {
        navigationTitleView.agentTitle = headerState.agentName
        navigationTitleView.agentEmoji = headerState.agentEmoji ?? ""
        navigationTitleView.modelTitle = makeModelSubtitle(from: headerState)
        if prefersNavigationBarManaged {
            navigationItem.title = headerState.agentName
        }
        if isViewLoaded {
            view.setNeedsLayout()
        }
    }

    private func makeModelSubtitle(from state: HeaderState) -> String {
        let model = state.modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        let provider = state.providerName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let resolvedModel = model.isEmpty ? "Not Selected" : model
        guard provider.isEmpty == false else { return resolvedModel }
        return "\(resolvedModel) · \(provider)"
    }

    private func configureTopBarViews() {
        topBarBackgroundView.clipsToBounds = true
        topBarBlurView.isUserInteractionEnabled = false
        topBarContentView.backgroundColor = .clear

        titleAvatarContainerView.isUserInteractionEnabled = true

        // Configure avatar button for custom interactions (e.g., session switching)
        avatarButton.menu = nil
        avatarButton.showsMenuAsPrimaryAction = false
        let hamburgerImage = UIImage(systemName: "line.3.horizontal")
        let symbolConfig = UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        #if targetEnvironment(macCatalyst)
            applyCatalystMenuButtonStyle(avatarButton, image: hamburgerImage, symbolConfiguration: symbolConfig)
        #else
            avatarButton.setImage(hamburgerImage, for: .normal)
            avatarButton.setPreferredSymbolConfiguration(symbolConfig, forImageIn: .normal)
        #endif
        avatarButton.imageView?.contentMode = .scaleAspectFit
        avatarButton.adjustsImageWhenHighlighted = false
        avatarButton.tintColor = UIColor.secondaryLabel.withAlphaComponent(0.5)
        menuDelegate?.chatViewControllerLeadingButton(self, button: avatarButton)

        navigationTitleView.onAgentTap = { [weak self] in
            guard let self else { return }
            self.menuDelegate?.chatViewControllerDidTapAgentTitle(self)
        }
        navigationTitleView.onModelTap = { [weak self] in
            guard let self else { return }
            self.menuDelegate?.chatViewControllerDidTapModelTitle(self)
        }

        let menuImage = UIImage(systemName: "chevron.down")
        #if targetEnvironment(macCatalyst)
            applyCatalystMenuButtonStyle(menuButton, image: menuImage, symbolConfiguration: symbolConfig)
        #else
            menuButton.setImage(menuImage, for: .normal)
            menuButton.setPreferredSymbolConfiguration(symbolConfig, forImageIn: .normal)
        #endif
        menuButton.showsMenuAsPrimaryAction = true
        menuButton.tintColor = UIColor.secondaryLabel.withAlphaComponent(0.5)
        menuButton.imageView?.contentMode = .scaleAspectFit
        menuButton.contentHorizontalAlignment = .right
        menuButton.contentVerticalAlignment = .center
        menuButton.isHidden = true

        topBarBackgroundView.addSubview(topBarBlurView)
        topBarBackgroundView.addSubview(topBarDividerView)
        topBarBackgroundView.addSubview(topBarContentView)
        topBarContentView.addSubview(titleAvatarContainerView)
        titleAvatarContainerView.addSubview(avatarButton)
        topBarContentView.addSubview(navigationTitleView)
        topBarContentView.addSubview(menuButton)
    }

    #if targetEnvironment(macCatalyst)
        private func applyCatalystMenuButtonStyle(
            _ button: UIButton,
            image: UIImage?,
            symbolConfiguration: UIImage.SymbolConfiguration
        ) {
            guard #available(iOS 16.0, *) else {
                button.setImage(image, for: .normal)
                button.setPreferredSymbolConfiguration(symbolConfiguration, forImageIn: .normal)
                return
            }

            var config = button.configuration ?? .plain()
            config.image = image
            config.preferredSymbolConfigurationForImage = symbolConfiguration
            config.indicator = .none
            config.macIdiomStyle = .borderless
            config.contentInsets = .zero
            config.imagePadding = 0
            button.configuration = config
        }
    #endif
}

// MARK: - Title Regeneration

public extension ChatViewController {
    /// Regenerate the conversation title and emoji avatar.
    /// Shows a loading alert during generation and dismisses it upon completion.
    func regenerateTitle() {
        guard let session = currentSession else { return }

        let alert = UIAlertController(
            title: nil,
            message: String.localized("Generating…"),
            preferredStyle: .alert
        )
        let indicator = UIActivityIndicatorView(style: .medium)
        indicator.translatesAutoresizingMaskIntoConstraints = false
        indicator.startAnimating()
        alert.view.addSubview(indicator)
        NSLayoutConstraint.activate([
            indicator.centerYAnchor.constraint(equalTo: alert.view.centerYAnchor),
            indicator.leadingAnchor.constraint(equalTo: alert.view.leadingAnchor, constant: 20),
        ])

        present(alert, animated: true)

        Task { @MainActor in
            await session.regenerateTitle()
            alert.dismiss(animated: true) { [weak self] in
                self?.refreshNavigationTitle()
            }
        }
    }

    func clearConversation() {
        guard let session = currentSession else { return }

        draftInputObject = nil
        clearPersistedDraft()
        chatInputView.resetValues()
        chatInputView.storage.removeAll()
        chatInputView.bind(sessionID: sessionID)
        session.clear { [weak self] in
            Task { @MainActor in
                self?.messageListView.updateList()
                self?.refreshNavigationTitle()
            }
        }
    }

    private func handleCommand(_ command: String) {
        let normalized = command.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if menuDelegate?.chatViewControllerHandleCommand(self, command: normalized) == true {
            return
        }
        switch normalized {
        case "/new":
            guard let session = currentSession else { return }
            Task { @MainActor in
                let newSessionID = menuDelegate?.chatViewControllerRequestNewSessionID(self, from: sessionID)
                    ?? configuration.newSessionIDProvider()
                switchSession(to: newSessionID)
            }
        default:
            let alert = UIAlertController(
                title: String.localized("Unsupported command"),
                message: command,
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: String.localized("OK"), style: .default))
            present(alert, animated: true)
        }
    }
}

// MARK: - Chat Input

extension ChatViewController: ChatInputDelegate {
    public func chatInputDidSubmit(_ input: ChatInputView, object: ChatInputContent, completion: @escaping @Sendable (Bool) -> Void) {
        _ = input
        guard let session = messageListView.session else {
            completion(false)
            return
        }
        guard let model = session.models.chat else {
            completion(false)
            return
        }
        let userInput = makeUserInput(from: object)
        draftInputObject = nil
        clearPersistedDraft()
        session.runInference(model: model, messageListView: messageListView, input: userInput) {
            completion(true)
        }
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
        handleCommand(command)
    }

    public func chatInputDidTriggerSkill(_ input: ChatInputView, prompt: String, autoSubmit: Bool) {
        if autoSubmit {
            return
        }
        input.refill(withText: prompt, attachments: [])
        input.focus()
    }
}
