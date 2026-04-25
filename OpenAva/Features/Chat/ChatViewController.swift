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
            let titleBarButtonItem: UIBarButtonItem
            private var leadingImage: UIImage?
            private var leadingTitle = ""
            private var leadingMenu: UIMenu?
            private var trailingImage: UIImage?
            private var trailingTitle = ""
            private var trailingMenu: UIMenu?

            private var leadingToolbarItem: NSMenuToolbarItem?
            private var trailingToolbarItem: NSMenuToolbarItem?

            init(titleBarButtonItem: UIBarButtonItem) {
                self.titleBarButtonItem = titleBarButtonItem

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

            func uninstall(from titlebar: UITitlebar) {
                if titlebar.toolbar === toolbar {
                    titlebar.toolbar = nil
                }
            }

            func update(
                leadingImage: UIImage?,
                leadingTitle: String = "",
                leadingMenu: UIMenu?,
                trailingImage: UIImage?,
                trailingTitle: String = "",
                trailingMenu: UIMenu?
            ) {
                self.leadingImage = leadingImage
                self.leadingTitle = leadingTitle
                self.leadingMenu = leadingMenu
                self.trailingImage = trailingImage
                self.trailingTitle = trailingTitle
                self.trailingMenu = trailingMenu

                leadingToolbarItem?.image = leadingImage
                leadingToolbarItem?.title = leadingTitle
                if let leadingMenu {
                    leadingToolbarItem?.itemMenu = leadingMenu
                }

                trailingToolbarItem?.image = trailingImage
                trailingToolbarItem?.title = trailingTitle
                if let trailingMenu {
                    trailingToolbarItem?.itemMenu = trailingMenu
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
                    let item = NSMenuToolbarItem(itemIdentifier: Item.leading)
                    item.image = leadingImage
                    item.title = leadingTitle
                    if let leadingMenu {
                        item.itemMenu = leadingMenu
                    }
                    item.showsIndicator = false
                    leadingToolbarItem = item
                    return item
                case Item.title:
                    return NSToolbarItem(itemIdentifier: Item.title, barButtonItem: titleBarButtonItem)
                case Item.trailing:
                    let item = NSMenuToolbarItem(itemIdentifier: Item.trailing)
                    item.image = trailingImage
                    item.title = trailingTitle
                    if let trailingMenu {
                        item.itemMenu = trailingMenu
                    }
                    item.showsIndicator = false
                    trailingToolbarItem = item
                    return item
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
    public private(set) var conversationModels: ConversationSession.Models
    public private(set) var sessionConfiguration: ConversationSession.Configuration
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

    /// When non-nil, a side (macCatalyst) or top (iOS) pane is reserved for this host
    /// view and the chat list / input shrink to share the remaining space.
    private weak var embeddedWebHostView: UIView?

    /// Fraction of the split view occupied by the embedded web pane.
    /// 0.5 means 50% / 50%. Clamped to `splitRatioRange` when applied.
    private var splitRatio: CGFloat = 0.5
    private let splitRatioRange: ClosedRange<CGFloat> = 0.25 ... 0.75
    private static let splitterThickness: CGFloat = 6
    private static let splitterHitSlop: CGFloat = 4

    private lazy var splitterHandleView: SplitterHandleView = {
        let handle = SplitterHandleView()
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleSplitterPan(_:)))
        handle.addGestureRecognizer(pan)
        handle.isHidden = true
        return handle
    }()

    /// Captured at gesture start so the drag is computed against a stable origin.
    private var splitterDragStartRatio: CGFloat = 0.5

    /// Embed an external view (e.g. the web_view tool panel) alongside the chat.
    /// On macCatalyst / regular-width it takes the right half; otherwise the top half.
    /// Calling again with a different view replaces the previous one.
    public func embedSidePaneView(_ hostView: UIView) {
        if embeddedWebHostView === hostView { return }
        embeddedWebHostView?.removeFromSuperview()
        hostView.translatesAutoresizingMaskIntoConstraints = true
        view.addSubview(hostView)
        embeddedWebHostView = hostView
        // Ensure the splitter stays above both panes so it can always receive touches.
        if splitterHandleView.superview !== view {
            view.addSubview(splitterHandleView)
        } else {
            view.bringSubviewToFront(splitterHandleView)
        }
        splitterHandleView.isHidden = false
        view.setNeedsLayout()
        view.layoutIfNeeded()
    }

    /// Remove a previously embedded side pane. If `hostView` does not match the
    /// currently embedded one, does nothing.
    public func removeEmbeddedSidePaneView(_ hostView: UIView) {
        guard embeddedWebHostView === hostView else { return }
        hostView.removeFromSuperview()
        embeddedWebHostView = nil
        splitterHandleView.isHidden = true
        view.setNeedsLayout()
        view.layoutIfNeeded()
    }

    private lazy var avatarButton: UIButton = .init(type: .system)
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
    private var providedSession: ConversationSession?
    var promptSubmissionHandler: ConversationPromptSubmissionHandler?

    private lazy var titleBarButtonItem = UIBarButtonItem(title: "", style: .plain, target: self, action: #selector(handleTitleTap))

    private static func toolbarIcon(_ name: String, fallback: String) -> UIImage? {
        let base = UIImage.chatInputIcon(named: name) ?? UIImage(systemName: fallback)
        let targetSize = CGSize(width: 18, height: 18)
        guard let base, base.size.width > targetSize.width else { return base }
        let renderer = UIGraphicsImageRenderer(size: targetSize)
        return renderer.image { _ in base.draw(in: CGRect(origin: .zero, size: targetSize)) }
            .withRenderingMode(.alwaysTemplate)
    }

    #if targetEnvironment(macCatalyst)
        private lazy var catalystTitlebarToolbarCoordinator = CatalystTitlebarToolbarCoordinator(
            titleBarButtonItem: titleBarButtonItem
        )
    #endif

    /// When set, the input draft is persisted to UserDefaults under this key so it survives
    /// app restarts. Should be unique per agent to isolate drafts between agents.
    public var draftPersistenceKey: String?

    private static let draftDefaultsPrefix = "chat.inputDraft."

    private func setPromptInputExecuting(_ isExecuting: Bool) {
        guard isViewLoaded else { return }
        logger.notice(
            "ui query activity changed session=\(self.sessionID, privacy: .public) active=\(String(isExecuting), privacy: .public)"
        )
        chatInputView.setExecuting(isExecuting)
    }

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

    public convenience init(
        session: ConversationSession,
        sessionID: String,
        models: ConversationSession.Models = .init(),
        sessionConfiguration: ConversationSession.Configuration = .init(storage: DisposableStorageProvider.shared),
        configuration: Configuration
    ) {
        self.init(
            sessionID: sessionID,
            models: models,
            sessionConfiguration: sessionConfiguration,
            configuration: configuration
        )
        providedSession = session
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

        view.addSubview(messageListView)
        view.addSubview(chatInputView)
        messageListView.addGestureRecognizer(dismissKeyboardTapGesture)
        messageListView.theme = configuration.messageTheme

        configureSession(for: sessionID)
        chatInputView.delegate = self
        chatInputView.bind(sessionID: sessionID)
        configureNavigationItems()
        applyHeaderStateToNavigationTitle()

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
        guard view.bounds.width > 0, view.bounds.height > 0 else { return }

        let safeArea = view.safeAreaInsets
        let inputHeight = chatInputView.heightPublisher.value
        let bottomPadding = max(safeArea.bottom, 0)
        let idleBottomSpacingReduction = keyboardHeight == 0 ? min(chatInputView.idleBottomSpacingReduction, bottomPadding) : 0
        let inputExtension = bottomPadding - idleBottomSpacingReduction
        let totalInputHeight = inputHeight + inputExtension

        chatInputView.bottomBackgroundExtension = inputExtension

        // Split the chat view between the chat column and an optional side/top pane
        // reserved for the embedded web view tool.
        let chatColumn: CGRect
        if let host = embeddedWebHostView {
            #if targetEnvironment(macCatalyst)
                let usesHorizontalSplit = true
            #else
                let usesHorizontalSplit = traitCollection.horizontalSizeClass == .regular
            #endif

            let clampedRatio = min(max(splitRatio, splitRatioRange.lowerBound), splitRatioRange.upperBound)
            let thickness = Self.splitterThickness
            let hitSlop = Self.splitterHitSlop

            if usesHorizontalSplit {
                // Mac / regular width: chat on the left, web pane on the right.
                let paneWidth = (view.bounds.width * clampedRatio).rounded()
                let chatWidth = view.bounds.width - paneWidth
                host.frame = CGRect(
                    x: chatWidth,
                    y: 0,
                    width: paneWidth,
                    height: view.bounds.height
                )
                chatColumn = CGRect(
                    x: 0,
                    y: 0,
                    width: chatWidth,
                    height: view.bounds.height
                )
                splitterHandleView.axis = .vertical
                splitterHandleView.frame = CGRect(
                    x: chatWidth - thickness / 2 - hitSlop,
                    y: 0,
                    width: thickness + hitSlop * 2,
                    height: view.bounds.height
                )
            } else {
                // iOS compact: web pane on top, chat on the bottom.
                let paneTopInset = safeArea.top
                let splitArea = view.bounds.height - paneTopInset
                let paneHeight = (paneTopInset + splitArea * clampedRatio).rounded()
                host.frame = CGRect(
                    x: 0,
                    y: 0,
                    width: view.bounds.width,
                    height: paneHeight
                )
                chatColumn = CGRect(
                    x: 0,
                    y: paneHeight,
                    width: view.bounds.width,
                    height: view.bounds.height - paneHeight
                )
                splitterHandleView.axis = .horizontal
                splitterHandleView.frame = CGRect(
                    x: 0,
                    y: paneHeight - thickness / 2 - hitSlop,
                    width: view.bounds.width,
                    height: thickness + hitSlop * 2
                )
            }

            view.bringSubviewToFront(splitterHandleView)
        } else {
            chatColumn = view.bounds
        }

        let inputY = chatColumn.maxY - totalInputHeight - keyboardHeight
        chatInputView.frame = CGRect(
            x: chatColumn.minX,
            y: max(inputY, chatColumn.minY + safeArea.top),
            width: chatColumn.width,
            height: totalInputHeight
        )

        let listTop: CGFloat
        if embeddedWebHostView != nil, chatColumn.minY > 0 {
            // iOS top/bottom mode: chat list starts right below the web pane.
            listTop = chatColumn.minY
        } else {
            listTop = 0
        }

        let keyboardOverlap = keyboardHeight > 0 ? keyboardHeight + safeArea.bottom : 0
        messageListView.frame = CGRect(
            x: chatColumn.minX,
            y: listTop,
            width: chatColumn.width,
            height: chatColumn.height - keyboardOverlap
        )
        let listSafeTop = chatColumn.minY == 0 ? safeArea.top : 0
        let bottomInset = keyboardHeight > 0 ? inputHeight : totalInputHeight
        messageListView.contentSafeAreaInsets = UIEdgeInsets(top: listSafeTop, left: 0, bottom: bottomInset, right: 0)
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

    @objc private func handleSplitterPan(_ recognizer: UIPanGestureRecognizer) {
        guard embeddedWebHostView != nil else { return }

        #if targetEnvironment(macCatalyst)
            let usesHorizontalSplit = true
        #else
            let usesHorizontalSplit = traitCollection.horizontalSizeClass == .regular
        #endif

        switch recognizer.state {
        case .began:
            splitterDragStartRatio = splitRatio
        case .changed, .ended:
            let translation = recognizer.translation(in: view)
            let availableLength: CGFloat
            let delta: CGFloat
            if usesHorizontalSplit {
                availableLength = view.bounds.width
                // Drag left -> webview (right pane) grows, so negate x translation.
                delta = -translation.x
            } else {
                let topInset = view.safeAreaInsets.top
                availableLength = max(1, view.bounds.height - topInset)
                // Drag down -> webview (top pane) grows.
                delta = translation.y
            }
            guard availableLength > 0 else { return }
            let proposed = splitterDragStartRatio + delta / availableLength
            let clamped = min(max(proposed, splitRatioRange.lowerBound), splitRatioRange.upperBound)
            if clamped != splitRatio {
                splitRatio = clamped
                view.setNeedsLayout()
                view.layoutIfNeeded()
            }
        default:
            break
        }
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
            let publishers = [
                NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification),
                NotificationCenter.default.publisher(for: NSNotification.Name("NSApplicationDidBecomeActiveNotification")),
            ]
            Publishers.MergeMany(publishers)
                .sink { [weak self] _ in
                    guard let self else { return }
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.isViewLoaded else { return }
                        self.keyboardHeight = 0

                        self.chatInputView.setNeedsLayout()
                        self.chatInputView.layoutIfNeeded()
                        self.chatInputView.setNeedsDisplay()

                        self.messageListView.setNeedsLayout()
                        self.messageListView.layoutIfNeeded()
                        self.messageListView.setNeedsDisplay()

                        self.view.setNeedsLayout()
                        self.view.layoutIfNeeded()
                        self.view.setNeedsDisplay()

                        self.layoutViews()
                        self.updateCatalystTitlebarToolbarIfNeeded()
                    }
                }
                .store(in: &cancellables)
        #endif
    }

    private func configureNavigationItems() {
        configureLeadingMenuButton()

        let trailingImage = Self.toolbarIcon("menu", fallback: "ellipsis")
        let trailingMenu = menuDelegate?.chatViewControllerMenu(self)
        let trailingNavigationItem = UIBarButtonItem(image: trailingImage, style: .plain, target: nil, action: nil)
        trailingNavigationItem.menu = trailingMenu

        chatInputView.modelButtonMenu = menuDelegate?.chatViewControllerModelMenu(self)
        chatInputView.selectedModelName = headerState.modelName

        let item = navigationItem
        item.leftBarButtonItem = UIBarButtonItem(customView: avatarButton)
        item.rightBarButtonItem = trailingNavigationItem
        updateCatalystTitlebarToolbarIfNeeded()

        if isViewLoaded {
            view.setNeedsLayout()
        }
    }

    private func bindNavigationTitleUpdates(session: ConversationSession) {
        sessionCancellables.removeAll()
        setPromptInputExecuting(session.isQueryActive)
        session.queryActivityDidChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak session] isActive in
                guard let self, let session else { return }
                guard self.currentSession === session else { return }
                self.setPromptInputExecuting(isActive)
                if isActive {
                    self.messageListView.isRetryingInterruptedSubmission = false
                }
            }
            .store(in: &sessionCancellables)
        session.messagesDidChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] messages, scrolling in
                self?.messageListView.showsInterruptedRetryAction = session.showsInterruptedRetryAction
                self?.messageListView.render(messages: messages, scrolling: scrolling)
                self?.scheduleContextUsageRefresh()
            }
            .store(in: &sessionCancellables)
        session.loadingStateDidChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard let self else { return }
                if let status {
                    self.messageListView.loading(with: status)
                } else {
                    self.messageListView.stopLoading()
                }
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
    public func updateConversationRuntime(
        sessionID: String,
        providedSession: ConversationSession?,
        models: ConversationSession.Models,
        sessionConfiguration: ConversationSession.Configuration
    ) {
        let previousSessionID = self.sessionID
        self.providedSession = providedSession
        conversationModels = models
        self.sessionConfiguration = sessionConfiguration
        configureSession(for: sessionID, resetMessageList: false)
        if previousSessionID != sessionID {
            chatInputView.bind(sessionID: sessionID)
        }
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
        try await session.compactConversation(model: model)
        scheduleContextUsageRefresh()
    }

    @MainActor
    public func performPartialCompact(
        around messageID: String,
        direction: PartialCompactDirection
    ) async throws {
        guard let session = currentSession, let model = session.models.chat else { return }
        try await session.partialCompactConversation(around: messageID, direction: direction, model: model)
        scheduleContextUsageRefresh()
    }

    @MainActor
    public func quickSettingAnchorView(forCommand command: String) -> UIView? {
        chatInputView.quickSettingButton(forCommand: command)
    }

    private func configureSession(for id: String, resetMessageList: Bool = true) {
        sessionID = id
        let session = providedSession ?? ConversationSessionManager.shared.session(for: id, configuration: sessionConfiguration)
        applyConversationModels(conversationModels, to: session)
        currentSession = session
        setPromptInputExecuting(session.isQueryActive)
        if resetMessageList {
            messageListView.prepareForNewSession()
        }
        messageListView.onToggleReasoningCollapse = { [weak self] messageID in
            self?.currentSession?.toggleReasoningCollapse(for: messageID)
        }
        messageListView.onToggleToolResultCollapse = { [weak self] messageID, toolCallID in
            self?.currentSession?.toggleToolResultCollapse(for: messageID, toolCallID: toolCallID)
        }
        messageListView.onRetryInterruptedMessageSubmission = { [weak self] in
            guard let self, let session = self.currentSession else { return }
            let accepted = session.retryInterruptedPromptSubmission()
            if !accepted {
                self.messageListView.isRetryingInterruptedSubmission = false
            }
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
        messageListView.onPartialCompact = { [weak self] messageID, direction in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try await self.performPartialCompact(around: messageID, direction: direction)
                } catch {
                    self.presentPartialCompactError(error)
                }
            }
        }
        bindNavigationTitleUpdates(session: session)
    }

    private func presentPartialCompactError(_ error: Error) {
        let alert = UIAlertController(
            title: String.localized("Error"),
            message: error.localizedDescription,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: String.localized("OK"), style: .default))
        present(alert, animated: true)
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
        applyHeaderStateToNavigationTitle()
        chatInputView.selectedModelName = headerState.modelName
    }

    public func refreshNavigationMenus() {
        configureNavigationItems()
    }

    private func applyHeaderStateToNavigationTitle() {
        let title = ChatTopBar.title(
            agentName: headerState.agentName,
            agentEmoji: headerState.agentEmoji,
            modelName: headerState.modelName
        ).principalTitleText

        navigationItem.title = title
        titleBarButtonItem.title = title
        if isViewLoaded {
            view.setNeedsLayout()
        }
    }

    @objc private func handleTitleTap() {
        menuDelegate?.chatViewControllerDidTapModelTitle(self)
    }

    public var showsSystemTopBar: Bool = true {
        didSet {
            guard oldValue != showsSystemTopBar else { return }
            updateCatalystTitlebarToolbarIfNeeded()
        }
    }

    private func updateCatalystTitlebarToolbarIfNeeded() {
        #if targetEnvironment(macCatalyst)
            catalystTitlebarToolbarCoordinator.update(
                leadingImage: resolvedButtonImage(from: avatarButton),
                leadingMenu: avatarButton.menu,
                trailingImage: Self.toolbarIcon("menu", fallback: "ellipsis"),
                trailingMenu: menuDelegate?.chatViewControllerMenu(self)
            )
            guard let titlebar = view.window?.windowScene?.titlebar else { return }
            if showsSystemTopBar {
                catalystTitlebarToolbarCoordinator.install(on: titlebar)
            } else {
                catalystTitlebarToolbarCoordinator.uninstall(from: titlebar)
            }
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
        handlePromptSubmit(
            session: currentSession,
            object: object,
            messageListView: messageListView,
            promptSubmissionHandler: promptSubmissionHandler,
            clearDraft: { [weak self] in
                self?.draftInputObject = nil
                self?.clearPersistedDraft()
            },
            completion: completion
        )
    }

    public func chatInputDidRequestStop(_: ChatInputView) {
        handlePromptStop(session: currentSession, fallbackSessionID: sessionID)
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

/// Thin draggable handle drawn between the chat column and the embedded web pane.
/// The hit area is padded with slop so the visible line stays narrow.
private final class SplitterHandleView: UIView {
    enum Axis { case vertical, horizontal }

    var axis: Axis = .vertical {
        didSet {
            guard axis != oldValue else { return }
            setNeedsLayout()
            updatePointerInteraction()
        }
    }

    private let lineView = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        lineView.backgroundColor = .clear
        lineView.isUserInteractionEnabled = false
        addSubview(lineView)
        updatePointerInteraction()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let lineThickness: CGFloat = 1
        switch axis {
        case .vertical:
            lineView.frame = CGRect(
                x: (bounds.width - lineThickness) / 2,
                y: 0,
                width: lineThickness,
                height: bounds.height
            )
        case .horizontal:
            lineView.frame = CGRect(
                x: 0,
                y: (bounds.height - lineThickness) / 2,
                width: bounds.width,
                height: lineThickness
            )
        }
    }

    private func updatePointerInteraction() {
        #if targetEnvironment(macCatalyst)
            if interactions.contains(where: { $0 is UIPointerInteraction }) == false {
                addInteraction(UIPointerInteraction(delegate: self))
            }
        #endif
    }
}

#if targetEnvironment(macCatalyst)
    extension SplitterHandleView: UIPointerInteractionDelegate {
        func pointerInteraction(_: UIPointerInteraction, styleFor _: UIPointerRegion) -> UIPointerStyle? {
            // Use a lift/highlight effect; iPadOS/Catalyst does not expose a native
            // resize cursor through UIPointerStyle, so a subtle visual cue is the
            // best we can do without private APIs.
            let shape = UIPointerShape.roundedRect(bounds, radius: 2)
            return UIPointerStyle(shape: shape, constrainedAxes: axis == .vertical ? .vertical : .horizontal)
        }
    }
#endif
