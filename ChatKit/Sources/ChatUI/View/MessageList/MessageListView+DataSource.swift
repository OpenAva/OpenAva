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

    struct ToolResultRepresentation: Hashable {
        let formattedParameters: String
        let formattedResult: String
        let hasParameters: Bool
        let hasResult: Bool

        init(parameters: String, result: String) {
            let (fmtParams, hasParams) = Self.formatJSONAndCheck(parameters)
            formattedParameters = fmtParams
            hasParameters = hasParams

            let (fmtRes, hasRes) = Self.formatJSONAndCheck(result)
            formattedResult = fmtRes
            hasResult = hasRes
        }

        private static func formatJSONAndCheck(_ text: String) -> (String, Bool) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return (trimmed, false)
            }
            guard let data = trimmed.data(using: .utf8),
                  let jsonObject = try? JSONSerialization.jsonObject(with: data, options: [])
            else {
                return (trimmed, true)
            }

            let hasContent: Bool
            if let dict = jsonObject as? [String: Any] {
                hasContent = !dict.isEmpty
            } else if let array = jsonObject as? [Any] {
                hasContent = !array.isEmpty
            } else {
                hasContent = true
            }

            guard let prettyData = try? JSONSerialization.data(withJSONObject: jsonObject, options: [.prettyPrinted, .withoutEscapingSlashes]),
                  let prettyString = String(data: prettyData, encoding: .utf8)
            else {
                return (trimmed, hasContent)
            }
            return (prettyString, hasContent)
        }

        var isEmpty: Bool {
            !hasParameters && !hasResult
        }
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

    struct CompactBoundaryRepresentation: Hashable {
        let id: String
        let createdAt: Date
        let title: String
        let detail: String?
    }

    struct TodoListRepresentation: Hashable {
        let id: String
        let messageID: String
        let createdAt: Date
        let metadata: TodoListMetadata
    }

    struct SubAgentTaskRepresentation: Hashable {
        let id: String
        let messageID: String
        let createdAt: Date
        let taskID: String
        let agentType: String
        let taskDescription: String
        let status: String
        let summary: String?
        let totalTurns: Int?
        let totalToolCalls: Int?
        let durationMs: Int?
        let resultPreview: String?
        let fullResult: String?
        let errorDescription: String?
        let recentActivities: [String]
        let isExpanded: Bool

        var hasExpandedContent: Bool {
            !recentActivities.isEmpty
                || !(fullResult?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                || !(errorDescription?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        }
    }

    /// Displayable entries for the list view.
    enum Entry: Hashable, Identifiable {
        case userContent(String, MessageRepresentation)
        case userAttachment(String, Attachments)
        case reasoningContent(String, MessageRepresentation)
        case responseContent(String, MessageRepresentation)
        case hint(String, String)
        case toolCallHint(String, ToolCallRepresentation)
        case toolResultContent(String, ToolResultRepresentation)
        case chartContent(String, ChartRepresentation)
        case mapContent(String, MapRepresentation)
        case mediaContent(String, MediaRepresentation)
        case compactBoundary(String, CompactBoundaryRepresentation)
        case todoList(String, TodoListRepresentation)
        case subAgentTask(String, SubAgentTaskRepresentation)
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
            case let .compactBoundary(id, _): "compact-boundary-\(id)"
            case let .todoList(id, _): "todo-list-\(id)"
            case let .subAgentTask(id, _): "sub-agent-task-\(id)"
            case .interruptionRetry: "interruption-retry"
            case let .activityReporting(msg): "activity-\(msg)"
            }
        }
    }

    /// Convert conversation messages to displayable entries.
    func entries(from messages: [ConversationMessage]) -> [Entry] {
        var entries: [Entry] = []
        var latestDisplayedDay: Date?
        var inlineRenderedToolResultIDs: Set<String> = []

        func shouldDisplayInTranscript(_ message: ConversationMessage) -> Bool {
            if message.isCompactSummary {
                return false
            }

            switch message.role {
            case .user, .assistant, .tool:
                return true
            case .system:
                return message.isCompactBoundary || message.isSubAgentTask || message.isTodoList
            default:
                return false
            }
        }

        func compactBoundaryTitle(for metadata: CompactBoundaryMetadata?) -> String {
            switch metadata?.trigger {
            case "auto":
                return String.localized("Automatic compact boundary")
            case "manual":
                return String.localized("Manual compact boundary")
            default:
                return String.localized("Conversation compact boundary")
            }
        }

        func localizedCompactBoundaryMetric(_ key: String, _ value: Int64) -> String {
            let format = NSLocalizedString(key, tableName: nil, bundle: .module, value: key, comment: "")
            return String(format: format, locale: Locale.current, value)
        }

        func compactBoundaryDetail(for metadata: CompactBoundaryMetadata?) -> String? {
            guard let metadata else { return nil }
            if let messagesSummarized = metadata.messagesSummarized, messagesSummarized > 0 {
                return localizedCompactBoundaryMetric("Compacted %lld earlier messages", Int64(messagesSummarized))
            }
            return nil
        }

        func isReasoningStillStreaming(in message: ConversationMessage) -> Bool {
            guard message.role == .assistant else { return false }
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

        func assistantMessageID(forToolResult toolCallID: String, startingAt index: Int) -> String? {
            if index > 0 {
                for i in stride(from: index - 1, through: 0, by: -1) {
                    let candidate = messages[i]
                    guard candidate.role == .assistant else { continue }
                    let hasCall = candidate.parts.contains { part in
                        guard case let .toolCall(call) = part else { return false }
                        return call.id == toolCallID
                    }
                    if hasCall {
                        return candidate.id
                    }
                }
            }
            return messages.first(where: { message in
                guard message.role == .assistant else { return false }
                return message.parts.contains { part in
                    guard case let .toolCall(call) = part else { return false }
                    return call.id == toolCallID
                }
            })?.id
        }

        func firstToolResultMessage(for toolCallID: String) -> (messageID: String, result: ToolResultContentPart)? {
            for message in messages where message.role == .tool {
                for part in message.parts {
                    guard case let .toolResult(result) = part, result.toolCallID == toolCallID else { continue }
                    return (message.id, result)
                }
            }
            return nil
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

        for (messageIndex, message) in messages.enumerated() {
            guard shouldDisplayInTranscript(message) else {
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
                        let matchingToolResultMessage = firstToolResultMessage(for: tc.id)
                        let matchingResult = matchingToolResultMessage?.result
                        entries.append(
                            .toolCallHint(
                                tc.id,
                                ToolCallRepresentation(
                                    messageID: matchingToolResultMessage?.messageID ?? message.id,
                                    toolCall: tc,
                                    hasResult: matchingResult != nil,
                                    isExpanded: !(matchingResult?.isCollapsed ?? true)
                                )
                            )
                        )
                        if let matchingResult, !matchingResult.isCollapsed {
                            let representation = ToolResultRepresentation(
                                parameters: tc.parameters,
                                result: matchingResult.result
                            )
                            if !representation.isEmpty {
                                entries.append(.toolResultContent(matchingResult.id, representation))
                                inlineRenderedToolResultIDs.insert(matchingResult.id)
                            }
                        }
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
                        continue
                    case .image, .audio, .file:
                        continue
                    }
                }

            case .tool:
                guard let toolResult = message.parts.compactMap({ part -> ToolResultContentPart? in
                    guard case let .toolResult(value) = part else { return nil }
                    return value
                }).first else {
                    break
                }
                guard !toolResult.isCollapsed else { break }
                guard !inlineRenderedToolResultIDs.contains(toolResult.id) else { break }
                let assistantID = assistantMessageID(forToolResult: toolResult.toolCallID, startingAt: messageIndex) ?? message.id
                let toolCall = messages.first(where: { $0.id == assistantID })?.parts.first { part in
                    guard case let .toolCall(value) = part else { return false }
                    return value.id == toolResult.toolCallID
                }
                let parameters: String = {
                    guard case let .toolCall(value)? = toolCall else { return "" }
                    return value.parameters
                }()
                let representation = ToolResultRepresentation(
                    parameters: parameters,
                    result: toolResult.result
                )
                guard !representation.isEmpty else { break }
                entries.append(.toolResultContent(toolResult.id, representation))

            case .system:
                if message.isTodoList, let metadata = message.todoListMetadata {
                    entries.append(
                        .todoList(
                            message.id,
                            TodoListRepresentation(
                                id: message.id,
                                messageID: message.id,
                                createdAt: message.createdAt,
                                metadata: metadata
                            )
                        )
                    )
                    continue
                }

                if message.isSubAgentTask, let metadata = message.subAgentTaskMetadata {
                    entries.append(
                        .subAgentTask(
                            message.id,
                            SubAgentTaskRepresentation(
                                id: message.id,
                                messageID: message.id,
                                createdAt: message.createdAt,
                                taskID: metadata.taskID,
                                agentType: metadata.agentType,
                                taskDescription: metadata.taskDescription,
                                status: metadata.status,
                                summary: metadata.summary,
                                totalTurns: metadata.totalTurns,
                                totalToolCalls: metadata.totalToolCalls,
                                durationMs: metadata.durationMs,
                                resultPreview: metadata.resultPreview,
                                fullResult: message.textContent,
                                errorDescription: metadata.errorDescription,
                                recentActivities: metadata.recentActivities ?? [],
                                isExpanded: expandedSubAgentMessageIDs.contains(message.id)
                            )
                        )
                    )
                    continue
                }

                guard message.isCompactBoundary else { break }
                entries.append(
                    .compactBoundary(
                        message.id,
                        CompactBoundaryRepresentation(
                            id: message.id,
                            createdAt: message.createdAt,
                            title: compactBoundaryTitle(for: message.compactBoundaryMetadata),
                            detail: compactBoundaryDetail(for: message.compactBoundaryMetadata)
                        )
                    )
                )

            default:
                continue
            }
        }

        if showsInterruptedRetryAction {
            entries.append(.interruptionRetry(String.localized("Task execution interrupted, please retry.")))
        }

        return entries
    }
}

// MARK: - ToolCallContentPart Hashable

extension ToolCallContentPart: Hashable {
    public static func == (lhs: ToolCallContentPart, rhs: ToolCallContentPart) -> Bool {
        lhs.id == rhs.id
            && lhs.state == rhs.state
            && lhs.toolName == rhs.toolName
            && lhs.apiName == rhs.apiName
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(state)
        hasher.combine(toolName)
        hasher.combine(apiName)
    }
}

extension ToolCallState: Hashable {}
