import ChatClient
import ChatUI
import Foundation

final class TranscriptStorageProvider: StorageProvider, @unchecked Sendable {
    private static let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private struct TranscriptContentBlock: Codable {
        struct ImageURL: Codable {
            let url: String
            let detail: String?
        }

        let type: String
        let text: String?
        let imageUrl: ImageURL?
        let toolUseID: String?
        let toolName: String?
        let toolUseState: String?
        let reasoningDuration: Double
    }

    private struct TranscriptMessageRecord: Codable {
        let uuid: String
        let role: String
        let timestamp: String
        let content: [TranscriptContentBlock]
        let toolUseID: String?
        let toolName: String?
        let stopReason: String?
        let metadata: [String: String]?
    }

    private struct UsagePayload: Codable {
        let inputTokens: Int
        let outputTokens: Int
        let cacheReadTokens: Int
        let cacheWriteTokens: Int
        let costUSD: Double?
        let model: String?

        init(_ usage: TokenUsage) {
            inputTokens = usage.inputTokens
            outputTokens = usage.outputTokens
            cacheReadTokens = usage.cacheReadTokens
            cacheWriteTokens = usage.cacheWriteTokens
            costUSD = usage.costUSD
            model = usage.model
        }
    }

    private struct SessionTranscriptEntry: Codable {
        let uuid: String
        let sessionId: String
        let type: String
        let subtype: String?
        let timestamp: String
        let sequence: Int64
        let message: TranscriptMessageRecord?
        let messageUUIDs: [String]?
        let customTitle: String?
        let aiTitle: String?
        let summary: String?
        let toolUseID: String?
        let toolName: String?
        let toolUseState: String?
        let text: String?
        let usage: UsagePayload?
        let isError: Bool?
        let result: String?
    }

    private struct SessionRecord: Codable {
        var key: String
        var kind: String
        var displayName: String
        var updatedAtMs: Int64
        var status: String
        var preview: String?
    }

    private struct SessionEnvelope: Codable {
        var sessions: [SessionRecord]
    }

    private struct ReplayState {
        var messages: [ConversationMessage] = []
        var title: String?
        var updatedAtMs: Int64 = 0
        var status: String = "idle"
        var preview: String?
    }

    private static let providersLock = NSLock()
    private static var providersByRootPath: [String: TranscriptStorageProvider] = [:]

    static func provider(runtimeRootURL: URL) -> TranscriptStorageProvider {
        let resolvedRoot = runtimeRootURL.standardizedFileURL
        let key = resolvedRoot.path
        providersLock.lock()
        defer { providersLock.unlock() }
        if let provider = providersByRootPath[key] {
            return provider
        }
        let provider = TranscriptStorageProvider(runtimeRootURL: resolvedRoot)
        providersByRootPath[key] = provider
        return provider
    }

    static func removeProvider(runtimeRootURL: URL) {
        let resolvedRoot = runtimeRootURL.standardizedFileURL
        let key = resolvedRoot.path
        providersLock.lock()
        defer { providersLock.unlock() }
        providersByRootPath.removeValue(forKey: key)
    }

    private let runtimeRootURL: URL
    private let sessionsDir: URL
    private let indexPath: URL
    private let lock = NSLock()

    private var messagesBySession: [String: [ConversationMessage]] = [:]
    private var loadedSessions = Set<String>()
    private var sessionsByKey: [String: SessionRecord] = [:]
    private var nextSequenceByConversation: [String: Int64] = [:]
    private var didLoadSessions = false

    private init(runtimeRootURL: URL) {
        self.runtimeRootURL = runtimeRootURL
        sessionsDir = runtimeRootURL.appendingPathComponent("sessions", isDirectory: true)
        indexPath = runtimeRootURL.appendingPathComponent("session_index.json", isDirectory: false)
        prepareDirectories()
    }

    func listSessions() -> [ChatSession] {
        lock.lock()
        loadSessionsIfNeededLocked()
        let sorted = sessionsByKey.values.sorted { $0.updatedAtMs > $1.updatedAtMs }
        lock.unlock()
        return sorted.map { ChatSession(key: $0.key, displayName: $0.displayName, updatedAt: $0.updatedAtMs) }
    }

    func createMessage(in sessionID: String, role: MessageRole) -> ConversationMessage {
        ConversationMessage(sessionID: sessionID, role: role)
    }

    func save(_ messages: [ConversationMessage]) {
        guard let sessionID = messages.first?.sessionID else { return }
        let sortedMessages = messages.sorted { $0.createdAt < $1.createdAt }

        lock.lock()
        ensureSessionLoadedLocked(sessionID)

        let previousMessages = messagesBySession[sessionID] ?? []
        let previousByID = Dictionary(uniqueKeysWithValues: previousMessages.map { ($0.id, $0) })
        let nextByID = Dictionary(uniqueKeysWithValues: sortedMessages.map { ($0.id, $0) })
        let removedIDs = previousMessages.map(\.id).filter { nextByID[$0] == nil }

        if let summaryMessage = sortedMessages.first(where: { isCompactionSummary($0) }), !removedIDs.isEmpty {
            appendTranscriptEntryLocked(
                type: "summary",
                sessionID: sessionID,
                message: makeTranscriptMessageRecord(from: summaryMessage),
                messageUUIDs: removedIDs,
                summary: summaryText(from: summaryMessage)
            )
            appendTranscriptEntryLocked(
                type: "system",
                subtype: "compact_boundary",
                sessionID: sessionID,
                messageUUIDs: removedIDs,
                summary: summaryText(from: summaryMessage)
            )
        } else if !removedIDs.isEmpty {
            appendTranscriptEntryLocked(type: "messages-deleted", sessionID: sessionID, messageUUIDs: removedIDs)
        }

        for message in sortedMessages {
            let previous = previousByID[message.id]
            if transcriptSignature(for: previous) == transcriptSignature(for: message) {
                continue
            }

            appendToolDiffEntriesLocked(sessionID: sessionID, previous: previous, current: message)

            if isCompactionSummary(message), !removedIDs.isEmpty {
                continue
            }

            appendTranscriptEntryLocked(
                type: message.role.rawValue,
                sessionID: sessionID,
                message: makeTranscriptMessageRecord(from: message)
            )
        }

        messagesBySession[sessionID] = sortedMessages
        upsertSessionLocked(
            for: sessionID,
            titleOverride: nil,
            previewOverride: previewText(from: sortedMessages),
            statusOverride: sessionsByKey[sessionID]?.status
        )
        persistSessionsLocked()
        lock.unlock()
    }

    func messages(in sessionID: String) -> [ConversationMessage] {
        lock.lock()
        ensureSessionLoadedLocked(sessionID)
        let messages = messagesBySession[sessionID] ?? []
        lock.unlock()
        return messages.sorted { $0.createdAt < $1.createdAt }
    }

    func delete(_ messageIDs: [String]) {
        guard !messageIDs.isEmpty else { return }
        lock.lock()
        var changedSessions: [String] = []
        for (sessionID, messages) in messagesBySession {
            let filtered = messages.filter { !messageIDs.contains($0.id) }
            if filtered.count != messages.count {
                messagesBySession[sessionID] = filtered
                appendTranscriptEntryLocked(type: "messages-deleted", sessionID: sessionID, messageUUIDs: messageIDs)
                upsertSessionLocked(
                    for: sessionID,
                    titleOverride: nil,
                    previewOverride: previewText(from: filtered),
                    statusOverride: sessionsByKey[sessionID]?.status
                )
                changedSessions.append(sessionID)
            }
        }
        if !changedSessions.isEmpty {
            persistSessionsLocked()
        }
        lock.unlock()
    }

    func title(for id: String) -> String? {
        lock.lock()
        loadSessionsIfNeededLocked()
        let title = sessionsByKey[id]?.displayName
        lock.unlock()
        return title
    }

    func setTitle(_ title: String, for id: String) {
        lock.lock()
        loadSessionsIfNeededLocked()
        let currentTitle = sessionsByKey[id]?.displayName
        guard currentTitle != title else {
            lock.unlock()
            return
        }
        upsertSessionLocked(
            for: id,
            titleOverride: title,
            previewOverride: sessionsByKey[id]?.preview,
            statusOverride: sessionsByKey[id]?.status
        )
        appendTranscriptEntryLocked(type: "ai-title", sessionID: id, aiTitle: title)
        persistSessionsLocked()
        lock.unlock()
    }

    func recordTurnStarted(sessionID: String) {
        recordLifecycleEntry(
            type: "system",
            subtype: "status",
            sessionID: sessionID,
            status: "executing",
            text: "executing"
        )
    }

    func recordTurnFinished(sessionID: String, success: Bool, errorDescription: String?) {
        recordLifecycleEntry(
            type: "result",
            subtype: success ? "success" : "error",
            sessionID: sessionID,
            status: success ? "idle" : "failed",
            isError: !success,
            result: errorDescription
        )
    }

    func recordTurnInterrupted(sessionID: String, reason: String) {
        recordLifecycleEntry(
            type: "result",
            subtype: "interrupted",
            sessionID: sessionID,
            status: "interrupted",
            isError: true,
            result: reason
        )
    }

    func recordUsage(_ usage: TokenUsage, sessionID: String) {
        lock.lock()
        appendTranscriptEntryLocked(type: "usage", sessionID: sessionID, usage: UsagePayload(usage))
        upsertSessionLocked(
            for: sessionID,
            titleOverride: sessionsByKey[sessionID]?.displayName,
            previewOverride: sessionsByKey[sessionID]?.preview,
            statusOverride: sessionsByKey[sessionID]?.status
        )
        persistSessionsLocked()
        lock.unlock()
    }

    private func recordLifecycleEntry(
        type: String,
        subtype: String,
        sessionID: String,
        status: String,
        text: String? = nil,
        isError: Bool? = nil,
        result: String? = nil
    ) {
        lock.lock()
        appendTranscriptEntryLocked(
            type: type,
            subtype: subtype,
            sessionID: sessionID,
            text: text,
            isError: isError,
            result: result
        )
        upsertSessionLocked(
            for: sessionID,
            titleOverride: sessionsByKey[sessionID]?.displayName,
            previewOverride: sessionsByKey[sessionID]?.preview,
            statusOverride: status
        )
        persistSessionsLocked()
        lock.unlock()
    }

    private func prepareDirectories() {
        try? FileManager.default.createDirectory(at: runtimeRootURL, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
    }

    private func sessionDirectory(for sessionID: String) -> URL {
        let safeKey = sessionID
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
        return sessionsDir.appendingPathComponent(safeKey, isDirectory: true)
    }

    private func transcriptPath(for sessionID: String) -> URL {
        sessionDirectory(for: sessionID).appendingPathComponent("transcript.jsonl", isDirectory: false)
    }

    private func ensureSessionLoadedLocked(_ sessionID: String) {
        guard !loadedSessions.contains(sessionID) else { return }
        let replayState = replayStateLocked(for: sessionID)
        messagesBySession[sessionID] = replayState.messages
        nextSequenceByConversation[sessionID] = replayState.updatedAtMs == 0 ? 0 : loadTranscriptEntriesLocked(sessionID).last?.sequence ?? 0
        if replayState.title != nil || replayState.preview != nil {
            upsertSessionLocked(
                for: sessionID,
                titleOverride: replayState.title,
                previewOverride: replayState.preview,
                statusOverride: replayState.status
            )
            persistSessionsLocked()
        }
        loadedSessions.insert(sessionID)
    }

    private func replayStateLocked(for sessionID: String) -> ReplayState {
        var state = ReplayState()
        for entry in loadTranscriptEntriesLocked(sessionID) {
            state.updatedAtMs = max(state.updatedAtMs, timestampMs(from: entry.timestamp))
            switch entry.type {
            case MessageRole.user.rawValue, MessageRole.assistant.rawValue, MessageRole.system.rawValue:
                guard let record = entry.message else { continue }
                upsertMessage(
                    makeConversationMessage(from: record, sessionID: sessionID),
                    into: &state.messages
                )
                state.preview = previewText(from: state.messages)
            case "summary":
                if let messageUUIDs = entry.messageUUIDs, !messageUUIDs.isEmpty {
                    state.messages.removeAll { messageUUIDs.contains($0.id) }
                }
                if let record = entry.message {
                    upsertMessage(
                        makeConversationMessage(from: record, sessionID: sessionID),
                        into: &state.messages
                    )
                }
                state.preview = previewText(from: state.messages)
            case "messages-deleted":
                if let messageUUIDs = entry.messageUUIDs, !messageUUIDs.isEmpty {
                    state.messages.removeAll { messageUUIDs.contains($0.id) }
                    state.preview = previewText(from: state.messages)
                }
            case "custom-title":
                if let customTitle = entry.customTitle, !customTitle.isEmpty {
                    state.title = customTitle
                }
            case "ai-title":
                if state.title?.isEmpty ?? true, let aiTitle = entry.aiTitle, !aiTitle.isEmpty {
                    state.title = aiTitle
                }
            case "system":
                if entry.subtype == "status", entry.text == "executing" {
                    state.status = "executing"
                }
            case "result":
                switch entry.subtype {
                case "error":
                    state.status = "failed"
                case "interrupted":
                    state.status = "interrupted"
                default:
                    state.status = "idle"
                }
            default:
                continue
            }
        }
        state.messages.sort { $0.createdAt < $1.createdAt }
        if state.preview == nil {
            state.preview = previewText(from: state.messages)
        }
        return state
    }

    private func upsertMessage(_ message: ConversationMessage, into messages: inout [ConversationMessage]) {
        if let index = messages.firstIndex(where: { $0.id == message.id }) {
            messages[index] = message
        } else {
            messages.append(message)
        }
    }

    private func loadTranscriptEntriesLocked(_ sessionID: String) -> [SessionTranscriptEntry] {
        let fileURL = transcriptPath(for: sessionID)
        guard let data = try? Data(contentsOf: fileURL),
              let text = String(data: data, encoding: .utf8)
        else {
            return []
        }

        var entries: [SessionTranscriptEntry] = []
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty,
                  let lineData = line.data(using: .utf8),
                  let entry = try? JSONDecoder().decode(SessionTranscriptEntry.self, from: lineData)
            else {
                continue
            }
            entries.append(entry)
        }
        return entries.sorted { lhs, rhs in
            if lhs.sequence == rhs.sequence {
                return lhs.timestamp < rhs.timestamp
            }
            return lhs.sequence < rhs.sequence
        }
    }

    private func appendTranscriptEntryLocked(
        type: String,
        subtype: String? = nil,
        sessionID: String,
        message: TranscriptMessageRecord? = nil,
        messageUUIDs: [String]? = nil,
        customTitle: String? = nil,
        aiTitle: String? = nil,
        summary: String? = nil,
        toolUseID: String? = nil,
        toolName: String? = nil,
        toolUseState: String? = nil,
        text: String? = nil,
        usage: UsagePayload? = nil,
        isError: Bool? = nil,
        result: String? = nil
    ) {
        let timestamp = Self.iso8601Formatter.string(from: Date())
        let nextSequence = (nextSequenceByConversation[sessionID] ?? 0) + 1
        nextSequenceByConversation[sessionID] = nextSequence
        let entry = SessionTranscriptEntry(
            uuid: UUID().uuidString,
            sessionId: sessionID,
            type: type,
            subtype: subtype,
            timestamp: timestamp,
            sequence: nextSequence,
            message: message,
            messageUUIDs: messageUUIDs,
            customTitle: customTitle,
            aiTitle: aiTitle,
            summary: summary,
            toolUseID: toolUseID,
            toolName: toolName,
            toolUseState: toolUseState,
            text: text,
            usage: usage,
            isError: isError,
            result: result
        )

        let directoryURL = sessionDirectory(for: sessionID)
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(entry),
              let text = String(data: data, encoding: .utf8)
        else {
            return
        }

        let fileURL = transcriptPath(for: sessionID)
        let handle: FileHandle
        if FileManager.default.fileExists(atPath: fileURL.path) {
            guard let existingHandle = try? FileHandle(forWritingTo: fileURL) else { return }
            handle = existingHandle
            try? handle.seekToEnd()
        } else {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
            guard let createdHandle = try? FileHandle(forWritingTo: fileURL) else { return }
            handle = createdHandle
        }
        defer { try? handle.close() }
        try? handle.write(contentsOf: Data((text + "\n").utf8))
    }

    private func appendToolDiffEntriesLocked(
        sessionID: String,
        previous: ConversationMessage?,
        current: ConversationMessage
    ) {
        let previousToolCalls = Dictionary(uniqueKeysWithValues: toolCallParts(in: previous).map { ($0.id, $0) })
        let currentToolCalls = toolCallParts(in: current)
        for toolCall in currentToolCalls where previousToolCalls[toolCall.id] == nil {
            appendTranscriptEntryLocked(
                type: "tool_progress",
                sessionID: sessionID,
                toolUseID: toolCall.id,
                toolName: toolCall.apiName.isEmpty ? toolCall.toolName : toolCall.apiName,
                toolUseState: toolCall.state.rawValue,
                text: toolCall.parameters
            )
        }

        let previousToolResults = Set(toolResultParts(in: previous).map(toolResultIdentity(_:)))
        for toolResult in toolResultParts(in: current) where !previousToolResults.contains(toolResultIdentity(toolResult)) {
            appendTranscriptEntryLocked(
                type: "tool_use_summary",
                sessionID: sessionID,
                toolUseID: toolResult.toolCallID,
                text: toolResult.result
            )
        }
    }

    private func toolCallParts(in message: ConversationMessage?) -> [ToolCallContentPart] {
        guard let message else { return [] }
        return message.parts.compactMap { part in
            guard case let .toolCall(value) = part else { return nil }
            return value
        }
    }

    private func toolResultParts(in message: ConversationMessage?) -> [ToolResultContentPart] {
        guard let message else { return [] }
        return message.parts.compactMap { part in
            guard case let .toolResult(value) = part else { return nil }
            return value
        }
    }

    private func toolResultIdentity(_ part: ToolResultContentPart) -> String {
        "\(part.toolCallID)|\(part.result)"
    }

    private func transcriptSignature(for message: ConversationMessage?) -> String? {
        guard let message,
              let record = makeTranscriptMessageRecord(from: message),
              let data = try? JSONEncoder().encode(record)
        else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private func isCompactionSummary(_ message: ConversationMessage) -> Bool {
        message.isCompactionSummary
    }

    private func previewText(from messages: [ConversationMessage]) -> String? {
        for message in messages.reversed() {
            if message.isCompactBoundary {
                continue
            }
            let trimmed = message.textContent.trimmingCharacters(in: .whitespacesAndNewlines)
            if ConversationMarkers.isToolUseSummary(trimmed) {
                continue
            }
            if !trimmed.isEmpty {
                return String(trimmed.prefix(120))
            }
        }
        return nil
    }

    private func summaryText(from message: ConversationMessage) -> String? {
        let trimmed = message.textContent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if message.isCompactBoundary {
            return message.compactBoundaryMetadata?.messagesSummarized.map { "messages_summarized=\($0)" }
        }
        if message.isCompactionSummary {
            return ConversationMarkers.stripContextSummaryPrefix(from: trimmed)
        }
        return trimmed
    }

    private func makeTranscriptMessageRecord(from message: ConversationMessage) -> TranscriptMessageRecord? {
        let blocks = mapContentBlocks(from: message.parts)
        let fallbackBlock = TranscriptContentBlock(
            type: "text",
            text: message.textContent,
            imageUrl: nil,
            toolUseID: nil,
            toolName: nil,
            toolUseState: nil,
            reasoningDuration: 0
        )
        let storedBlocks = blocks.isEmpty ? [fallbackBlock] : blocks
        let firstToolCall = firstToolCallPart(in: message.parts)
        let firstToolResult = firstToolResultPart(in: message.parts)

        return TranscriptMessageRecord(
            uuid: message.id,
            role: message.role.rawValue,
            timestamp: Self.iso8601Formatter.string(from: message.createdAt),
            content: storedBlocks,
            toolUseID: firstToolResult?.toolCallID,
            toolName: firstToolCall?.toolName,
            stopReason: message.finishReason?.rawValue,
            metadata: message.metadata.isEmpty ? nil : message.metadata
        )
    }

    private func mapContentBlocks(from parts: [ContentPart]) -> [TranscriptContentBlock] {
        parts.compactMap { part in
            switch part {
            case let .text(textPart):
                return TranscriptContentBlock(
                    type: "text",
                    text: textPart.text,
                    imageUrl: nil,
                    toolUseID: nil,
                    toolName: nil,
                    toolUseState: nil,
                    reasoningDuration: 0
                )
            case let .reasoning(reasoningPart):
                return TranscriptContentBlock(
                    type: "reasoning",
                    text: reasoningPart.text,
                    imageUrl: nil,
                    toolUseID: nil,
                    toolName: nil,
                    toolUseState: nil,
                    reasoningDuration: reasoningPart.duration
                )
            case let .toolCall(toolCallPart):
                return TranscriptContentBlock(
                    type: "tool_use",
                    text: toolCallPart.parameters,
                    imageUrl: nil,
                    toolUseID: toolCallPart.id,
                    toolName: toolCallPart.toolName,
                    toolUseState: toolCallPart.state.rawValue,
                    reasoningDuration: 0
                )
            case let .toolResult(resultPart):
                return TranscriptContentBlock(
                    type: "tool_result",
                    text: resultPart.result,
                    imageUrl: nil,
                    toolUseID: resultPart.toolCallID,
                    toolName: nil,
                    toolUseState: nil,
                    reasoningDuration: 0
                )
            case let .image(imagePart):
                let label = imagePart.name ?? "image"
                return TranscriptContentBlock(
                    type: "image",
                    text: "[\(label)]",
                    imageUrl: nil,
                    toolUseID: nil,
                    toolName: nil,
                    toolUseState: nil,
                    reasoningDuration: 0
                )
            case let .audio(audioPart):
                let label = audioPart.name ?? "audio"
                return TranscriptContentBlock(
                    type: "audio",
                    text: "[\(label)]",
                    imageUrl: nil,
                    toolUseID: nil,
                    toolName: nil,
                    toolUseState: nil,
                    reasoningDuration: 0
                )
            case let .file(filePart):
                let label = filePart.name ?? "file"
                return TranscriptContentBlock(
                    type: "file",
                    text: "[\(label)]",
                    imageUrl: nil,
                    toolUseID: nil,
                    toolName: nil,
                    toolUseState: nil,
                    reasoningDuration: 0
                )
            }
        }
    }

    private func firstToolCallPart(in parts: [ContentPart]) -> ToolCallContentPart? {
        for part in parts {
            if case let .toolCall(value) = part {
                return value
            }
        }
        return nil
    }

    private func firstToolResultPart(in parts: [ContentPart]) -> ToolResultContentPart? {
        for part in parts {
            if case let .toolResult(value) = part {
                return value
            }
        }
        return nil
    }

    private func makeConversationMessage(from record: TranscriptMessageRecord, sessionID: String) -> ConversationMessage {
        let createdAt = Self.iso8601Formatter.date(from: record.timestamp) ?? Date(timeIntervalSince1970: 0)
        var metadata = record.metadata ?? [:]
        if let stopReason = record.stopReason {
            metadata["finishReason"] = stopReason
        }
        return ConversationMessage(
            id: record.uuid,
            sessionID: sessionID,
            role: MessageRole(rawValue: record.role),
            parts: mapParts(from: record),
            createdAt: createdAt,
            metadata: metadata
        )
    }

    private func mapParts(from record: TranscriptMessageRecord) -> [ContentPart] {
        var result: [ContentPart] = []
        for block in record.content {
            switch block.type {
            case "reasoning":
                if let text = block.text {
                    result.append(.reasoning(ReasoningContentPart(text: text, duration: block.reasoningDuration)))
                }
            case "tool_use":
                let toolName = block.toolName ?? record.toolName ?? "Tool"
                let parameters = block.text ?? "{}"
                let toolUseState = ToolCallState(rawValue: block.toolUseState ?? "") ?? .succeeded
                result.append(
                    .toolCall(
                        ToolCallContentPart(
                            id: block.toolUseID ?? record.toolUseID ?? UUID().uuidString,
                            toolName: toolName,
                            parameters: parameters,
                            state: toolUseState
                        )
                    )
                )
            case "tool_result":
                let toolUseID = block.toolUseID ?? record.toolUseID ?? UUID().uuidString
                result.append(
                    .toolResult(
                        ToolResultContentPart(
                            toolCallID: toolUseID,
                            result: block.text ?? "",
                            isCollapsed: true
                        )
                    )
                )
            default:
                if let text = block.text {
                    result.append(.text(TextContentPart(text: text)))
                }
            }
        }
        return result
    }

    private func timestampMs(from timestamp: String) -> Int64 {
        guard let date = Self.iso8601Formatter.date(from: timestamp) else { return 0 }
        return Int64(date.timeIntervalSince1970 * 1000)
    }

    private func loadSessionsIfNeededLocked() {
        guard !didLoadSessions else { return }
        didLoadSessions = true
        guard let data = try? Data(contentsOf: indexPath),
              let envelope = try? JSONDecoder().decode(SessionEnvelope.self, from: data)
        else {
            sessionsByKey = [:]
            return
        }
        sessionsByKey = Dictionary(uniqueKeysWithValues: envelope.sessions.map { ($0.key, $0) })
    }

    private func upsertSessionLocked(
        for sessionID: String,
        titleOverride: String?,
        previewOverride: String?,
        statusOverride: String?
    ) {
        loadSessionsIfNeededLocked()
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let existing = sessionsByKey[sessionID]
        let resolvedTitle = titleOverride ?? existing?.displayName ?? sessionID

        sessionsByKey[sessionID] = SessionRecord(
            key: sessionID,
            kind: existing?.kind ?? "chat",
            displayName: resolvedTitle,
            updatedAtMs: now,
            status: statusOverride ?? existing?.status ?? "idle",
            preview: previewOverride ?? existing?.preview
        )
    }

    private func persistSessionsLocked() {
        let sorted = sessionsByKey.values.sorted { $0.updatedAtMs > $1.updatedAtMs }
        let envelope = SessionEnvelope(sessions: sorted)
        guard let data = try? JSONEncoder().encode(envelope) else { return }
        try? data.write(to: indexPath, options: [.atomic])
    }
}
