//
//  MessageListView.swift
//  ChatUI
//
//  High-performance message list using ListViewKit.
//  Adapted from FlowDown's MessageListView.
//

import ListViewKit
import Litext
import MarkdownView
import SnapKit
import UIKit

public final class MessageListView: UIView {
    private lazy var listView: ListViewKit.ListView = .init()
    private var renderedMessages: [ConversationMessage] = []
    private var loadingMessage: String?
    private var lastRenderScrolling = false
    var expandedSubAgentMessageIDs: Set<String> = []

    public var contentSize: CGSize {
        listView.contentSize
    }

    lazy var dataSource: ListViewDiffableDataSource<Entry> = .init(listView: listView)

    private var entryCount = 0
    private var isFirstLoad: Bool = true
    private let autoScrollTolerance: CGFloat = 2

    public var onRollbackUserQuery: ((String, String) -> Void)?
    public var onPartialCompact: ((String, PartialCompactDirection) -> Void)?
    public var onToggleReasoningCollapse: ((String) -> Void)?
    public var onToggleToolResultCollapse: ((String, String) -> Void)?
    public var onRetryInterruptedMessageSubmission: (() -> Void)?
    public var isRetryingInterruptedSubmission = false {
        didSet {
            guard oldValue != isRetryingInterruptedSubmission else { return }
            updateFromUpstreamPublisher(renderedMessages, lastRenderScrolling, isLoading: loadingMessage)
        }
    }

    public var showsInterruptedRetryAction = false {
        didSet {
            if !showsInterruptedRetryAction {
                isRetryingInterruptedSubmission = false
            }
            guard oldValue != showsInterruptedRetryAction else { return }
            updateFromUpstreamPublisher(renderedMessages, lastRenderScrolling, isLoading: loadingMessage)
        }
    }

    private var isAutoScrollingToBottom: Bool = true

    public var contentSafeAreaInsets: UIEdgeInsets = .zero {
        didSet { setNeedsLayout() }
    }

    static let listRowInsets: UIEdgeInsets = .init(top: 0, left: 20, bottom: 16, right: 20)

    public var theme: MarkdownTheme = .default {
        didSet { listView.reloadData() }
    }

    public var emptyStateTitle: String? {
        get { emptyStateView.title }
        set { emptyStateView.title = newValue }
    }

    public var emptyStateSubtitle: String? {
        get { emptyStateView.subtitle }
        set { emptyStateView.subtitle = newValue }
    }

    private(set) lazy var labelForSizeCalculation: LTXLabel = .init()
    private(set) lazy var markdownViewForSizeCalculation: MarkdownTextView = .init()
    private(set) lazy var markdownPackageCache: MarkdownPackageCache = .init()

    private lazy var emptyStateView = ChatEmptyStateView()

    public init() {
        super.init(frame: .zero)

        listView.delegate = self
        listView.adapter = self
        listView.alwaysBounceVertical = true
        listView.alwaysBounceHorizontal = false
        listView.contentInsetAdjustmentBehavior = .never
        listView.showsVerticalScrollIndicator = false
        listView.showsHorizontalScrollIndicator = false
        addSubview(listView)
        listView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        addSubview(emptyStateView)
        emptyStateView.snp.makeConstraints { make in
            make.center.equalToSuperview()
            make.leading.trailing.equalToSuperview()
        }
        emptyStateView.isHidden = true

        listView.gestureRecognizers?.forEach {
            guard $0 is UIPanGestureRecognizer else { return }
            $0.cancelsTouchesInView = false
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }

    override public func layoutSubviews() {
        let wasNearBottom = isContentOffsetNearBottom()
        super.layoutSubviews()

        listView.contentInset = contentSafeAreaInsets

        if isAutoScrollingToBottom || wasNearBottom {
            let targetOffset = listView.maximumContentOffset
            if abs(listView.contentOffset.y - targetOffset.y) > autoScrollTolerance {
                listView.scroll(to: targetOffset)
            }
            if wasNearBottom {
                isAutoScrollingToBottom = true
            }
        }
    }

    private func updateAutoScrolling() {
        if isContentOffsetNearBottom() {
            isAutoScrollingToBottom = true
        }
    }

    private func isContentOffsetNearBottom(tolerance: CGFloat? = nil) -> Bool {
        let tolerance = tolerance ?? autoScrollTolerance
        return abs(listView.contentOffset.y - listView.maximumContentOffset.y) <= tolerance
    }

    public func prepareForNewSession() {
        renderedMessages = []
        loadingMessage = nil
        lastRenderScrolling = false
        expandedSubAgentMessageIDs.removeAll()
        isAutoScrollingToBottom = true
        isRetryingInterruptedSubmission = false
        showsInterruptedRetryAction = false
        isFirstLoad = true
        alpha = 0
        dataSource.applySnapshot(using: [], animatingDifferences: false)
    }

    public func markNextUpdateAsUserInitiated() {
        isAutoScrollingToBottom = true
    }

    public func render(messages: [ConversationMessage], scrolling: Bool) {
        renderedMessages = messages
        lastRenderScrolling = scrolling
        updateFromUpstreamPublisher(messages, scrolling, isLoading: loadingMessage)
    }

    public func loading(with message: String = .init()) {
        loadingMessage = message
        updateFromUpstreamPublisher(renderedMessages, lastRenderScrolling, isLoading: loadingMessage)
    }

    public func stopLoading() {
        loadingMessage = nil
        updateFromUpstreamPublisher(renderedMessages, lastRenderScrolling, isLoading: nil)
    }

    /// Render with fresh messages and clear loading state in a single pass.
    public func renderAndStopLoading(messages: [ConversationMessage], scrolling: Bool) {
        renderedMessages = messages
        lastRenderScrolling = scrolling
        loadingMessage = nil
        updateFromUpstreamPublisher(messages, scrolling, isLoading: nil)
    }

    func toggleSubAgentTaskExpansion(messageID: String) {
        if expandedSubAgentMessageIDs.contains(messageID) {
            expandedSubAgentMessageIDs.remove(messageID)
        } else {
            expandedSubAgentMessageIDs.insert(messageID)
        }
        updateFromUpstreamPublisher(renderedMessages, false, isLoading: loadingMessage)
    }

    private func updateFromUpstreamPublisher(_ messages: [ConversationMessage], _ scrolling: Bool, isLoading: String?) {
        var entries = entries(from: messages)

        for entry in entries {
            switch entry {
            case let .responseContent(_, messageRepresentation):
                _ = markdownPackageCache.package(for: messageRepresentation, theme: theme)
            default: break
            }
        }

        if let isLoading { entries.append(.activityReporting(isLoading)) }

        let shouldScrolling = scrolling && isAutoScrollingToBottom

        entryCount = entries.count

        let isListEmpty = entryCount == 0 && isLoading == nil
        emptyStateView.isHidden = !isListEmpty

        if isFirstLoad || alpha == 0 {
            isFirstLoad = false
            dataSource.applySnapshot(using: entries, animatingDifferences: false)
            listView.setContentOffset(.init(x: 0, y: listView.maximumContentOffset.y), animated: false)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                UIView.animate(withDuration: 0.25) { self.alpha = 1 }
            }
        } else {
            dataSource.applySnapshot(using: entries, animatingDifferences: true)
            if shouldScrolling {
                listView.scroll(to: listView.maximumContentOffset)
            }
        }
    }
}

extension MessageListView: UIScrollViewDelegate {
    public func scrollViewWillBeginDragging(_: UIScrollView) {
        isAutoScrollingToBottom = false
    }

    public func scrollViewDidEndDecelerating(_: UIScrollView) {
        updateAutoScrolling()
    }

    public func scrollViewDidEndDragging(_: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate {
            updateAutoScrolling()
        }
    }
}
