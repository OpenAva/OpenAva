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
        case todoList
        case subAgentTask
        case toolCallHint
        case toolResultContent
        case chartContent
        case mapContent
        case interruptionRetry
        case activityReporting
    }
}

extension MessageListView: ListViewAdapter {
    private struct ToolResultSectionMetrics {
        let titleHeight: CGFloat
        let codeHeight: CGFloat
    }

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
        case .todoList: RowType.todoList
        case .subAgentTask: RowType.subAgentTask
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
        case .todoList:
            TodoListMessageView()
        case .subAgentTask:
            SubAgentTaskCardView()
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
                let availableWidth = UserMessageView.availableTextWidth(for: containerWidth)
                let cacheKey = NSString(string: "user-\(message.messageID)|\(Int(availableWidth.rounded()))")
                if let cached = userContentHeightCache.object(forKey: cacheKey) {
                    return CGFloat(cached.floatValue) + UserMessageView.textPadding * 2
                }

                let attributedContent = NSAttributedString(string: message.content, attributes: [
                    .font: theme.fonts.body,
                    .foregroundColor: theme.colors.body,
                ])
                let height = boundingSize(with: availableWidth, for: attributedContent).height
                userContentHeightCache.setObject(NSNumber(value: Double(height)), forKey: cacheKey)
                return height + UserMessageView.textPadding * 2
            case .userAttachment:
                return AttachmentsBar.itemHeight
            case let .reasoningContent(_, message):
                if message.isRevealed {
                    let availableWidth = containerWidth - 16
                    let cacheKey = NSString(string: "reasoning-\(message.id)|\(Int(availableWidth.rounded()))")

                    let textHeight: CGFloat
                    if let cached = userContentHeightCache.object(forKey: cacheKey) {
                        textHeight = CGFloat(cached.floatValue)
                    } else {
                        let attributedContent = NSAttributedString(string: message.content, attributes: [
                            .font: theme.fonts.footnote,
                            .paragraphStyle: ReasoningContentView.paragraphStyle,
                        ])
                        textHeight = boundingSize(with: availableWidth, for: attributedContent).height
                        userContentHeightCache.setObject(NSNumber(value: Double(textHeight)), forKey: cacheKey)
                    }

                    return textHeight
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
            case let .todoList(_, todoList):
                return TodoListMessageView.contentHeight(for: todoList.metadata, theme: theme, maxWidth: containerWidth)
            case let .subAgentTask(_, task):
                return SubAgentTaskCardView.contentHeight(for: task, theme: theme, maxWidth: containerWidth)
            case let .toolResultContent(_, toolResult):
                let textWidth = max(0, containerWidth - 14)
                var totalHeight: CGFloat = 0

                if toolResult.hasParameters {
                    let metrics = toolResultSectionMetrics(
                        entryID: entry.id,
                        title: String.localized("Tool Arguments"),
                        content: toolResult.formattedParameters,
                        textWidth: textWidth,
                        theme: theme
                    )
                    totalHeight += metrics.titleHeight + 8
                    totalHeight += metrics.codeHeight + 16
                }

                if toolResult.hasResult {
                    if totalHeight > 0 { totalHeight += 16 } // stack view spacing
                    let metrics = toolResultSectionMetrics(
                        entryID: entry.id,
                        title: String.localized("Tool Result"),
                        content: toolResult.formattedResult,
                        textWidth: textWidth,
                        theme: theme
                    )
                    totalHeight += metrics.titleHeight + 8
                    totalHeight += metrics.codeHeight + 16
                }

                return min(totalHeight, 360)
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
        } else if let todoListView = rowView as? TodoListMessageView {
            if case let .todoList(_, todoList) = entry {
                todoListView.theme = theme
                todoListView.configure(with: todoList.metadata)
            }
        } else if let subAgentTaskCardView = rowView as? SubAgentTaskCardView {
            if case let .subAgentTask(_, task) = entry {
                subAgentTaskCardView.theme = theme
                subAgentTaskCardView.configure(with: task)
                subAgentTaskCardView.tapHandler = { [weak self] in
                    self?.toggleSubAgentTaskExpansion(messageID: task.messageID)
                }
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
                toolResultContentView.configure(with: toolResult)
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
                retryActionView.isLoading = isRetryingInterruptedSubmission
                retryActionView.tapHandler = { [weak self] in
                    guard let self, !self.isRetryingInterruptedSubmission else { return }
                    self.isRetryingInterruptedSubmission = true
                    self.onRetryInterruptedMessageSubmission?()
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

    private func toolResultSectionMetrics(
        entryID: String,
        title: String,
        content: String,
        textWidth: CGFloat,
        theme: MarkdownTheme
    ) -> ToolResultSectionMetrics {
        let cacheKey = NSString(string: "\(entryID)|\(title)|\(Int(textWidth.rounded()))")
        if let cached = toolResultSectionMetricsCache.object(forKey: cacheKey) {
            let size = cached.cgSizeValue
            return .init(titleHeight: size.width, codeHeight: size.height)
        }

        // For list view height calculation, we only care up to a certain maximum cell height (360).
        // A 5000 character string will easily exceed the max cell height, so we truncate to speed up the bounding rect.
        let calculationContent = content.count > 5000 ? String(content.prefix(5000)) : content

        let titleHeight = ceil(
            NSAttributedString(
                string: title,
                attributes: [.font: theme.fonts.footnote.bold]
            ).boundingRect(
                with: CGSize(width: textWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                context: nil
            ).height
        )

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 4
        paragraphStyle.lineBreakMode = .byCharWrapping
        let codeHeight = ceil(
            NSAttributedString(
                string: calculationContent,
                attributes: [
                    .font: theme.fonts.code,
                    .paragraphStyle: paragraphStyle,
                ]
            ).boundingRect(
                with: CGSize(width: max(0, textWidth - 16), height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                context: nil
            ).height
        )

        let metrics = ToolResultSectionMetrics(titleHeight: titleHeight, codeHeight: codeHeight)
        toolResultSectionMetricsCache.setObject(NSValue(cgSize: CGSize(width: titleHeight, height: codeHeight)), forKey: cacheKey)
        return metrics
    }
}
