//
//  MessageListView+DataSource.swift
//  ChatUI
//
//  Data source types and message-to-entry conversion.
//

import Foundation
import MarkdownView

extension MessageListView {
    static func hasAgentIdentity(name: String?, emoji: String?, avatarURL: String? = nil) -> Bool {
        if let agentName = name?.trimmingCharacters(in: .whitespacesAndNewlines), !agentName.isEmpty {
            return true
        }
        if let avatarURL = avatarURL?.trimmingCharacters(in: .whitespacesAndNewlines), !avatarURL.isEmpty {
            return true
        }
        if let agentEmoji = emoji?.trimmingCharacters(in: .whitespacesAndNewlines), !agentEmoji.isEmpty {
            return true
        }
        return false
    }

    /// Describes where a visible turn came from so one transcript can carry
    /// human, automation, and team-originated messages without splitting flows.
    struct MessageSourceRepresentation: Hashable {
        enum Kind: String, Hashable {
            case user
            case heartbeat
            case teamMention = "team_mention"
            case teamTask = "team_task"
            case teamBroadcast = "team_broadcast"
            case teamMessage = "team_message"
            case systemEvent = "system_event"
            case unknown
        }

        static let sourceMetadataKey = "turnSource"
        static let heartbeatModeMetadataKey = "heartbeatMode"
        static let teamMessageTypeMetadataKey = "teamMessageType"
        static let teamSenderMetadataKey = "teamSender"

        let kind: Kind
        let rawValue: String
        let title: String
        let detail: String?

        var showsBadge: Bool {
            kind != .user
        }

        var badgeText: String {
            if let detail, !detail.isEmpty {
                return "\(title) · \(detail)"
            }
            return title
        }

        static func make(from metadata: [String: String]) -> Self {
            let rawSource = metadata[sourceMetadataKey]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() ?? Kind.user.rawValue
            let kind = Kind(rawValue: rawSource) ?? .unknown

            let title: String
            let detail: String?
            switch kind {
            case .user:
                title = String.localized("User")
                detail = nil
            case .heartbeat:
                title = String.localized("Heartbeat")
                detail = metadata[heartbeatModeMetadataKey].flatMap(localizedMetadataDetail)
            case .teamMention:
                title = String.localized("Team mention")
                detail = metadata[teamSenderMetadataKey].flatMap(localizedTeamSenderDetail)
            case .teamTask:
                title = String.localized("Team task")
                detail = metadata[teamMessageTypeMetadataKey].flatMap(localizedMetadataDetail)
            case .teamBroadcast:
                title = String.localized("Team broadcast")
                detail = metadata[teamSenderMetadataKey].flatMap(localizedTeamSenderDetail)
                    ?? metadata[teamMessageTypeMetadataKey].flatMap(localizedMetadataDetail)
            case .teamMessage:
                title = String.localized("Team message")
                detail = metadata[teamSenderMetadataKey].flatMap(localizedTeamSenderDetail)
            case .systemEvent:
                title = String.localized("System event")
                detail = metadata[teamMessageTypeMetadataKey].flatMap(localizedMetadataDetail)
            case .unknown:
                title = String.localized("External source")
                detail = localizedMetadataDetail(rawSource)
            }

            return .init(kind: kind, rawValue: rawSource, title: title, detail: detail)
        }

        private static func localizedTeamSenderDetail(_ sender: String) -> String? {
            let trimmed = sender.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return String(format: String.localized("from %@"), trimmed)
        }

        private static func localizedMetadataDetail(_ rawValue: String) -> String? {
            let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }

            let words = trimmed
                .replacingOccurrences(of: "-", with: "_")
                .split(separator: "_")
                .map { word in
                    let lowercased = word.lowercased()
                    guard let first = lowercased.first else { return "" }
                    return String(first).uppercased() + String(lowercased.dropFirst())
                }
                .filter { !$0.isEmpty }
            return words.isEmpty ? trimmed : words.joined(separator: " ")
        }
    }

    /// A lightweight representation of a message for display purposes.
    struct MessageRepresentation: Hashable {
        let id: String
        let messageID: String
        let createdAt: Date
        let role: MessageRole
        let content: String
        let source: MessageSourceRepresentation
        var isRevealed: Bool
        var isThinking: Bool
        var isInterrupted: Bool
        var thinkingDuration: TimeInterval
        var agentName: String?
        var agentEmoji: String?
    }

    struct AgentHeaderRepresentation: Hashable {
        let id: String
        let messageID: String
        let createdAt: Date
        let name: String?
        let emoji: String?
        let avatarURL: String?

        var displayName: String {
            if let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmedName.isEmpty {
                return trimmedName
            }
            return "Assistant"
        }

        var displayEmoji: String {
            if let trimmedEmoji = emoji?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmedEmoji.isEmpty {
                return trimmedEmoji
            }
            return "🤖"
        }

        var resolvedAvatarURL: URL? {
            guard let trimmed = avatarURL?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
                return nil
            }
            return URL(string: trimmed)
        }
    }

    struct ExecutionErrorRepresentation: Hashable {
        let id: String
        let messageID: String
        let createdAt: Date
        let title: String
        let message: String
        let details: String?
        let agentName: String?
        let agentEmoji: String?
    }

    struct Attachments: Hashable {
        let items: [ChatInputAttachment]
        let isTrailingAligned: Bool

        init(items: [ChatInputAttachment], isTrailingAligned: Bool = true) {
            self.items = items
            self.isTrailingAligned = isTrailingAligned
        }
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

    struct MermaidRepresentation: Hashable {
        let id: String
        let messageID: String
        let createdAt: Date
        let source: String
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
        case agentHeader(String, AgentHeaderRepresentation)
        case reasoningContent(String, MessageRepresentation)
        case responseContent(String, MessageRepresentation)
        case executionError(String, ExecutionErrorRepresentation)
        case hint(String, String)
        case toolCallHint(String, ToolCallRepresentation)
        case toolResultContent(String, ToolResultRepresentation)
        case chartContent(String, ChartRepresentation)
        case mapContent(String, MapRepresentation)
        case mermaidContent(String, MermaidRepresentation)
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
            case let .agentHeader(id, _): "agent-header-\(id)"
            case let .reasoningContent(id, _): "reasoning-\(id)"
            case let .responseContent(id, _): "response-\(id)"
            case let .executionError(id, _): "execution-error-\(id)"
            case let .hint(id, _): "hint-\(id)"
            case let .toolCallHint(id, _): "tool-\(id)"
            case let .toolResultContent(id, _): "tool-result-\(id)"
            case let .chartContent(id, _): "chart-\(id)"
            case let .mapContent(id, _): "map-\(id)"
            case let .mermaidContent(id, _): "mermaid-\(id)"
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

        // Reset per-entry leading inset table; rebuilt as entries are emitted.
        entryLeadingInsets.removeAll(keepingCapacity: true)

        func append(_ entry: Entry, leadingInset: CGFloat) {
            entries.append(entry)
            if leadingInset != 0 {
                entryLeadingInsets[entry.id] = leadingInset
            }
        }

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
            if message.finishReason != nil {
                return false
            }

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

        func normalizedAgentIdentity(for message: ConversationMessage) -> String? {
            let trimmedName = message.metadata["agentName"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let trimmedAvatarURL = message.metadata["agentAvatarURL"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let trimmedEmoji = message.metadata["agentEmoji"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !trimmedName.isEmpty || !trimmedAvatarURL.isEmpty || !trimmedEmoji.isEmpty else { return nil }

            return "\(trimmedName.lowercased())|\(trimmedAvatarURL)|\(trimmedEmoji)"
        }

        func agentHeaderRepresentation(for message: ConversationMessage) -> AgentHeaderRepresentation? {
            let name = message.metadata["agentName"]
            let emoji = message.metadata["agentEmoji"]
            let avatarURL = message.metadata["agentAvatarURL"]
            let hasName = name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            let hasAvatarURL = avatarURL?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            let hasEmoji = emoji?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            guard hasName || hasAvatarURL || hasEmoji else { return nil }

            return AgentHeaderRepresentation(
                id: "\(message.id).agent-header",
                messageID: message.id,
                createdAt: message.createdAt,
                name: name,
                emoji: emoji,
                avatarURL: avatarURL
            )
        }

        func isTodoWriteToolName(_ name: String?) -> Bool {
            let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed == "TodoWrite" || trimmed == "todo_write"
        }

        func isTodoWriteToolCall(_ toolCall: ToolCallContentPart) -> Bool {
            isTodoWriteToolName(toolCall.toolName) || isTodoWriteToolName(toolCall.apiName)
        }

        func assistantMessageHasVisibleContent(_ message: ConversationMessage) -> Bool {
            if message.isTransientExecutionError {
                return true
            }

            for part in message.parts {
                switch part {
                case let .reasoning(reasoningPart):
                    if !reasoningPart.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        return true
                    }
                case let .text(textPart):
                    if !textPart.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        return true
                    }
                case let .toolCall(toolCall):
                    if !isTodoWriteToolCall(toolCall) {
                        return true
                    }
                case .toolResult, .image, .audio, .file:
                    return true
                }
            }
            return false
        }

        func assistantMessage(forToolResult toolCallID: String, startingAt index: Int) -> ConversationMessage? {
            if index > 0 {
                for i in stride(from: index - 1, through: 0, by: -1) {
                    let candidate = messages[i]
                    guard candidate.role == .assistant else { continue }
                    let hasCall = candidate.parts.contains { part in
                        guard case let .toolCall(call) = part else { return false }
                        return call.id == toolCallID
                    }
                    if hasCall {
                        return candidate
                    }
                }
            }
            return messages.first(where: { message in
                guard message.role == .assistant else { return false }
                return message.parts.contains { part in
                    guard case let .toolCall(call) = part else { return false }
                    return call.id == toolCallID
                }
            })
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

        var activeAgentIdentity: String?

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm"

        let dayKeyFormatter = DateFormatter()
        dayKeyFormatter.dateFormat = "yyyy-MM-dd"

        func checkAddDateHint(_ date: Date) {
            if let latestDisplayedDay, Calendar.current.isDate(date, inSameDayAs: latestDisplayedDay) { return }
            activeAgentIdentity = nil
            latestDisplayedDay = date
            let hintText = dateFormatter.string(from: date)
            let dayKey = dayKeyFormatter.string(from: date)
            append(.hint("date.\(dayKey)", hintText), leadingInset: 0)
        }

        for (messageIndex, message) in messages.enumerated() {
            guard shouldDisplayInTranscript(message) else {
                continue
            }

            checkAddDateHint(message.createdAt)

            // Determine the content leading inset for entries produced by this message.
            // Agent-branded assistant turns (and their associated tool rows) are
            // indented to align with the agent header's content column.
            let messageLeadingInset: CGFloat
            switch message.role {
            case .assistant:
                messageLeadingInset = MessageListView.hasAgentIdentity(
                    name: message.metadata["agentName"],
                    emoji: message.metadata["agentEmoji"],
                    avatarURL: message.metadata["agentAvatarURL"]
                ) ? MessageListRowView.agentContentLeadingOffset : 0
            case .tool:
                // Tool results are visually part of the owning assistant turn.
                if let toolResult = message.parts.compactMap({ part -> ToolResultContentPart? in
                    guard case let .toolResult(value) = part else { return nil }
                    return value
                }).first,
                    let assistantMessage = assistantMessage(forToolResult: toolResult.toolCallID, startingAt: messageIndex)
                {
                    messageLeadingInset = MessageListView.hasAgentIdentity(
                        name: assistantMessage.metadata["agentName"],
                        emoji: assistantMessage.metadata["agentEmoji"],
                        avatarURL: assistantMessage.metadata["agentAvatarURL"]
                    ) ? MessageListRowView.agentContentLeadingOffset : 0
                } else {
                    messageLeadingInset = 0
                }
            default:
                messageLeadingInset = 0
            }
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
                source: MessageSourceRepresentation.make(from: message.metadata),
                isRevealed: !reasoningCollapsed,
                isThinking: isThinking,
                isInterrupted: message.finishReason == .cancelled,
                thinkingDuration: reasoningDuration,
                agentName: message.metadata["agentName"],
                agentEmoji: message.metadata["agentEmoji"]
            )

            let hasVisibleAssistantContent = message.role == .assistant && assistantMessageHasVisibleContent(message)
            if hasVisibleAssistantContent,
               let agentIdentity = normalizedAgentIdentity(for: message),
               let agentHeader = agentHeaderRepresentation(for: message)
            {
                if agentIdentity != activeAgentIdentity {
                    // The agent header itself owns the avatar column; do not indent it.
                    append(.agentHeader(agentHeader.id, agentHeader), leadingInset: 0)
                }
                activeAgentIdentity = agentIdentity
            } else if message.role == .user || message.role == .system || hasVisibleAssistantContent {
                activeAgentIdentity = nil
            }

            if message.isTransientExecutionError {
                let errorID = "\(message.id).execution-error"
                let title = message.executionErrorTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
                let summary = message.executionErrorMessage?.trimmingCharacters(in: .whitespacesAndNewlines)
                let errorInset: CGFloat = MessageListView.hasAgentIdentity(
                    name: message.metadata["agentName"],
                    emoji: message.metadata["agentEmoji"],
                    avatarURL: message.metadata["agentAvatarURL"]
                ) ? MessageListRowView.agentContentLeadingOffset : 0
                append(
                    .executionError(
                        errorID,
                        ExecutionErrorRepresentation(
                            id: errorID,
                            messageID: message.id,
                            createdAt: message.createdAt,
                            title: title?.isEmpty == false ? title! : String.localized("Request failed"),
                            message: summary?.isEmpty == false ? summary! : textContent,
                            details: message.executionErrorDetails,
                            agentName: message.metadata["agentName"],
                            agentEmoji: message.metadata["agentEmoji"]
                        )
                    ),
                    leadingInset: errorInset
                )
                continue
            }

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
                    append(.userAttachment(message.id, .init(items: attachmentItems, isTrailingAligned: true)), leadingInset: messageLeadingInset)
                }
                if !textContent.isEmpty {
                    append(.userContent(message.id, representation), leadingInset: messageLeadingInset)
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
                            source: MessageSourceRepresentation.make(from: message.metadata),
                            isRevealed: !reasoningPart.isCollapsed,
                            isThinking: isThinking,
                            isInterrupted: message.finishReason == .cancelled,
                            thinkingDuration: reasoningPart.duration,
                            agentName: message.metadata["agentName"],
                            agentEmoji: message.metadata["agentEmoji"]
                        )
                        append(.reasoningContent(reasoningPart.id, reasoningRep), leadingInset: messageLeadingInset)
                    case let .toolCall(tc):
                        let matchingToolResultMessage = firstToolResultMessage(for: tc.id)
                        let matchingResult = matchingToolResultMessage?.result
                        if isTodoWriteToolCall(tc) {
                            if let matchingResult {
                                inlineRenderedToolResultIDs.insert(matchingResult.id)
                            }
                            continue
                        }
                        append(
                            .toolCallHint(
                                tc.id,
                                ToolCallRepresentation(
                                    messageID: matchingToolResultMessage?.messageID ?? message.id,
                                    toolCall: tc,
                                    hasResult: matchingResult != nil,
                                    isExpanded: !(matchingResult?.isCollapsed ?? true)
                                )
                            ),
                            leadingInset: messageLeadingInset
                        )
                        if let matchingResult, !matchingResult.isCollapsed {
                            let representation = ToolResultRepresentation(
                                parameters: tc.parameters,
                                result: matchingResult.result
                            )
                            if !representation.isEmpty {
                                append(
                                    .toolResultContent(matchingResult.id, representation),
                                    leadingInset: messageLeadingInset
                                )
                                inlineRenderedToolResultIDs.insert(matchingResult.id)
                            }
                        }
                    case let .text(textPart):
                        guard !textPart.text.isEmpty else { continue }

                        func appendMarkdown(_ content: String, id: String) {
                            guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                            let textRep = MessageRepresentation(
                                id: id,
                                messageID: message.id,
                                createdAt: message.createdAt,
                                role: message.role,
                                content: content,
                                source: MessageSourceRepresentation.make(from: message.metadata),
                                isRevealed: !reasoningCollapsed,
                                isThinking: false,
                                isInterrupted: message.finishReason == .cancelled,
                                thinkingDuration: 0,
                                agentName: message.metadata["agentName"],
                                agentEmoji: message.metadata["agentEmoji"]
                            )
                            append(.responseContent(id, textRep), leadingInset: messageLeadingInset)
                        }

                        func appendChart(_ spec: ChartSpec, rawBlock: String, id: String) {
                            let chartRep = ChartRepresentation(
                                id: id,
                                messageID: message.id,
                                createdAt: message.createdAt,
                                spec: spec,
                                rawBlock: rawBlock
                            )
                            append(.chartContent(id, chartRep), leadingInset: messageLeadingInset)
                        }

                        func appendMap(_ spec: MapSpec, rawBlock: String, id: String) {
                            let mapRep = MapRepresentation(
                                id: id,
                                messageID: message.id,
                                createdAt: message.createdAt,
                                spec: spec,
                                rawBlock: rawBlock
                            )
                            append(.mapContent(id, mapRep), leadingInset: messageLeadingInset)
                        }

                        func appendMedia(_ media: MarkdownMediaPayload, id: String) {
                            let mediaRep = MediaRepresentation(
                                id: id,
                                messageID: message.id,
                                createdAt: message.createdAt,
                                kind: media.kind,
                                url: media.url,
                                altText: media.altText
                            )
                            append(.mediaContent(id, mediaRep), leadingInset: messageLeadingInset)
                        }

                        func appendMermaid(_ source: String, rawBlock: String, id: String) {
                            let mermaidRep = MermaidRepresentation(
                                id: id,
                                messageID: message.id,
                                createdAt: message.createdAt,
                                source: source,
                                rawBlock: rawBlock
                            )
                            append(.mermaidContent(id, mermaidRep), leadingInset: messageLeadingInset)
                        }

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
                                                let mermaidSegments = MermaidMarkdownParser.parseSegments(from: mediaMarkdown)
                                                for (mermaidIndex, mermaidSegment) in mermaidSegments.enumerated() {
                                                    let idSuffix = "\(index).\(nestedIndex).\(mediaIndex).\(mermaidIndex)"
                                                    switch mermaidSegment {
                                                    case let .markdown(mermaidMarkdown):
                                                        appendMarkdown(mermaidMarkdown, id: "\(textPart.id).md.\(idSuffix)")
                                                    case let .mermaid(source, rawBlock):
                                                        appendMermaid(source, rawBlock: rawBlock, id: "\(textPart.id).mermaid.\(idSuffix)")
                                                    case let .chart(spec, rawBlock):
                                                        appendChart(spec, rawBlock: rawBlock, id: "\(textPart.id).chart.\(idSuffix)")
                                                    case let .map(spec, rawBlock):
                                                        appendMap(spec, rawBlock: rawBlock, id: "\(textPart.id).map.\(idSuffix)")
                                                    case let .media(media):
                                                        appendMedia(media, id: "\(textPart.id).media.\(idSuffix)")
                                                    }
                                                }
                                            case let .media(media):
                                                appendMedia(media, id: "\(textPart.id).media.\(index).\(nestedIndex).\(mediaIndex)")
                                            case let .chart(spec, rawBlock):
                                                appendChart(spec, rawBlock: rawBlock, id: "\(textPart.id).chart.\(index).\(nestedIndex).\(mediaIndex)")
                                            case let .map(spec, rawBlock):
                                                appendMap(spec, rawBlock: rawBlock, id: "\(textPart.id).map.\(index).\(nestedIndex).\(mediaIndex)")
                                            case let .mermaid(source, rawBlock):
                                                appendMermaid(source, rawBlock: rawBlock, id: "\(textPart.id).mermaid.\(index).\(nestedIndex).\(mediaIndex)")
                                            }
                                        }
                                    case let .map(spec, rawBlock):
                                        appendMap(spec, rawBlock: rawBlock, id: "\(textPart.id).map.\(index).\(nestedIndex)")
                                    case let .chart(spec, rawBlock):
                                        appendChart(spec, rawBlock: rawBlock, id: "\(textPart.id).chart.\(index).\(nestedIndex)")
                                    case let .media(media):
                                        appendMedia(media, id: "\(textPart.id).media.\(index).\(nestedIndex)")
                                    case let .mermaid(source, rawBlock):
                                        appendMermaid(source, rawBlock: rawBlock, id: "\(textPart.id).mermaid.\(index).\(nestedIndex)")
                                    }
                                }
                            case let .chart(spec, rawBlock):
                                appendChart(spec, rawBlock: rawBlock, id: "\(textPart.id).chart.\(index)")
                            case let .map(spec, rawBlock):
                                appendMap(spec, rawBlock: rawBlock, id: "\(textPart.id).map.\(index)")
                            case let .media(media):
                                appendMedia(media, id: "\(textPart.id).media.\(index)")
                            case let .mermaid(source, rawBlock):
                                appendMermaid(source, rawBlock: rawBlock, id: "\(textPart.id).mermaid.\(index)")
                            }
                        }
                    case let .file(filePart):
                        let resolvedName = filePart.name ?? String.localized("Document")
                        let storageFilename = filePart.sourceFilePath.map { URL(fileURLWithPath: $0).lastPathComponent }
                            ?? filePart.name
                            ?? "document.txt"
                        let attachment = ChatInputAttachment(
                            type: .document,
                            name: resolvedName,
                            fileData: filePart.data,
                            textContent: filePart.textContent ?? String(data: filePart.data, encoding: .utf8) ?? "",
                            storageFilename: storageFilename,
                            sourceFilePath: filePart.sourceFilePath
                        )
                        append(
                            .userAttachment(
                                "\(message.id).file.\(filePart.id)",
                                .init(items: [attachment], isTrailingAligned: false)
                            ),
                            leadingInset: messageLeadingInset
                        )
                    case let .toolResult(toolResult):
                        continue
                    case .image, .audio:
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
                let assistantMessage = assistantMessage(forToolResult: toolResult.toolCallID, startingAt: messageIndex)
                let toolCall = assistantMessage?.parts.first { part in
                    guard case let .toolCall(value) = part else { return false }
                    return value.id == toolResult.toolCallID
                }
                let parameters: String = {
                    guard case let .toolCall(value)? = toolCall else { return "" }
                    return value.parameters
                }()
                if case let .toolCall(value)? = toolCall, isTodoWriteToolCall(value) {
                    break
                }
                let representation = ToolResultRepresentation(
                    parameters: parameters,
                    result: toolResult.result
                )
                guard !representation.isEmpty else { break }
                append(.toolResultContent(toolResult.id, representation), leadingInset: messageLeadingInset)

            case .system:
                if message.isTodoList, let metadata = message.todoListMetadata {
                    append(
                        .todoList(
                            message.id,
                            TodoListRepresentation(
                                id: message.id,
                                messageID: message.id,
                                createdAt: message.createdAt,
                                metadata: metadata
                            )
                        ),
                        leadingInset: messageLeadingInset
                    )
                    continue
                }

                if message.isSubAgentTask, let metadata = message.subAgentTaskMetadata {
                    append(
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
                        ),
                        leadingInset: messageLeadingInset
                    )
                    continue
                }

                guard message.isCompactBoundary else { break }
                append(
                    .compactBoundary(
                        message.id,
                        CompactBoundaryRepresentation(
                            id: message.id,
                            createdAt: message.createdAt,
                            title: compactBoundaryTitle(for: message.compactBoundaryMetadata),
                            detail: compactBoundaryDetail(for: message.compactBoundaryMetadata)
                        )
                    ),
                    leadingInset: messageLeadingInset
                )

            default:
                continue
            }
        }

        if showsInterruptedRetryAction {
            append(.interruptionRetry(String.localized("Task execution interrupted, please retry.")), leadingInset: 0)
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
