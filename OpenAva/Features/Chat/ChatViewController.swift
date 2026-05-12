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

private let chatInputLogger = Logger(subsystem: "com.day1-labs.openava", category: "chat.input")

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

            private struct MenuItemState {
                var image: UIImage?
                var title: String
                var menu: UIMenu?

                func apply(to item: NSMenuToolbarItem?) {
                    item?.image = image
                    item?.title = title
                    if let menu {
                        item?.itemMenu = menu
                    }
                }
            }

            private let toolbar = NSToolbar(identifier: "openava.chat.titlebar")
            let titleBarButtonItem: UIBarButtonItem
            private var leadingState = MenuItemState(image: nil, title: "", menu: nil)
            private var trailingState = MenuItemState(image: nil, title: "", menu: nil)

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
                leadingState = MenuItemState(image: leadingImage, title: leadingTitle, menu: leadingMenu)
                trailingState = MenuItemState(image: trailingImage, title: trailingTitle, menu: trailingMenu)

                leadingState.apply(to: leadingToolbarItem)
                trailingState.apply(to: trailingToolbarItem)
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
                    let item = makeMenuToolbarItem(identifier: Item.leading, state: leadingState)
                    leadingToolbarItem = item
                    return item
                case Item.title:
                    return NSToolbarItem(itemIdentifier: Item.title, barButtonItem: titleBarButtonItem)
                case Item.trailing:
                    let item = makeMenuToolbarItem(identifier: Item.trailing, state: trailingState)
                    trailingToolbarItem = item
                    return item
                default:
                    return nil
                }
            }

            private func makeMenuToolbarItem(
                identifier: NSToolbarItem.Identifier,
                state: MenuItemState
            ) -> NSMenuToolbarItem {
                let item = NSMenuToolbarItem(itemIdentifier: identifier)
                state.apply(to: item)
                item.showsIndicator = false
                return item
            }
        }
    #endif

    private enum QuickCommand {
        static let contextUsage = "/context"
    }

    public struct HeaderState: Equatable {
        public var agentName: String
        public var agentEmoji: String?
        public var agentAvatarImage: UIImage?
        public var agentAvatarImageID: String?
        public var agentAvatarRemoteURL: URL?
        public var agentAvatarPersistURL: URL?
        public var modelName: String
        public var providerName: String?
        public var teamMemberCount: Int?

        public init(
            agentName: String,
            agentEmoji: String? = nil,
            agentAvatarImage: UIImage? = nil,
            agentAvatarImageID: String? = nil,
            agentAvatarRemoteURL: URL? = nil,
            agentAvatarPersistURL: URL? = nil,
            modelName: String,
            providerName: String? = nil,
            teamMemberCount: Int? = nil
        ) {
            self.agentName = agentName
            self.agentEmoji = agentEmoji
            self.agentAvatarImage = agentAvatarImage
            self.agentAvatarImageID = agentAvatarImageID
            self.agentAvatarRemoteURL = agentAvatarRemoteURL
            self.agentAvatarPersistURL = agentAvatarPersistURL
            self.modelName = modelName
            self.providerName = providerName
            self.teamMemberCount = teamMemberCount
        }

        public static func == (lhs: HeaderState, rhs: HeaderState) -> Bool {
            lhs.agentName == rhs.agentName &&
                lhs.agentEmoji == rhs.agentEmoji &&
                lhs.agentAvatarImageID == rhs.agentAvatarImageID &&
                lhs.agentAvatarRemoteURL == rhs.agentAvatarRemoteURL &&
                lhs.agentAvatarPersistURL == rhs.agentAvatarPersistURL &&
                lhs.modelName == rhs.modelName &&
                lhs.providerName == rhs.providerName &&
                lhs.teamMemberCount == rhs.teamMemberCount
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
    private var lastLoggedPromptInputExecuting: Bool?
    public weak var menuDelegate: ChatViewControllerMenuDelegate? {
        didSet {
            guard isViewLoaded else { return }
            configureNavigationItems()
        }
    }

    /// When non-nil, a side (macCatalyst) or top (iOS) pane is reserved for this host
    /// view and the chat list / input shrink to share the remaining space.
    private weak var embeddedWebHostView: UIView?
    private var embeddedDocumentPreviewController: ChatWorkspaceDocumentPreviewController?

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
    private var headerState: HeaderState = .init(agentName: "Assistant", agentEmoji: nil, modelName: "Not Selected", providerName: nil, teamMemberCount: nil)
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
    private var presentedToolPermissionRequestID: String?

    private var draftInputObject: ChatInputContent?
    private var providedSession: ConversationSession?
    var promptSubmissionHandler: ConversationPromptSubmissionHandler?

    private lazy var titleBarButtonItem = UIBarButtonItem(title: "", style: .plain, target: self, action: #selector(handleTitleTap))

    private let titleAvatarImageView: UIImageView = {
        let view = UIImageView()
        view.contentMode = .scaleAspectFill
        view.clipsToBounds = true
        view.layer.cornerRadius = 11
        view.isHidden = true
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: 22),
            view.heightAnchor.constraint(equalToConstant: 22),
        ])
        return view
    }()

    private let titleLabel: UILabel = {
        let label = UILabel()
        label.font = .systemFont(ofSize: 16, weight: .semibold)
        return label
    }()

    private let titleSubtitleLabel: UILabel = {
        let label = UILabel()
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabel
        return label
    }()

    private lazy var customTitleView: UIStackView = {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 2

        let titleHStack = UIStackView()
        titleHStack.axis = .horizontal
        titleHStack.alignment = .center
        titleHStack.spacing = 6

        let chevronImageView = UIImageView()
        chevronImageView.image = UIImage(systemName: "chevron.down")?.withConfiguration(UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
        chevronImageView.tintColor = ChatUIDesign.Color.black60
        chevronImageView.contentMode = .scaleAspectFit

        titleHStack.addArrangedSubview(titleAvatarImageView)
        titleHStack.addArrangedSubview(titleLabel)
        titleHStack.addArrangedSubview(chevronImageView)

        stack.addArrangedSubview(titleHStack)
        stack.addArrangedSubview(titleSubtitleLabel)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTitleTap))
        stack.addGestureRecognizer(tap)
        stack.isUserInteractionEnabled = true

        return stack
    }()

    #if targetEnvironment(macCatalyst)
        private lazy var catalystTitlebarToolbarCoordinator = CatalystTitlebarToolbarCoordinator(
            titleBarButtonItem: titleBarButtonItem
        )
    #endif

    public struct EmptyStateContent: Equatable {
        public var title: String?
        public var subtitle: String?

        public init(title: String?, subtitle: String?) {
            self.title = title
            self.subtitle = subtitle
        }
    }

    /// Explicit empty-state copy shown when the chat has no messages.
    /// When unset, the controller falls back to a personal greeting.
    public var emptyStateContent: EmptyStateContent? {
        didSet { applyEmptyStateContent() }
    }

    /// Preferred user-facing name for the empty chat greeting.
    /// Falls back to the current system user name when unset or blank.
    public var emptyStateUserName: String? {
        didSet { applyEmptyStateContent() }
    }

    /// When set, the input draft is persisted to UserDefaults under this key so it survives
    /// app restarts. Should be unique per agent to isolate drafts between agents.
    public var draftPersistenceKey: String?

    private static let draftDefaultsPrefix = "chat.inputDraft."

    private func setPromptInputExecuting(_ isExecuting: Bool) {
        guard isViewLoaded else { return }
        if lastLoggedPromptInputExecuting != isExecuting {
            chatInputLogger.debug(
                "prompt input execution state changed session=\(self.sessionID, privacy: .public) isExecuting=\(String(isExecuting), privacy: .public)"
            )
            lastLoggedPromptInputExecuting = isExecuting
        }
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

    private func applyEmptyStateContent() {
        if let emptyStateContent {
            messageListView.emptyStateTitle = emptyStateContent.title
            messageListView.emptyStateSubtitle = emptyStateContent.subtitle
            return
        }

        let preferredName = emptyStateUserName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let fallbackName = NSUserName().trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = preferredName.isEmpty ? fallbackName : preferredName
        messageListView.emptyStateTitle = "Hi, \(resolvedName.isEmpty ? "there" : resolvedName)"
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
        applyEmptyStateContent()

        configureSession(for: sessionID)
        chatInputView.delegate = self
        chatInputView.bind(sessionID: sessionID)
        configureNavigationItems()
        applyHeaderStateToNavigationTitle()

        setupKeyboardObservation()
        setupInputHeightObservation()
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

    private func configureNavigationItems() {
        configureLeadingMenuButton()

        let trailingImage = UIImage(systemName: ChatTopBar.trailingMenuSystemImage)
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
        session.pendingToolPermissionsDidChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak session] requests in
                guard let self, let session else { return }
                guard self.currentSession === session else { return }
                self.presentNextToolPermissionRequestIfNeeded(requests, session: session)
            }
            .store(in: &sessionCancellables)
        presentNextToolPermissionRequestIfNeeded(session.pendingToolPermissionRequests, session: session)
        session.usageDidChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.scheduleContextUsageRefresh()
            }
            .store(in: &sessionCancellables)
        scheduleContextUsageRefresh()
    }

    private func presentNextToolPermissionRequestIfNeeded(
        _ requests: [ConversationSession.PendingToolPermissionRequest],
        session: ConversationSession
    ) {
        guard isViewLoaded, currentSession === session else { return }
        guard let request = requests.first else {
            presentedToolPermissionRequestID = nil
            return
        }
        guard presentedToolPermissionRequestID == nil else { return }
        guard presentedViewController == nil else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self, weak session] in
                guard let self, let session, self.currentSession === session else { return }
                self.presentNextToolPermissionRequestIfNeeded(session.pendingToolPermissionRequests, session: session)
            }
            return
        }

        presentedToolPermissionRequestID = request.id

        let message = request.message ?? ""
        let apiName = request.apiName
        let formattedArguments = formattedToolPermissionArguments(request.arguments)

        let controller = ChatToolPermissionViewController(
            toolName: request.toolName,
            message: message,
            apiName: apiName,
            argumentsText: formattedArguments
        )

        controller.delegate = self

        // Save request for delegate callback
        self.activeToolPermissionRequest = request

        present(controller, animated: true)
    }

    private var activeToolPermissionRequest: ConversationSession.PendingToolPermissionRequest?

    private func finishPresentedToolPermissionRequest(
        session: ConversationSession,
        resolve: () -> Void
    ) {
        presentedToolPermissionRequestID = nil
        activeToolPermissionRequest = nil
        resolve()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self, weak session] in
            guard let self, let session, self.currentSession === session else { return }
            self.presentNextToolPermissionRequestIfNeeded(session.pendingToolPermissionRequests, session: session)
        }
    }

    private func formattedToolPermissionArguments(_ arguments: String) -> String? {
        guard let data = arguments.data(using: .utf8) else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            let trimmed = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        guard JSONSerialization.isValidJSONObject(object),
              let prettyData = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let prettyText = String(data: prettyData, encoding: .utf8)
        else {
            return nil
        }
        return prettyText
    }

    /// Updates `autoCompactEnabled` on the active session's chat model without recreating the session.
    public func updateAutoCompactEnabled(_ enabled: Bool) {
        currentSession?.models.chat?.autoCompactEnabled = enabled
        scheduleContextUsageRefresh()
    }

    var currentToolPermissionMode: ToolPermissionMode {
        currentSession?.toolPermissionMode ?? .default
    }

    func updateToolPermissionMode(_ mode: ToolPermissionMode) {
        currentSession?.setToolPermissionMode(mode)
        updateToolPermissionPresentation()
    }

    private func updateToolPermissionPresentation() {
        chatInputView.updatePermissionPresentation(toolPermissionPresentation(for: currentToolPermissionMode))
    }

    private func toolPermissionPresentation(for mode: ToolPermissionMode) -> ChatInputPermissionPresentation {
        switch mode {
        case .default:
            return ChatInputPermissionPresentation(title: L10n.tr("chat.permission.default"), systemImageName: "lock")
        case .auto:
            return ChatInputPermissionPresentation(title: L10n.tr("chat.permission.autoReview"), systemImageName: "shield.lefthalf.filled")
        case .bypassPermissions:
            return ChatInputPermissionPresentation(title: L10n.tr("chat.permission.fullAccess"), systemImageName: "lock.open")
        }
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
        updateToolPermissionPresentation()
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
        messageListView.onOpenAttachment = { [weak self] attachment in
            self?.openMessageAttachmentPreview(attachment) ?? false
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

    private func openMessageAttachmentPreview(_ attachment: ChatInputAttachment) -> Bool {
        guard attachment.type == .document else { return false }

        let resolvedURL = attachment.sourceFilePath.map { URL(fileURLWithPath: $0).standardizedFileURL }
        let resolvedExtension = resolvedURL?.pathExtension.lowercased()
            ?? URL(fileURLWithPath: attachment.storageFilename).pathExtension.lowercased()
        guard ["md", "markdown"].contains(resolvedExtension) else { return false }

        let title = attachment.name.isEmpty ? (resolvedURL?.lastPathComponent ?? attachment.storageFilename) : attachment.name
        presentWorkspaceDocumentPreview(
            title: title,
            fileURL: resolvedURL,
            fallbackText: attachment.textContent
        )
        return true
    }

    private func presentWorkspaceDocumentPreview(title: String, fileURL: URL?, fallbackText: String) {
        let controller = ChatWorkspaceDocumentPreviewController(
            title: title,
            fileURL: fileURL,
            fallbackText: fallbackText,
            theme: configuration.messageTheme
        )

        #if targetEnvironment(macCatalyst)
            dismissEmbeddedDocumentPreviewIfNeeded()
            controller.onCloseRequested = { [weak self, weak controller] in
                guard let self, let controller else { return }
                self.dismissEmbeddedDocumentPreview(controller)
            }
            addChild(controller)
            embedSidePaneView(controller.view)
            controller.didMove(toParent: self)
            embeddedDocumentPreviewController = controller
        #else
            controller.onCloseRequested = { [weak controller] in
                controller?.dismiss(animated: true)
            }
            controller.modalPresentationStyle = .formSheet
            controller.preferredContentSize = CGSize(width: 680, height: 760)
            present(controller, animated: true)
        #endif
    }

    private func dismissEmbeddedDocumentPreviewIfNeeded() {
        guard let controller = embeddedDocumentPreviewController else { return }
        dismissEmbeddedDocumentPreview(controller)
    }

    private func dismissEmbeddedDocumentPreview(_ controller: ChatWorkspaceDocumentPreviewController) {
        guard embeddedDocumentPreviewController === controller else { return }
        controller.willMove(toParent: nil)
        removeEmbeddedSidePaneView(controller.view)
        controller.removeFromParent()
        embeddedDocumentPreviewController = nil
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

        let presentation = snapshot.map { snapshot in
            ChatInputContextUsagePresentation(
                usedFraction: min(1, max(0, CGFloat(snapshot.usedPercentage) / 100)),
                accessibilityLabel: title
            )
        }
        chatInputView.updateContextUsagePresentation(presentation)
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
        messageListView.isTeamChat = (state.teamMemberCount != nil)
        applyHeaderStateToNavigationTitle()
        chatInputView.selectedModelName = headerState.modelName
    }

    public func refreshNavigationMenus() {
        configureNavigationItems()
    }

    /// Remote URL currently being fetched so we do not spawn duplicate downloads.
    private var inFlightAvatarRemoteURL: URL?

    private func applyHeaderStateToNavigationTitle() {
        let rawTitle = resolvedHeaderTitleText()

        applyHeaderTitleView(title: rawTitle)
        navigationItem.titleView = customTitleView
        applyTitleBarButtonItem(title: rawTitle)

        if isViewLoaded {
            view.setNeedsLayout()
        }

        downloadRemoteAvatarIfNeeded()
    }

    private func resolvedHeaderTitleText() -> String {
        // Treat a non-emoji avatar configuration as "prefers avatar" even if the
        // local bitmap has not arrived yet, so we never fall back to an emoji glyph.
        let prefersAvatar = headerState.agentAvatarImageID != nil
        let hasAvatar = headerState.agentAvatarImage != nil
        let title = ChatTopBar.Title(
            displayName: headerState.agentName,
            displayEmoji: (hasAvatar || prefersAvatar) ? nil : headerState.agentEmoji,
            identityKind: .agent
        )
        return (hasAvatar || prefersAvatar) ? title.resolvedDisplayName : title.principalDisplayText
    }

    private func applyHeaderTitleView(title: String) {
        titleLabel.text = title
        titleAvatarImageView.image = headerState.agentAvatarImage
        titleAvatarImageView.isHidden = headerState.agentAvatarImage == nil

        if let count = headerState.teamMemberCount, count > 0 {
            titleSubtitleLabel.text = "\(count) Members Online"
            titleSubtitleLabel.isHidden = false
        } else {
            titleSubtitleLabel.isHidden = true
        }
    }

    private func applyTitleBarButtonItem(title: String) {
        #if targetEnvironment(macCatalyst)
            // Render the whole title area (avatar + name + chevron) into a single
            // image so the SF Symbol chevron renders with the correct font and we
            // avoid the PUA glyph tofu that NSToolbarItem shows for unicode arrows.
            let composed = composeCatalystTitleImage(
                avatar: headerState.agentAvatarImage,
                title: title
            )
            titleBarButtonItem.image = composed?.withRenderingMode(.alwaysOriginal)
            titleBarButtonItem.title = ""
        #else
            titleBarButtonItem.title = title
            titleBarButtonItem.image = headerState.agentAvatarImage?.withRenderingMode(.alwaysOriginal)
        #endif
    }

    /// Downloads a remote avatar (typically DiceBear) into `agentAvatarPersistURL`
    /// and re-applies the header once the bitmap is on disk.
    private func downloadRemoteAvatarIfNeeded() {
        guard headerState.agentAvatarImage == nil,
              let remoteURL = headerState.agentAvatarRemoteURL,
              let persistURL = headerState.agentAvatarPersistURL,
              inFlightAvatarRemoteURL != remoteURL
        else {
            return
        }
        inFlightAvatarRemoteURL = remoteURL

        URLSession.shared.dataTask(with: remoteURL) { [weak self] data, _, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.inFlightAvatarRemoteURL = nil
                guard let data, let image = UIImage(data: data) else { return }
                let folder = persistURL.deletingLastPathComponent()
                try? FileManager.default.createDirectory(
                    at: folder,
                    withIntermediateDirectories: true
                )
                try? data.write(to: persistURL, options: [.atomic])

                // Re-render the header with the now-available bitmap.
                self.headerState.agentAvatarImage = image
                self.applyHeaderStateToNavigationTitle()
                self.updateCatalystTitlebarToolbarIfNeeded()
            }
        }.resume()
    }

    #if targetEnvironment(macCatalyst)
        private func composeCatalystTitleImage(avatar: UIImage?, title: String) -> UIImage? {
            let avatarSize: CGFloat = 20
            let spacing: CGFloat = 6
            let font = UIFont.systemFont(ofSize: 14, weight: .semibold)
            let titleAttributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: UIColor.label,
            ]
            let titleSize = (title as NSString).size(withAttributes: titleAttributes)

            let chevronConfig = UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
            let chevron = UIImage(systemName: "chevron.down", withConfiguration: chevronConfig)?
                .withTintColor(ChatUIDesign.Color.black60, renderingMode: .alwaysOriginal)

            let avatarWidth: CGFloat = avatar != nil ? avatarSize + spacing : 0
            let chevronSize = chevron?.size ?? .zero
            let chevronWidth: CGFloat = chevron != nil ? chevronSize.width + spacing : 0
            let totalWidth = avatarWidth + titleSize.width + chevronWidth
            let totalHeight = max(avatarSize, max(titleSize.height, chevronSize.height))

            guard totalWidth > 0, totalHeight > 0 else { return nil }

            let renderer = UIGraphicsImageRenderer(size: CGSize(width: totalWidth, height: totalHeight))
            return renderer.image { context in
                var x: CGFloat = 0
                if let avatar {
                    let rect = CGRect(
                        x: x,
                        y: (totalHeight - avatarSize) / 2,
                        width: avatarSize,
                        height: avatarSize
                    )
                    context.cgContext.saveGState()
                    UIBezierPath(ovalIn: rect).addClip()
                    avatar.draw(in: rect)
                    context.cgContext.restoreGState()
                    x += avatarSize + spacing
                }
                let titleRect = CGRect(
                    x: x,
                    y: (totalHeight - titleSize.height) / 2,
                    width: titleSize.width,
                    height: titleSize.height
                )
                (title as NSString).draw(in: titleRect, withAttributes: titleAttributes)
                x += titleSize.width + spacing
                if let chevron {
                    let rect = CGRect(
                        x: x,
                        y: (totalHeight - chevronSize.height) / 2,
                        width: chevronSize.width,
                        height: chevronSize.height
                    )
                    chevron.draw(in: rect)
                }
            }
        }
    #endif

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
                trailingImage: UIImage(systemName: ChatTopBar.trailingMenuSystemImage),
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
        let image = UIImage(systemName: ChatTopBar.leadingMenuSystemImage)
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

extension ChatViewController: ChatToolPermissionViewControllerDelegate {
    func toolPermissionViewController(_ controller: ChatToolPermissionViewController, didSelectAction action: ChatToolPermissionViewController.Action) {
        controller.dismiss(animated: true) { [weak self] in
            guard let self = self,
                  let session = self.currentSession,
                  let request = self.activeToolPermissionRequest else { return }

            switch action {
            case .allowOnce:
                self.finishPresentedToolPermissionRequest(session: session) {
                    session.approveToolPermissionRequest(id: request.id)
                }
            case .alwaysAllowExact:
                self.finishPresentedToolPermissionRequest(session: session) {
                    session.addPersistedToolPermissionRule(
                        ToolPermissionRule(
                            behavior: .allow,
                            toolName: request.apiName,
                            matcher: .argumentsEqual(request.arguments)
                        )
                    )
                    session.approveToolPermissionRequest(id: request.id)
                }
            case .alwaysAllowTool:
                self.finishPresentedToolPermissionRequest(session: session) {
                    session.addPersistedToolPermissionRule(
                        self.persistedBroadAllowRule(for: request)
                    )
                    session.approveToolPermissionRequest(id: request.id)
                }
            case .deny:
                self.finishPresentedToolPermissionRequest(session: session) {
                    session.rejectToolPermissionRequest(id: request.id)
                }
            }
        }
    }

    private func persistedBroadAllowRule(for request: ConversationSession.PendingToolPermissionRequest) -> ToolPermissionRule {
        if request.apiName == "web_view",
           let origin = webViewOriginArgument(in: request.arguments)
        {
            return ToolPermissionRule(
                behavior: .allow,
                toolName: request.apiName,
                matcher: .urlOrigin(origin)
            )
        }

        return ToolPermissionRule(
            behavior: .allow,
            toolName: request.apiName,
            matcher: .tool
        )
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
