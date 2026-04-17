//
//  MessageListView+Adapter.swift
//  ChatUI
//

import ListViewKit
import Litext
import MarkdownView
import UIKit

private extension MessageListView {
    enum RowType {
        case userContent
        case userAttachment
        case reasoningContent
        case responseContent
        case mediaContent
        case hint
        case compactBoundary
        case toolCallHint
        case toolResultContent
        case chartContent
        case mapContent
        case interruptionRetry
        case activityReporting
    }
}

extension MessageListView: ListViewAdapter {
    private func compactConversationMenu(messageID: String) -> UIMenu {
        let upToTitle = String.localized("Compact Up to Here")
        let fromTitle = String.localized("Compact From Here")
        return UIMenu(
            title: String.localized("Compact Conversation"),
            image: UIImage(systemName: "rectangle.compress.vertical"),
            children: [
                UIAction(
                    title: upToTitle,
                    image: UIImage(systemName: "arrow.up.to.line.compact")
                ) { [weak self] _ in
                    self?.onPartialCompact?(messageID, .upTo)
                },
                UIAction(
                    title: fromTitle,
                    image: UIImage(systemName: "arrow.down.to.line.compact")
                ) { [weak self] _ in
                    self?.onPartialCompact?(messageID, .from)
                },
            ]
        )
    }

    private func entryForRow(at index: Int) -> Entry? {
        dataSource.snapshot().item(at: index)
    }

    public func listView(_: ListView, rowKindFor _: any Identifiable, at index: Int) -> any Hashable {
        guard let entry = entryForRow(at: index) else { return RowType.hint }
        return switch entry {
        case .userContent: RowType.userContent
        case .userAttachment: RowType.userAttachment
        case .reasoningContent: RowType.reasoningContent
        case .responseContent: RowType.responseContent
        case .mediaContent: RowType.mediaContent
        case .hint: RowType.hint
        case .compactBoundary: RowType.compactBoundary
        case .toolCallHint: RowType.toolCallHint
        case .toolResultContent: RowType.toolResultContent
        case .chartContent: RowType.chartContent
        case .mapContent: RowType.mapContent
        case .interruptionRetry: RowType.interruptionRetry
        case .activityReporting: RowType.activityReporting
        }
    }

    public func listViewMakeRow(for kind: any Hashable) -> ListRowView {
        guard let type = kind as? RowType else { return .init() }

        let view: MessageListRowView = switch type {
        case .userContent:
            UserMessageView()
        case .userAttachment:
            UserAttachmentView()
        case .reasoningContent:
            ReasoningContentView()
        case .responseContent:
            ResponseView()
        case .mediaContent:
            MediaMessageView()
        case .hint:
            HintMessageView()
        case .compactBoundary:
            CompactBoundaryMessageView()
        case .toolCallHint:
            ToolHintView()
        case .toolResultContent:
            ToolResultContentView()
        case .chartContent:
            ChartMessageView()
        case .mapContent:
            MapMessageView()
        case .interruptionRetry:
            RetryActionView()
        case .activityReporting:
            ActivityReportingView()
        }
        view.theme = theme
        return view
    }

    public func listView(_ listView: ListView, heightFor _: any Identifiable, at index: Int) -> CGFloat {
        guard let entry = entryForRow(at: index) else { return 0 }

        let listRowInsets = MessageListView.listRowInsets
        let containerWidth = max(0, listView.bounds.width - listRowInsets.horizontal)
        if containerWidth == 0 { return 0 }

        let bottomInset = listRowInsets.bottom
        let contentHeight: CGFloat = {
            switch entry {
            case let .userContent(_, message):
                let attributedContent = NSAttributedString(string: message.content, attributes: [
                    .font: theme.fonts.body,
                    .foregroundColor: theme.colors.body,
                ])
                let availableWidth = UserMessageView.availableTextWidth(for: containerWidth)
                return boundingSize(with: availableWidth, for: attributedContent).height + UserMessageView.textPadding * 2
            case .userAttachment:
                return AttachmentsBar.itemHeight
            case let .reasoningContent(_, message):
                let attributedContent = NSAttributedString(string: message.content, attributes: [
                    .font: theme.fonts.footnote,
                    .paragraphStyle: ReasoningContentView.paragraphStyle,
                ])
                if message.isRevealed {
                    return boundingSize(with: containerWidth - 16, for: attributedContent).height
                        + ReasoningContentView.spacing
                        + ReasoningContentView.revealedTileHeight
                        + 2
                } else {
                    return ReasoningContentView.unrevealedTileHeight
                }
            case let .responseContent(_, message):
                markdownViewForSizeCalculation.theme = theme
                let package = markdownPackageCache.package(for: message, theme: theme)
                markdownViewForSizeCalculation.setMarkdownManually(package)
                return ceil(markdownViewForSizeCalculation.boundingSize(for: containerWidth).height)
            case let .mediaContent(_, media):
                return MediaMessageView.contentHeight(for: media, containerWidth: containerWidth)
            case .hint:
                return ceil(theme.fonts.footnote.lineHeight + 16)
            case let .compactBoundary(_, boundary):
                return CompactBoundaryMessageView.contentHeight(for: theme, detail: boundary.detail, maxWidth: containerWidth)
            case let .toolResultContent(_, toolResult):
                // Match ReasoningContentView text sizing (footnote, leading inset 14)
                let attributed = NSAttributedString(string: toolResult.displayText, attributes: [
                    .font: theme.fonts.footnote,
                    .paragraphStyle: ToolResultContentView.paragraphStyle,
                ])
                return ceil(boundingSize(with: containerWidth - 14, for: attributed).height)
            case let .chartContent(_, chart):
                return ChartMessageView.contentHeight(for: chart.spec, containerWidth: containerWidth)
            case let .mapContent(_, map):
                return MapMessageView.contentHeight(for: map.spec, containerWidth: containerWidth)
            case let .activityReporting(content):
                let textHeight = boundingSize(with: .greatestFiniteMagnitude, for: NSAttributedString(string: content, attributes: [
                    .font: theme.fonts.body,
                ])).height
                return max(textHeight, ActivityReportingView.loadingSymbolSize.height + 16)
            case .interruptionRetry:
                return RetryActionView.rowHeight
            case .toolCallHint:
                return theme.fonts.body.lineHeight + 20
            }
        }()

        return contentHeight + bottomInset
    }

    public func listView(_: ListView, configureRowView rowView: ListRowView, for _: any Identifiable, at index: Int) {
        guard let entry = entryForRow(at: index) else { return }

        if let userMessageView = rowView as? UserMessageView {
            if case let .userContent(_, message) = entry {
                userMessageView.theme = theme
                userMessageView.text = message.content
                // Copy / Select All menu
                let text = message.content
                let messageID = message.messageID
                userMessageView.contextMenuProvider = { [weak self, weak userMessageView] _ in
                    UIMenu(children: [
                        UIAction(
                            title: String.localized("Copy"),
                            image: UIImage(systemName: "doc.on.doc")
                        ) { _ in
                            UIPasteboard.general.string = text
                        },
                        UIAction(
                            title: String.localized("Select All"),
                            image: UIImage(systemName: "selection.pin.in.out")
                        ) { _ in
                            userMessageView?.selectAllText()
                        },
                        UIAction(
                            title: String.localized("Rollback"),
                            image: UIImage(systemName: "arrow.uturn.backward")
                        ) { _ in
                            self?.onRollbackUserQuery?(messageID, text)
                        },
                        self?.compactConversationMenu(messageID: messageID),
                    ].compactMap { $0 })
                }
            }
        } else if let userAttachmentView = rowView as? UserAttachmentView {
            if case let .userAttachment(_, attachments) = entry {
                userAttachmentView.theme = theme
                userAttachmentView.update(with: attachments)
            }
        } else if let responseView = rowView as? ResponseView {
            if case let .responseContent(_, message) = entry {
                responseView.theme = theme
                let package = markdownPackageCache.package(for: message, theme: theme)
                responseView.markdownView.setMarkdown(package)
                // Copy / Select All menu
                let text = message.content
                responseView.contextMenuProvider = { [weak self, weak responseView] _ in
                    UIMenu(children: [
                        UIAction(
                            title: String.localized("Copy"),
                            image: UIImage(systemName: "doc.on.doc")
                        ) { _ in
                            UIPasteboard.general.string = text
                        },
                        UIAction(
                            title: String.localized("Select All"),
                            image: UIImage(systemName: "selection.pin.in.out")
                        ) { _ in
                            responseView?.markdownView.textView.selectAllText()
                        },
                        self?.compactConversationMenu(messageID: message.messageID),
                    ].compactMap { $0 })
                }
            }
        } else if let mediaMessageView = rowView as? MediaMessageView {
            if case let .mediaContent(_, media) = entry {
                mediaMessageView.theme = theme
                mediaMessageView.configure(with: media)
                let mediaURL = media.url
                mediaMessageView.contextMenuProvider = { _ in
                    var actions: [UIAction] = [
                        UIAction(
                            title: String.localized("Copy"),
                            image: UIImage(systemName: "doc.on.doc")
                        ) { _ in
                            UIPasteboard.general.string = mediaURL
                        },
                    ]
                    if let url = URL(string: mediaURL) {
                        actions.append(
                            UIAction(
                                title: String.localized("Open"),
                                image: UIImage(systemName: "arrow.up.right.square")
                            ) { _ in
                                UIApplication.shared.open(url)
                            }
                        )
                    }
                    return UIMenu(children: actions)
                }
            }
        } else if let hintMessageView = rowView as? HintMessageView {
            if case let .hint(_, content) = entry {
                hintMessageView.theme = theme
                hintMessageView.text = content
            }
        } else if let compactBoundaryView = rowView as? CompactBoundaryMessageView {
            if case let .compactBoundary(_, boundary) = entry {
                compactBoundaryView.theme = theme
                compactBoundaryView.title = boundary.title
                compactBoundaryView.detail = boundary.detail
            }
        } else if let activityReportingView = rowView as? ActivityReportingView {
            if case let .activityReporting(content) = entry {
                activityReportingView.theme = theme
                activityReportingView.text = content
            }
        } else if let reasoningContentView = rowView as? ReasoningContentView {
            if case let .reasoningContent(_, message) = entry {
                reasoningContentView.theme = theme
                reasoningContentView.isRevealed = message.isRevealed
                reasoningContentView.isThinking = message.isThinking
                reasoningContentView.thinkingDuration = message.thinkingDuration
                reasoningContentView.text = message.content
                reasoningContentView.thinkingTileTapHandler = { [weak self] _ in
                    self?.onToggleReasoningCollapse?(message.messageID)
                }
            }
        } else if let toolResultContentView = rowView as? ToolResultContentView {
            if case let .toolResultContent(_, toolResult) = entry {
                toolResultContentView.theme = theme
                toolResultContentView.text = toolResult.displayText
            }
        } else if let chartMessageView = rowView as? ChartMessageView {
            if case let .chartContent(_, chart) = entry {
                chartMessageView.theme = theme
                chartMessageView.configure(with: chart.spec)
                let chartJSON = chart.rawBlock
                chartMessageView.contextMenuProvider = { _ in
                    UIMenu(children: [
                        UIAction(
                            title: String.localized("Copy"),
                            image: UIImage(systemName: "doc.on.doc")
                        ) { _ in
                            UIPasteboard.general.string = chartJSON
                        },
                    ])
                }
            }
        } else if let mapMessageView = rowView as? MapMessageView {
            if case let .mapContent(_, map) = entry {
                mapMessageView.theme = theme
                mapMessageView.configure(with: map.spec)
                let mapJSON = map.rawBlock
                mapMessageView.contextMenuProvider = { _ in
                    UIMenu(children: [
                        UIAction(
                            title: String.localized("Copy"),
                            image: UIImage(systemName: "doc.on.doc")
                        ) { _ in
                            UIPasteboard.general.string = mapJSON
                        },
                    ])
                }
            }
        } else if let retryActionView = rowView as? RetryActionView {
            if case let .interruptionRetry(title) = entry {
                retryActionView.title = title
                retryActionView.tapHandler = { [weak self] in
                    self?.onRetryInterruptedInference?()
                }
            }
        } else if let toolHintView = rowView as? ToolHintView {
            if case let .toolCallHint(_, toolCallRepresentation) = entry {
                toolHintView.theme = theme
                let displayName = toolCallRepresentation.toolCall.toolName
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let apiName = toolCallRepresentation.toolCall.apiName
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                toolHintView.toolName = {
                    if !displayName.isEmpty {
                        return displayName
                    }
                    if !apiName.isEmpty {
                        return apiName
                    }
                    return "tool"
                }()
                toolHintView.text = toolCallRepresentation.toolCall.parameters
                toolHintView.state = toolCallRepresentation.toolCall.state
                toolHintView.hasResult = toolCallRepresentation.hasResult
                toolHintView.isExpanded = toolCallRepresentation.isExpanded
                toolHintView.clickHandler = { [weak self] in
                    self?.onToggleToolResultCollapse?(
                        toolCallRepresentation.messageID,
                        toolCallRepresentation.toolCall.id
                    )
                }
            }
        }
    }

    private func boundingSize(with width: CGFloat, for attributedString: NSAttributedString) -> CGSize {
        labelForSizeCalculation.preferredMaxLayoutWidth = width
        labelForSizeCalculation.attributedText = attributedString
        let contentSize = labelForSizeCalculation.intrinsicContentSize
        return .init(width: ceil(contentSize.width), height: ceil(contentSize.height))
    }
}
