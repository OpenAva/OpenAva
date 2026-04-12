//
//  MessageListView+DataSource.swift
//  ChatUI
//
//  Data source types and message-to-entry conversion.
//

import Foundation
import MarkdownView

extension MessageListView {
    /// A lightweight representation of a message for display purposes.
    struct MessageRepresentation: Hashable {
        let id: String
        let messageID: String
        let createdAt: Date
        let role: MessageRole
        let content: String
        var isRevealed: Bool
        var isThinking: Bool
        var thinkingDuration: TimeInterval
    }

    struct Attachments: Hashable {
        let items: [ChatInputAttachment]
    }

    struct ToolCallRepresentation: Hashable {
        let messageID: String
        let toolCall: ToolCallContentPart
        let hasResult: Bool
        let isExpanded: Bool
    }

    struct ChartRepresentation: Hashable {
        let id: String
        let messageID: String
        let createdAt: Date
        let spec: ChartSpec
        let rawBlock: String
    }

    struct MapRepresentation: Hashable {
        let id: String
        let messageID: String
        let createdAt: Date
        let spec: MapSpec
        let rawBlock: String
    }

    struct MediaRepresentation: Hashable {
        let id: String
        let messageID: String
        let createdAt: Date
        let kind: MarkdownMediaKind
        let url: String
        let altText: String?
    }

    /// Displayable entries for the list view.
    enum Entry: Hashable, Identifiable {
        case userContent(String, MessageRepresentation)
        case userAttachment(String, Attachments)
        case reasoningContent(String, MessageRepresentation)
        case responseContent(String, MessageRepresentation)
        case hint(String, String)
        case toolCallHint(String, ToolCallRepresentation)
        case toolResultContent(String, String) // tool result plain text
        case chartContent(String, ChartRepresentation)
        case mapContent(String, MapRepresentation)
        case mediaContent(String, MediaRepresentation)
        case interruptionRetry(String)
        case activityReporting(String)

        var id: String {
            switch self {
            case let .userContent(id, _): "user-\(id)"
            case let .userAttachment(id, _): "user-attachment-\(id)"
            case let .reasoningContent(id, _): "reasoning-\(id)"
            case let .responseContent(id, _): "response-\(id)"
            case let .hint(id, _): "hint-\(id)"
            case let .toolCallHint(id, _): "tool-\(id)"
            case let .toolResultContent(id, _): "tool-result-\(id)"
            case let .chartContent(id, _): "chart-\(id)"
            case let .mapContent(id, _): "map-\(id)"
            case let .mediaContent(id, _): "media-\(id)"
            case .interruptionRetry: "interruption-retry"
            case let .activityReporting(msg): "activity-\(msg)"
            }
        }
    }

    /// Convert conversation messages to displayable entries.
    func entries(from messages: [ConversationMessage]) -> [Entry] {
        var entries: [Entry] = []
        var latestDisplayedDay: Date?

        func isReasoningStillStreaming(in message: ConversationMessage) -> Bool {
            var hasVisibleReasoning = false

            for part in message.parts {
                switch part {
                case let .reasoning(reasoningPart):
                    if !reasoningPart.text.isEmpty {
                        hasVisibleReasoning = true
                    }
                case let .text(textPart):
                    if !textPart.text.isEmpty {
                        return false
                    }
                case .toolCall, .toolResult, .image, .audio, .file:
                    return false
                }
            }

            return hasVisibleReasoning
        }

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm"

        let dayKeyFormatter = DateFormatter()
        dayKeyFormatter.dateFormat = "yyyy-MM-dd"

        func checkAddDateHint(_ date: Date) {
            if let latestDisplayedDay, Calendar.current.isDate(date, inSameDayAs: latestDisplayedDay) { return }
            latestDisplayedDay = date
            let hintText = dateFormatter.string(from: date)
            let dayKey = dayKeyFormatter.string(from: date)
            entries.append(.hint("date.\(dayKey)", hintText))
        }

        for message in messages {
            if message.isCompactionSummary {
                continue
            }

            checkAddDateHint(message.createdAt)

            let textContent = message.textContent
            let isThinking = isReasoningStillStreaming(in: message)
            var reasoningDuration: TimeInterval = 0
            var reasoningCollapsed = false

            for part in message.parts {
                if case let .reasoning(rp) = part {
                    reasoningDuration = rp.duration
                    reasoningCollapsed = rp.isCollapsed
                }
            }

            let representation = MessageRepresentation(
                id: message.id,
                messageID: message.id,
                createdAt: message.createdAt,
                role: message.role,
                content: textContent,
                isRevealed: !reasoningCollapsed,
                isThinking: isThinking,
                thinkingDuration: reasoningDuration
            )

            switch message.role {
            case .user:
                let attachmentItems = message.parts.compactMap { part -> ChatInputAttachment? in
                    switch part {
                    case let .image(imagePart):
                        return ChatInputAttachment(
                            type: .image,
                            name: imagePart.name ?? String.localized("Image"),
                            previewImageData: imagePart.previewData ?? imagePart.data,
                            fileData: imagePart.data,
                            storageFilename: imagePart.name ?? "image.jpeg"
                        )
                    case let .audio(audioPart):
                        return ChatInputAttachment(
                            type: .audio,
                            name: audioPart.name ?? String.localized("Audio"),
                            fileData: audioPart.data,
                            textContent: audioPart.transcription ?? audioPart.name ?? "",
                            storageFilename: audioPart.name ?? "audio.m4a"
                        )
                    case let .file(filePart):
                        return ChatInputAttachment(
                            type: .document,
                            name: filePart.name ?? String.localized("Document"),
                            textContent: filePart.textContent ?? String(data: filePart.data, encoding: .utf8) ?? "",
                            storageFilename: filePart.name ?? "document.txt"
                        )
                    case .text, .reasoning, .toolCall, .toolResult:
                        return nil
                    }
                }
                if !attachmentItems.isEmpty {
                    entries.append(.userAttachment(message.id, .init(items: attachmentItems)))
                }
                if !textContent.isEmpty {
                    entries.append(.userContent(message.id, representation))
                }

            case .assistant:
                // Preserve assistant part order so tool UI stays where the model emitted it.
                for part in message.parts {
                    switch part {
                    case let .reasoning(reasoningPart):
                        guard !reasoningPart.text.isEmpty else { continue }
                        let reasoningRep = MessageRepresentation(
                            id: reasoningPart.id,
                            messageID: message.id,
                            createdAt: message.createdAt,
                            role: message.role,
                            content: reasoningPart.text,
                            isRevealed: !reasoningPart.isCollapsed,
                            isThinking: isThinking,
                            thinkingDuration: reasoningPart.duration
                        )
                        entries.append(.reasoningContent(reasoningPart.id, reasoningRep))
                    case let .toolCall(tc):
                        let matchingResults = message.parts.compactMap { part -> ToolResultContentPart? in
                            guard case let .toolResult(value) = part, value.toolCallID == tc.id else { return nil }
                            return value
                        }
                        entries.append(
                            .toolCallHint(
                                tc.id,
                                ToolCallRepresentation(
                                    messageID: message.id,
                                    toolCall: tc,
                                    hasResult: !matchingResults.isEmpty,
                                    isExpanded: matchingResults.contains(where: { !$0.isCollapsed })
                                )
                            )
                        )
                    case let .text(textPart):
                        guard !textPart.text.isEmpty else { continue }
                        let segments = ChartMarkdownParser.parseSegments(from: textPart.text)
                        // Keep segment order to preserve the model output structure.
                        for (index, segment) in segments.enumerated() {
                            switch segment {
                            case let .markdown(content):
                                guard !content.isEmpty else { continue }
                                let nestedSegments = MapMarkdownParser.parseSegments(from: content)
                                for (nestedIndex, nestedSegment) in nestedSegments.enumerated() {
                                    switch nestedSegment {
                                    case let .markdown(nestedContent):
                                        let mediaSegments = MarkdownMediaParser.parseSegments(from: nestedContent)
                                        for (mediaIndex, mediaSegment) in mediaSegments.enumerated() {
                                            switch mediaSegment {
                                            case let .markdown(mediaMarkdown):
                                                guard !mediaMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                                                    continue
                                                }
                                                let segmentID = "\(textPart.id).md.\(index).\(nestedIndex).\(mediaIndex)"
                                                let textRep = MessageRepresentation(
                                                    id: segmentID,
                                                    messageID: message.id,
                                                    createdAt: message.createdAt,
                                                    role: message.role,
                                                    content: mediaMarkdown,
                                                    isRevealed: !reasoningCollapsed,
                                                    isThinking: false,
                                                    thinkingDuration: 0
                                                )
                                                entries.append(.responseContent(segmentID, textRep))
                                            case let .media(media):
                                                let mediaID = "\(textPart.id).media.\(index).\(nestedIndex).\(mediaIndex)"
                                                let mediaRep = MediaRepresentation(
                                                    id: mediaID,
                                                    messageID: message.id,
                                                    createdAt: message.createdAt,
                                                    kind: media.kind,
                                                    url: media.url,
                                                    altText: media.altText
                                                )
                                                entries.append(.mediaContent(mediaID, mediaRep))
                                            case let .chart(spec, rawBlock):
                                                let chartID = "\(textPart.id).chart.\(index).\(nestedIndex).\(mediaIndex)"
                                                let chartRep = ChartRepresentation(
                                                    id: chartID,
                                                    messageID: message.id,
                                                    createdAt: message.createdAt,
                                                    spec: spec,
                                                    rawBlock: rawBlock
                                                )
                                                entries.append(.chartContent(chartID, chartRep))
                                            case let .map(spec, rawBlock):
                                                let mapID = "\(textPart.id).map.\(index).\(nestedIndex).\(mediaIndex)"
                                                let mapRep = MapRepresentation(
                                                    id: mapID,
                                                    messageID: message.id,
                                                    createdAt: message.createdAt,
                                                    spec: spec,
                                                    rawBlock: rawBlock
                                                )
                                                entries.append(.mapContent(mapID, mapRep))
                                            }
                                        }
                                    case let .map(spec, rawBlock):
                                        let mapID = "\(textPart.id).map.\(index).\(nestedIndex)"
                                        let mapRep = MapRepresentation(
                                            id: mapID,
                                            messageID: message.id,
                                            createdAt: message.createdAt,
                                            spec: spec,
                                            rawBlock: rawBlock
                                        )
                                        entries.append(.mapContent(mapID, mapRep))
                                    case let .chart(spec, rawBlock):
                                        let chartID = "\(textPart.id).chart.\(index).\(nestedIndex)"
                                        let chartRep = ChartRepresentation(
                                            id: chartID,
                                            messageID: message.id,
                                            createdAt: message.createdAt,
                                            spec: spec,
                                            rawBlock: rawBlock
                                        )
                                        entries.append(.chartContent(chartID, chartRep))
                                    case let .media(media):
                                        let mediaID = "\(textPart.id).media.\(index).\(nestedIndex)"
                                        let mediaRep = MediaRepresentation(
                                            id: mediaID,
                                            messageID: message.id,
                                            createdAt: message.createdAt,
                                            kind: media.kind,
                                            url: media.url,
                                            altText: media.altText
                                        )
                                        entries.append(.mediaContent(mediaID, mediaRep))
                                    }
                                }
                            case let .chart(spec, rawBlock):
                                let chartID = "\(textPart.id).chart.\(index)"
                                let chartRep = ChartRepresentation(
                                    id: chartID,
                                    messageID: message.id,
                                    createdAt: message.createdAt,
                                    spec: spec,
                                    rawBlock: rawBlock
                                )
                                entries.append(.chartContent(chartID, chartRep))
                            case let .map(spec, rawBlock):
                                let mapID = "\(textPart.id).map.\(index)"
                                let mapRep = MapRepresentation(
                                    id: mapID,
                                    messageID: message.id,
                                    createdAt: message.createdAt,
                                    spec: spec,
                                    rawBlock: rawBlock
                                )
                                entries.append(.mapContent(mapID, mapRep))
                            case let .media(media):
                                let mediaID = "\(textPart.id).media.\(index)"
                                let mediaRep = MediaRepresentation(
                                    id: mediaID,
                                    messageID: message.id,
                                    createdAt: message.createdAt,
                                    kind: media.kind,
                                    url: media.url,
                                    altText: media.altText
                                )
                                entries.append(.mediaContent(mediaID, mediaRep))
                            }
                        }
                    case let .toolResult(toolResult):
                        guard !toolResult.result.isEmpty, !toolResult.isCollapsed else { continue }
                        entries.append(.toolResultContent(toolResult.id, toolResult.result))
                    case .image, .audio, .file:
                        continue
                    }
                }

            case .system:
                // System messages are not displayed in the list
                break

            default:
                // Custom roles: display as hint
                if !textContent.isEmpty {
                    entries.append(.hint(message.id, textContent))
                }
            }
        }

        if showsInterruptedRetryAction {
            entries.append(.interruptionRetry("任务已中断，请点重试"))
        }

        return entries
    }
}

// MARK: - ToolCallContentPart Hashable

extension ToolCallContentPart: Hashable {
    public static func == (lhs: ToolCallContentPart, rhs: ToolCallContentPart) -> Bool {
        lhs.id == rhs.id && lhs.state == rhs.state
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(state)
    }
}

extension ToolCallState: Hashable {}
