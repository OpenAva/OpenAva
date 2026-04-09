//
//  ChatViewController.swift
//  LanguageModelChatUI
//

import Combine
import UIKit

#if targetEnvironment(macCatalyst)
    import AppKit
#endif

/// A complete chat view controller that provides message display and user input.
///
/// Usage:
///
///     let vc = ChatViewController(sessionID: "conv-1", sessionConfiguration: configuration)
///     present(vc, animated: true)
///
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

    private enum Layout {
        static let topBarHorizontalInset: CGFloat = 16
        static let topBarTopSpacing: CGFloat = 0
        static let topBarTouchSize: CGFloat = 32
        static let topBarTitleSpacing: CGFloat = 8
        static let topBarAvatarSize: CGFloat = 22

        #if targetEnvironment(macCatalyst)
            static let catalystTopBarHorizontalInset: CGFloat = 80
            static let catalystTopBarTopInset: CGFloat = 10
        #endif
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

    #if targetEnvironment(macCatalyst)
        private lazy var catalystTitleBarButtonItem: UIBarButtonItem = {
            let item = UIBarButtonItem(
                title: "Assistant \u{203A}",
                style: .plain,
                target: self,
                action: #selector(catalystTitleBarButtonTapped)
            )
            item.setTitleTextAttributes([
                .font: UIFont.systemFont(ofSize: 14, weight: .semibold),
            ], for: .normal)
            item.setTitleTextAttributes([
                .font: UIFont.systemFont(ofSize: 14, weight: .semibold),
            ], for: .highlighted)
            return item
        }()

        @objc private func catalystTitleBarButtonTapped() {
            menuDelegate?.chatViewControllerDidTapModelTitle(self)
        }

        private static func catalystToolbarIcon(_ name: String, fallback: String) -> UIImage? {
            let base = UIImage.chatInputIcon(named: name) ?? UIImage(systemName: fallback)
            let targetSize = CGSize(width: 18, height: 18)
            guard let base, base.size.width > targetSize.width else { return base }
            let renderer = UIGraphicsImageRenderer(size: targetSize)
            return renderer.image { _ in base.draw(in: CGRect(origin: .zero, size: targetSize)) }
                .withRenderingMode(.alwaysTemplate)
        }

        private lazy var catalystLeadingBarButtonItem = UIBarButtonItem(
            image: Self.catalystToolbarIcon("users", fallback: "person.2"),
            style: .plain,
            target: nil,
            action: nil
        )

        private lazy var catalystTrailingBarButtonItem = UIBarButtonItem(
            image: Self.catalystToolbarIcon("menu", fallback: "ellipsis"),
            style: .plain,
            target: nil,
            action: nil
        )

        private lazy var catalystTitlebarToolbarCoordinator = CatalystTitlebarToolbarCoordinator(
            leadingBarButtonItem: catalystLeadingBarButtonItem,
            titleBarButtonItem: catalystTitleBarButtonItem,
            trailingBarButtonItem: catalystTrailingBarButtonItem
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

        view.backgroundColor = ChatUIDesign.Color.warmCream
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
        updateCatalystTitlebarToolbarIfNeeded()
    }

    override open func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        updateCatalystTitlebarToolbarIfNeeded()
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

        if prefersNavigationBarManaged || usesCatalystTitlebarToolbar {
            messageListView.frame = CGRect(
                x: 0,
                y: 0,
                width: view.bounds.width,
                height: chatInputView.frame.minY
            )
            messageListView.contentSafeAreaInsets = prefersNavigationBarManaged
                ? UIEdgeInsets(top: safeArea.top, left: 0, bottom: 0, right: 0)
                : .zero
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
        if prefersNavigationBarManaged || usesCatalystTitlebarToolbar {
            topBarBackgroundView.frame = .zero
            return safeAreaTop
        }
        let contentY = resolvedTopBarContentY(safeAreaTop: safeAreaTop)
        let leadingInset = resolvedTopBarLeadingInset
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
            height: topBarContentView.frame.maxY
        )
        topBarBlurView.frame = topBarBackgroundView.bounds

        titleAvatarContainerView.frame = CGRect(
            x: leadingInset,
            y: 0,
            width: Layout.topBarTouchSize,
            height: contentHeight
        )
        let menuY = (contentHeight - Layout.topBarTouchSize) / 2
        avatarButton.frame = CGRect(
            x: 0,
            y: menuY,
            width: Layout.topBarTouchSize,
            height: Layout.topBarTouchSize
        )
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

    private var resolvedTopBarLeadingInset: CGFloat {
        #if targetEnvironment(macCatalyst)
            Layout.catalystTopBarHorizontalInset
        #else
            Layout.topBarHorizontalInset
        #endif
    }

    private func resolvedTopBarContentY(safeAreaTop: CGFloat) -> CGFloat {
        #if targetEnvironment(macCatalyst)
            return Layout.catalystTopBarTopInset
        #else
            return safeAreaTop + Layout.topBarTopSpacing
        #endif
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
        navigationItem.titleView = nil
        navigationItem.leftBarButtonItem = nil
        navigationItem.rightBarButtonItem = nil

        menuDelegate?.chatViewControllerLeadingButton(self, button: avatarButton)

        if usesCatalystTitlebarToolbar {
            #if targetEnvironment(macCatalyst)
                catalystLeadingBarButtonItem.menu = avatarButton.menu
                catalystTrailingBarButtonItem.menu = menuDelegate?.chatViewControllerMenu(self)
            #endif
            updateCatalystTitlebarToolbarIfNeeded()
        } else if prefersNavigationBarManaged {
            navigationItem.title = headerState.agentName
            navigationItem.largeTitleDisplayMode = .inline
            navigationItem.rightBarButtonItem = menuDelegate?.chatViewControllerMenu(self).map {
                UIBarButtonItem(image: UIImage(systemName: "ellipsis.circle"), menu: $0)
            }
            menuButton.isHidden = true
        } else {
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
        topBarBackgroundView.isHidden = managed || usesCatalystTitlebarToolbar
        if managed {
            navigationItem.largeTitleDisplayMode = .inline
            if let nav = navigationController {
                nav.navigationBar.prefersLargeTitles = false
            }
        }
        configureNavigationItems()
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

    private func resetInputState() {
        draftInputObject = nil
        clearPersistedDraft()
        chatInputView.resetValues()
        chatInputView.storage.removeAll()
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

    private func applyHeaderStateToTitleView() {
        navigationTitleView.agentTitle = headerState.agentName
        navigationTitleView.agentEmoji = headerState.agentEmoji ?? ""
        navigationTitleView.modelTitle = makeModelSubtitle(from: headerState)
        #if targetEnvironment(macCatalyst)
            updateCatalystTitleBarButtonText()
        #endif
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
        let leadingImage = UIImage.chatInputIcon(named: "users") ?? UIImage(systemName: "person.2")
        let symbolConfig = UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        applyTopBarButtonStyle(
            avatarButton,
            image: leadingImage,
            symbolConfiguration: symbolConfig,
            horizontalAlignment: .left,
            showsMenuAsPrimaryAction: false,
            isHidden: false
        )
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
        applyTopBarButtonStyle(
            menuButton,
            image: menuImage,
            symbolConfiguration: symbolConfig,
            horizontalAlignment: .right,
            showsMenuAsPrimaryAction: true,
            isHidden: false
        )

        topBarBackgroundView.addSubview(topBarBlurView)
        topBarBackgroundView.addSubview(topBarContentView)
        topBarContentView.addSubview(titleAvatarContainerView)
        titleAvatarContainerView.addSubview(avatarButton)
        topBarContentView.addSubview(navigationTitleView)
        topBarContentView.addSubview(menuButton)
    }

    private var usesCatalystTitlebarToolbar: Bool {
        #if targetEnvironment(macCatalyst)
            true
        #else
            false
        #endif
    }

    private func updateCatalystTitlebarToolbarIfNeeded() {
        #if targetEnvironment(macCatalyst)
            guard usesCatalystTitlebarToolbar,
                  let titlebar = view.window?.windowScene?.titlebar
            else {
                return
            }

            updateCatalystTitleBarButtonText()
            catalystTitlebarToolbarCoordinator.install(on: titlebar)
        #endif
    }

    #if targetEnvironment(macCatalyst)
        private func updateCatalystTitleBarButtonText() {
            let emoji = headerState.agentEmoji?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let name = headerState.agentName
            let base = emoji.isEmpty ? name : "\(emoji) \(name)"
            let model = headerState.modelName.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedModel = model.isEmpty ? "Not Selected" : model
            catalystTitleBarButtonItem.title = "\(base) \u{2022} \(resolvedModel)"
        }
    #endif

    private func applyTopBarButtonStyle(
        _ button: UIButton,
        image: UIImage?,
        symbolConfiguration: UIImage.SymbolConfiguration,
        horizontalAlignment: UIControl.ContentHorizontalAlignment,
        showsMenuAsPrimaryAction: Bool,
        isHidden: Bool
    ) {
        #if targetEnvironment(macCatalyst)
            applyCatalystMenuButtonStyle(button, image: image, symbolConfiguration: symbolConfiguration)
        #else
            button.setImage(image, for: .normal)
            button.setPreferredSymbolConfiguration(symbolConfiguration, forImageIn: .normal)
        #endif
        button.imageView?.contentMode = .scaleAspectFit
        button.adjustsImageWhenHighlighted = false
        button.tintColor = UIColor.secondaryLabel.withAlphaComponent(0.5)
        button.contentHorizontalAlignment = horizontalAlignment
        button.contentVerticalAlignment = .center
        button.showsMenuAsPrimaryAction = showsMenuAsPrimaryAction
        button.isHidden = isHidden
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

// MARK: - Chat Input

extension ChatViewController: ChatInputDelegate {
    public func chatInputDidSubmit(_: ChatInputView, object: ChatInputContent, completion: @escaping @Sendable (Bool) -> Void) {
        guard let session = messageListView.session, let model = session.models.chat else {
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
