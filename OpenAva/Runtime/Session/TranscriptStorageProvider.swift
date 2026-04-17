import ChatClient
import ChatUI
import Foundation

// MARK: - Transcript Entry Types

/// Entry types for the JSONL transcript.
/// Only chain participants (user, assistant, system) advance the parentUuid chain.
/// All other entries are metadata that sit outside the chain.
private enum TranscriptEntryKind: String {
    case user
    case assistant
    case system
    case summary
    case compactBoundary
    case aiTitle
    case customTitle
    case lastPrompt
    case toolProgress
    case toolUseSummary
    case usage
    case messagesDeleted
    case status
    case tag

    /// Whether this entry kind participates in the parentUuid chain.
    var isChainParticipant: Bool {
        switch self {
        case .user, .assistant, .system: return true
        default: return false
        }
    }
}

// MARK: - TranscriptStorageProvider

final class TranscriptStorageProvider: StorageProvider, @unchecked Sendable {
    private static let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// File size threshold for using optimized stream reading.
    /// Files larger than this will skip pre-compact data during load.
    private static let skipPreCompactThreshold: Int = 5 * 1024 * 1024 // 5 MB

    // MARK: - Codable Types

    private struct TranscriptContentBlock: Codable {
        struct ImageURL: Codable {
            let url: String
            let detail: String?
        }

        let type: String
        var text: String?
        var imageUrl: ImageURL?
        var toolUseID: String?
        var toolName: String?
        var apiName: String?
        var toolUseState: String?
        var reasoningDuration: Double = 0
        var isCollapsed: Bool?
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

    /// The on-disk transcript entry. Every line in transcript.jsonl is one of these.
    /// Messages (user/assistant/system) carry parentUuid to form a chain;
    /// metadata entries (title, status, etc.) have parentUuid = nil.
    /// compact_boundary entries set parentUuid = nil (chain break) but preserve
    /// logicalParentUuid for cross-boundary relationship tracking.
    private struct SessionTranscriptEntry: Codable {
        let uuid: String
        let parentUuid: String?
        let logicalParentUuid: String? // preserved for compact_boundary cross-boundary tracking
        let sessionId: String
        let type: String
        let subtype: String?
        let timestamp: String
        let sequence: Int64
        let message: TranscriptMessageRecord?
        let messageUUIDs: [String]?
        let customTitle: String?
        let aiTitle: String?
        let lastPrompt: String?
        let summary: String?
        let tag: String?
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
        var lastPrompt: String?
    }

    private struct SessionEnvelope: Codable {
        var sessions: [SessionRecord]
    }

    // MARK: - Replay State

    private struct ReplayState {
        var messages: [ConversationMessage] = []
        var title: String?
        var customTitle: String?
        var aiTitle: String?
        var updatedAtMs: Int64 = 0
        var status: String = "idle"
        var preview: String?
        var lastPrompt: String?
    }

    private enum ReplayMode {
        case compactedContext
        case fullHistory
    }

    // MARK: - Interruption Detection

    enum InterruptionKind {
        case none
        case interruptedPrompt // user sent message but no assistant reply started
        case interruptedTurn // assistant reply was in progress when interrupted
    }

    // MARK: - Singleton Cache

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
        providersByRootPath.removeValue(forKey: key)
        providersLock.unlock()
    }

    // MARK: - Instance State

    private let runtimeRootURL: URL
    private let sessionsDir: URL
    private let indexPath: URL
    private let lock = NSLock()

    /// In-memory message cache by session. Kept in sync with the chain.
    private var messagesBySession: [String: [ConversationMessage]] = [:]
    private var loadedSessions = Set<String>()
    private var sessionsByKey: [String: SessionRecord] = [:]
    private var nextSequenceByConversation: [String: Int64] = [:]
    private var didLoadSessions = false

    /// Tracks the last chain-participant UUID per session so we can
    /// set parentUuid correctly on the next append.
    private var lastChainUuidBySession: [String: String] = [:]

    /// Tracks which message UUIDs are already on disk, for dedup.
    private var recordedUuidsBySession: [String: Set<String>] = [:]

    /// Tracks the most recently appended entry UUID per session.
    /// Avoids reading the last line of the file after each append.
    private var lastAppendedEntryUuidBySession: [String: String] = [:]

    private init(runtimeRootURL: URL) {
        self.runtimeRootURL = runtimeRootURL
        sessionsDir = runtimeRootURL.appendingPathComponent("sessions", isDirectory: true)
        indexPath = runtimeRootURL.appendingPathComponent("session_index.json", isDirectory: false)
        prepareDirectories()
    }

    func flushTranscript() {
        // Synchronous writes — nothing to flush.
    }

    // MARK: - StorageProvider Conformance

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

    // MARK: - save() — Diff-based append with chain structure

    func save(_ messages: [ConversationMessage]) {
        guard let sessionID = messages.first?.sessionID else { return }
        let sortedMessages = messages.sorted { $0.createdAt < $1.createdAt }

        lock.lock()
        ensureSessionLoadedLocked(sessionID)

        let previousMessages = messagesBySession[sessionID] ?? []
        let previousByID = Dictionary(uniqueKeysWithValues: previousMessages.map { ($0.id, $0) })
        let nextByID = Dictionary(uniqueKeysWithValues: sortedMessages.map { ($0.id, $0) })
        let removedIDs = previousMessages.map(\.id).filter { nextByID[$0] == nil }

        if let summaryMessage = sortedMessages.first(where: { $0.isCompactionSummary }), !removedIDs.isEmpty {
            // Compaction: summary entry gets parentUuid=null (chain root),
            // compact_boundary also gets parentUuid=null but preserves logicalParentUuid.
            let logicalParent = lastChainUuidBySession[sessionID]
            appendEntryLocked(
                type: "summary",
                sessionID: sessionID,
                parentUuid: nil,
                message: makeTranscriptMessageRecord(from: summaryMessage),
                messageUUIDs: removedIDs,
                summary: summaryText(from: summaryMessage)
            )
            appendEntryLocked(
                type: "system",
                subtype: "compact_boundary",
                sessionID: sessionID,
                parentUuid: nil,
                logicalParentUuid: logicalParent,
                messageUUIDs: removedIDs,
                summary: summaryText(from: summaryMessage)
            )
            // After compaction boundary, reset chain cursor.
            if let boundaryUuid = lastAppendedEntryUuidBySession[sessionID] {
                lastChainUuidBySession[sessionID] = boundaryUuid
            }
            // Re-append metadata so it stays in the tail window.
            reAppendMetadataLocked(sessionID: sessionID)
        } else if !removedIDs.isEmpty {
            appendEntryLocked(
                type: "messages-deleted",
                sessionID: sessionID,
                parentUuid: nil,
                messageUUIDs: removedIDs
            )
        }

        for message in sortedMessages {
            let previous = previousByID[message.id]

            // Dedup: skip messages already on disk.
            if let recorded = recordedUuidsBySession[sessionID], recorded.contains(message.id) {
                if transcriptSignature(for: previous) == transcriptSignature(for: message) {
                    continue
                }
                // Changed: append an update entry.
            }

            appendToolDiffEntriesLocked(sessionID: sessionID, previous: previous, current: message)

            if message.isCompactionSummary, !removedIDs.isEmpty {
                continue
            }

            let kind: TranscriptEntryKind
            switch message.role {
            case .user: kind = .user
            case .assistant: kind = .assistant
            default: kind = .system
            }

            let isUpdate = recordedUuidsBySession[sessionID]?.contains(message.id) ?? false
            let parentUuid: String? = if isUpdate {
                nil // update entries don't participate in chain
            } else {
                lastChainUuidBySession[sessionID]
            }

            appendEntryLocked(
                type: message.role.rawValue,
                sessionID: sessionID,
                parentUuid: parentUuid,
                message: makeTranscriptMessageRecord(from: message)
            )

            // Record UUID and advance chain cursor for new chain participants.
            if !isUpdate {
                recordedUuidsBySession[sessionID, default: []].insert(message.id)
                if kind.isChainParticipant, let newUuid = lastAppendedEntryUuidBySession[sessionID] {
                    lastChainUuidBySession[sessionID] = newUuid
                }
            }
        }

        messagesBySession[sessionID] = sortedMessages.map(copyMessage(_:))
        upsertSessionLocked(
            for: sessionID,
            titleOverride: nil,
            previewOverride: previewText(from: sortedMessages),
            lastPromptOverride: nil,
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
        return messages.sorted { $0.createdAt < $1.createdAt }.map(copyMessage(_:))
    }

    func sessionStatus(for sessionID: String) -> String {
        lock.lock()
        ensureSessionLoadedLocked(sessionID)
        let status = sessionsByKey[sessionID]?.status ?? "idle"
        lock.unlock()
        return status
    }

    func fullHistoryMessages(in sessionID: String) -> [ConversationMessage] {
        lock.lock()
        let messages = replayStateLocked(for: sessionID, mode: .fullHistory).messages
        lock.unlock()
        return messages.sorted { $0.createdAt < $1.createdAt }.map(copyMessage(_:))
    }

    func delete(_ messageIDs: [String]) {
        guard !messageIDs.isEmpty else { return }
        lock.lock()
        var changedSessions: [String] = []
        for (sessionID, messages) in messagesBySession {
            let filtered = messages.filter { !messageIDs.contains($0.id) }
            if filtered.count != messages.count {
                messagesBySession[sessionID] = filtered
                appendEntryLocked(
                    type: "messages-deleted",
                    sessionID: sessionID,
                    parentUuid: nil,
                    messageUUIDs: messageIDs
                )
                upsertSessionLocked(
                    for: sessionID,
                    titleOverride: nil,
                    previewOverride: previewText(from: filtered),
                    lastPromptOverride: nil,
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
            lastPromptOverride: sessionsByKey[id]?.lastPrompt,
            statusOverride: sessionsByKey[id]?.status
        )
        // User-set title uses customTitle (takes priority over aiTitle).
        appendEntryLocked(
            type: "custom-title",
            sessionID: id,
            parentUuid: nil,
            customTitle: title
        )
        persistSessionsLocked()
        lock.unlock()
    }

    func recordTranscript(_ event: TranscriptEvent, for sessionID: String) {
        switch event {
        case let .syncMessages(messages):
            save(messages)
        case let .appendMessage(message):
            appendMessage(message, to: sessionID)
        case let .updateMessage(message):
            appendMessageUpdate(message, to: sessionID)
        case let .deleteMessages(messageIDs):
            delete(messageIDs)
        case let .setTitle(title):
            setTitle(title, for: sessionID)
        case let .recordAITitle(title):
            recordAITitle(title, sessionID: sessionID)
        case let .recordLastPrompt(prompt):
            recordLastPrompt(prompt, sessionID: sessionID)
        case .turnStarted:
            recordTurnStarted(sessionID: sessionID)
        case let .turnFinished(success, errorDescription):
            recordTurnFinished(sessionID: sessionID, success: success, errorDescription: errorDescription)
        case let .turnInterrupted(reason):
            recordTurnInterrupted(sessionID: sessionID, reason: reason)
        case let .usage(usage):
            recordUsage(usage, sessionID: sessionID)
        }
    }

    func recordSidechainTranscript(_ event: TranscriptEvent, for sessionID: String) {
        recordTranscript(event, for: sessionID)
    }

    // MARK: - Incremental Append API

    /// Append a single message to the transcript immediately.
    func appendMessage(_ message: ConversationMessage, to sessionID: String) {
        lock.lock()
        ensureSessionLoadedLocked(sessionID)

        // Dedup: skip if already recorded.
        if recordedUuidsBySession[sessionID]?.contains(message.id) == true {
            lock.unlock()
            return
        }

        let kind: TranscriptEntryKind
        switch message.role {
        case .user: kind = .user
        case .assistant: kind = .assistant
        default: kind = .system
        }

        appendEntryLocked(
            type: message.role.rawValue,
            sessionID: sessionID,
            parentUuid: lastChainUuidBySession[sessionID],
            message: makeTranscriptMessageRecord(from: message)
        )

        recordedUuidsBySession[sessionID, default: []].insert(message.id)
        if kind.isChainParticipant, let newUuid = lastAppendedEntryUuidBySession[sessionID] {
            lastChainUuidBySession[sessionID] = newUuid
        }

        // Update in-memory cache.
        upsertMessage(copyMessage(message), into: &messagesBySession[sessionID, default: []])
        upsertSessionLocked(
            for: sessionID,
            titleOverride: nil,
            previewOverride: previewText(from: messagesBySession[sessionID] ?? []),
            lastPromptOverride: lastPromptText(from: message),
            statusOverride: sessionsByKey[sessionID]?.status
        )
        persistSessionsLocked()
        lock.unlock()
    }

    /// Append a message update (content changed for an existing UUID).
    func appendMessageUpdate(_ message: ConversationMessage, to sessionID: String) {
        lock.lock()
        ensureSessionLoadedLocked(sessionID)

        appendEntryLocked(
            type: message.role.rawValue,
            sessionID: sessionID,
            parentUuid: nil,
            message: makeTranscriptMessageRecord(from: message)
        )

        // Update in-memory cache.
        upsertMessage(copyMessage(message), into: &messagesBySession[sessionID, default: []])
        upsertSessionLocked(
            for: sessionID,
            titleOverride: nil,
            previewOverride: previewText(from: messagesBySession[sessionID] ?? []),
            lastPromptOverride: nil,
            statusOverride: sessionsByKey[sessionID]?.status
        )
        persistSessionsLocked()
        lock.unlock()
    }

    // MARK: - Lifecycle Recording

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
        appendEntryLocked(
            type: "usage",
            sessionID: sessionID,
            parentUuid: nil,
            usage: UsagePayload(usage)
        )
        upsertSessionLocked(
            for: sessionID,
            titleOverride: sessionsByKey[sessionID]?.displayName,
            previewOverride: sessionsByKey[sessionID]?.preview,
            lastPromptOverride: sessionsByKey[sessionID]?.lastPrompt,
            statusOverride: sessionsByKey[sessionID]?.status
        )
        persistSessionsLocked()
        lock.unlock()
    }

    /// Append an AI-generated title entry. AI titles are overridden by customTitle.
    func recordAITitle(_ title: String, sessionID: String) {
        lock.lock()
        appendEntryLocked(
            type: "ai-title",
            sessionID: sessionID,
            parentUuid: nil,
            aiTitle: title
        )
        // AI title: always update display name. If user later sets a custom title,
        // it will override this via setTitle() which uses customTitle entry.
        let existing = sessionsByKey[sessionID]
        upsertSessionLocked(
            for: sessionID,
            titleOverride: title,
            previewOverride: existing?.preview,
            lastPromptOverride: existing?.lastPrompt,
            statusOverride: existing?.status
        )
        persistSessionsLocked()
        lock.unlock()
    }

    /// Append a last-prompt metadata entry.
    func recordLastPrompt(_ prompt: String, sessionID: String) {
        lock.lock()
        appendEntryLocked(
            type: "last-prompt",
            sessionID: sessionID,
            parentUuid: nil,
            lastPrompt: prompt
        )
        lock.unlock()
    }

    func removeSessions(_ sessionIDs: [String]) {
        let targets = Set(sessionIDs)
        guard !targets.isEmpty else { return }

        lock.lock()
        loadSessionsIfNeededLocked()

        var didChange = false
        for sessionID in targets {
            messagesBySession.removeValue(forKey: sessionID)
            loadedSessions.remove(sessionID)
            nextSequenceByConversation.removeValue(forKey: sessionID)
            lastChainUuidBySession.removeValue(forKey: sessionID)
            lastAppendedEntryUuidBySession.removeValue(forKey: sessionID)
            recordedUuidsBySession.removeValue(forKey: sessionID)
            if sessionsByKey.removeValue(forKey: sessionID) != nil {
                didChange = true
            }
            try? FileManager.default.removeItem(at: sessionDirectory(for: sessionID))
        }

        if didChange {
            persistSessionsLocked()
        }
        lock.unlock()
    }

    // MARK: - Interruption Detection

    /// Detect if the last turn in a session was interrupted.
    func detectInterruption(for sessionID: String) -> InterruptionKind {
        lock.lock()
        ensureSessionLoadedLocked(sessionID)
        let msgs = (messagesBySession[sessionID] ?? []).sorted { $0.createdAt < $1.createdAt }
        lock.unlock()
        return Self.detectInterruption(in: msgs)
    }

    static func detectInterruption(in messages: [ConversationMessage]) -> InterruptionKind {
        // Skip non-conversation messages from the end.
        var lastConversationMessage: ConversationMessage?
        for message in messages.reversed() {
            if message.role == .user || message.role == .assistant {
                lastConversationMessage = message
                break
            }
        }

        guard let last = lastConversationMessage else { return .none }

        // Last message is assistant and has content → normal completion.
        if last.role == .assistant {
            // Check if assistant has unresolved tool calls (running state).
            let hasRunningToolCalls = last.parts.contains { part in
                guard case let .toolCall(tc) = part else { return false }
                return tc.state == .running
            }
            if hasRunningToolCalls {
                return .interruptedTurn
            }
            return .none
        }

        // Last message is user.
        if last.role == .user {
            if last.isCompactionSummary || last.isCompactBoundary || last.isCompactAttachment {
                return .none
            }

            // Check if the user message has unresolved tool results.
            let hasToolResult = last.parts.contains { part in
                if case .toolResult = part { return true }
                return false
            }
            if hasToolResult {
                // Tool result without a following assistant → interrupted.
                return .interruptedTurn
            }

            // Regular user prompt without assistant reply.
            return .interruptedPrompt
        }

        return .none
    }

    /// Filter out unresolved tool uses and orphaned thinking-only messages
    /// from a recovered session, using interruption detection to filter unresolved messages.
    static func filterUnresolvedForRecovery(_ messages: [ConversationMessage]) -> [ConversationMessage] {
        var result = messages

        // 1. Filter assistant messages with only running tool calls (no result and no text).
        result.removeAll { msg in
            guard msg.role == .assistant else { return false }
            let hasText = !msg.textContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let hasReasoning = !(msg.reasoningContent ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let allToolCallsRunning = msg.parts.contains { part in
                guard case let .toolCall(tc) = part else { return false }
                return tc.state == .running
            }
            let hasAnyNonRunningPart = msg.parts.contains { part in
                switch part {
                case .text: return true
                case .reasoning: return true
                case let .toolCall(tc): return tc.state != .running
                case .toolResult: return true
                default: return false
                }
            }
            // If it's just running tool calls with no content, it's an orphan.
            return allToolCallsRunning && !hasText && !hasReasoning && !hasAnyNonRunningPart
        }

        // 2. Mark running tool calls as failed in remaining messages.
        for message in result where message.role == .assistant {
            let toolResultIDs = Set(message.parts.compactMap { part -> String? in
                guard case let .toolResult(value) = part else { return nil }
                return value.toolCallID
            })
            for (index, part) in message.parts.enumerated() {
                guard case var .toolCall(toolCall) = part,
                      toolCall.state == .running,
                      !toolResultIDs.contains(toolCall.id)
                else { continue }
                toolCall.state = .failed
                message.parts[index] = .toolCall(toolCall)
            }
        }

        return result
    }

    // MARK: - Private: Lifecycle Entry Helper

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
        appendEntryLocked(
            type: type,
            subtype: subtype,
            sessionID: sessionID,
            parentUuid: nil,
            text: text,
            isError: isError,
            result: result
        )
        upsertSessionLocked(
            for: sessionID,
            titleOverride: sessionsByKey[sessionID]?.displayName,
            previewOverride: sessionsByKey[sessionID]?.preview,
            lastPromptOverride: sessionsByKey[sessionID]?.lastPrompt,
            statusOverride: status
        )
        persistSessionsLocked()
        lock.unlock()
    }

    // MARK: - Private: Directory & Path Helpers

    private func prepareDirectories() {
        try? FileManager.default.createDirectory(at: runtimeRootURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
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

    // MARK: - Private: Session Loading

    private func ensureSessionLoadedLocked(_ sessionID: String) {
        guard !loadedSessions.contains(sessionID) else { return }
        let replayState = replayStateLocked(for: sessionID, mode: .compactedContext)
        messagesBySession[sessionID] = replayState.messages
        let entries = loadTranscriptEntriesLocked(sessionID)
        nextSequenceByConversation[sessionID] = entries.last?.sequence ?? 0
        lastChainUuidBySession[sessionID] = computeLastChainUuid(from: entries)
        recordedUuidsBySession[sessionID] = computeRecordedUuids(from: entries)
        if replayState.title != nil || replayState.preview != nil || replayState.status != "idle" {
            upsertSessionLocked(
                for: sessionID,
                titleOverride: replayState.customTitle ?? replayState.aiTitle,
                previewOverride: replayState.preview,
                lastPromptOverride: replayState.lastPrompt,
                statusOverride: replayState.status
            )
            persistSessionsLocked()
        }
        loadedSessions.insert(sessionID)
    }

    private func computeLastChainUuid(from entries: [SessionTranscriptEntry]) -> String? {
        entries.last { entryKind(from: $0).isChainParticipant }?.uuid
    }

    private func computeRecordedUuids(from entries: [SessionTranscriptEntry]) -> Set<String> {
        var uuids = Set<String>()
        for entry in entries {
            let kind = entryKind(from: entry)
            if kind.isChainParticipant, let msg = entry.message {
                uuids.insert(msg.uuid)
            }
        }
        return uuids
    }

    // MARK: - Private: Replay (Read Path) — Chain-based only

    private func replayStateLocked(for sessionID: String, mode: ReplayMode) -> ReplayState {
        let entries = loadTranscriptEntriesLocked(sessionID)
        return replayFromChainLocked(entries: entries, sessionID: sessionID, mode: mode)
    }

    /// Chain-based replay: build a Map<UUID, Entry>, find the leaf,
    /// walk parentUuid back to root, return ordered messages.
    /// Recovers orphaned parallel tool results that fall off the main chain.
    private func replayFromChainLocked(
        entries: [SessionTranscriptEntry],
        sessionID: String,
        mode: ReplayMode
    ) -> ReplayState {
        var state = ReplayState()
        // Map from entry UUID to entry (for chain traversal).
        var entryMap = [String: SessionTranscriptEntry]()
        // Map from message UUID to latest entry (for upsert semantics on updates).
        var messageUuidToEntry = [String: SessionTranscriptEntry]()

        for entry in entries {
            state.updatedAtMs = max(state.updatedAtMs, timestampMs(from: entry.timestamp))
            let kind = entryKind(from: entry)

            // Process metadata regardless of chain.
            switch kind {
            case .aiTitle:
                if let title = entry.aiTitle { state.aiTitle = title }
                continue
            case .customTitle:
                if let title = entry.customTitle { state.customTitle = title }
                continue
            case .lastPrompt:
                if let prompt = entry.lastPrompt { state.lastPrompt = prompt }
                continue
            case .status:
                if entry.text == "executing" { state.status = "executing" }
                else if let status = extractStatusFromEntry(entry) { state.status = status }
                continue
            case .usage, .toolProgress, .toolUseSummary, .messagesDeleted, .tag:
                continue
            default: break
            }

            guard kind.isChainParticipant, entry.message != nil else { continue }

            // Track all entries by entry UUID for chain traversal.
            entryMap[entry.uuid] = entry

            // Track latest entry by message UUID for upsert semantics.
            // Later entries with the same message UUID override earlier ones.
            if let msgUUID = entry.message?.uuid {
                messageUuidToEntry[msgUUID] = entry
            }
        }

        // Compute effective title (customTitle > aiTitle).
        state.title = state.customTitle ?? state.aiTitle

        // For chain traversal, use the upserted entries.
        // Build a new entryMap from the upserted entries.
        var upsertedEntryMap = [String: SessionTranscriptEntry]()
        for entry in messageUuidToEntry.values {
            upsertedEntryMap[entry.uuid] = entry
        }

        // Find leaves: upserted entries whose UUID is not referenced as a parentUuid by any other upserted entry.
        var parentRefs = Set<String>()
        for entry in upsertedEntryMap.values {
            if let p = entry.parentUuid {
                parentRefs.insert(p)
            }
        }

        var leafUuids = Set<String>()
        for entry in upsertedEntryMap.values {
            if !parentRefs.contains(entry.uuid) {
                leafUuids.insert(entry.uuid)
            }
        }

        // Find the newest non-sidechain leaf.
        let leaf = leafUuids.compactMap { uuid -> SessionTranscriptEntry? in
            upsertedEntryMap[uuid]
        }.sorted { timestampMs(from: $0.timestamp) > timestampMs(from: $1.timestamp) }.first

        guard let leaf else { return state }

        // Walk the chain from leaf to root.
        var chainEntries: [SessionTranscriptEntry] = []
        var current: SessionTranscriptEntry? = leaf
        var seen = Set<String>()
        while let entry = current {
            if seen.contains(entry.uuid) { break } // cycle guard
            seen.insert(entry.uuid)
            chainEntries.append(entry)
            if let parentUuid = entry.parentUuid {
                current = upsertedEntryMap[parentUuid]
            } else {
                current = nil
            }
        }
        chainEntries.reverse()

        // Recover orphaned parallel tool results.
        chainEntries = recoverOrphanedParallelToolResults(
            entryMap: upsertedEntryMap,
            chain: chainEntries,
            seen: seen
        )

        // Apply compaction: in compactedContext mode, skip entries
        // before the last compact_boundary (parentUuid == nil).
        if mode == .compactedContext {
            var lastBoundaryIdx = -1
            for (i, entry) in chainEntries.enumerated() {
                if entry.type == "system" && entry.subtype == "compact_boundary" {
                    lastBoundaryIdx = i
                }
            }
            if lastBoundaryIdx >= 0 {
                // Keep everything from the boundary onward, remove the boundary itself.
                var slice = Array(chainEntries[lastBoundaryIdx...])
                if let first = slice.first, first.type == "system" && first.subtype == "compact_boundary" {
                    slice.removeFirst()
                }
                chainEntries = slice
            }
        }

        for entry in chainEntries {
            let kind = entryKind(from: entry)
            if kind.isChainParticipant, let msg = entry.message {
                let message = makeConversationMessage(from: msg, sessionID: sessionID)
                upsertMessage(message, into: &state.messages)
            }
            if kind == .summary, let msg = entry.message {
                let message = makeConversationMessage(from: msg, sessionID: sessionID)
                upsertMessage(message, into: &state.messages)
            }
        }

        // If status is "executing" but messages indicate an interruption,
        // correct the status via interrupt detection.
        if state.status == "executing" {
            let interruption = Self.detectInterruption(in: state.messages)
            if interruption != .none {
                state.status = "interrupted"
            }
        }

        // Reconcile incomplete tool calls for non-executing sessions.
        if state.status != "executing" {
            reconcileIncompleteToolCalls(in: &state.messages, sessionStatus: state.status)
        }

        state.preview = state.preview ?? previewText(from: state.messages)
        return state
    }

    // MARK: - Private: Parallel Tool Result Recovery

    /// When the model issues multiple parallel tool_use calls, each gets its own
    /// assistant message with the same `message.id`. A simple parentUuid chain walk
    /// only follows one path, missing sibling tool_use/tool_result pairs.
    /// This function recovers those orphaned parallel branches.
    private func recoverOrphanedParallelToolResults(
        entryMap: [String: SessionTranscriptEntry],
        chain: [SessionTranscriptEntry],
        seen: Set<String>
    ) -> [SessionTranscriptEntry] {
        // Group chain entries by their message UUID (message.uuid, not entry.uuid).
        var chainByMessageId = [String: [Int]]() // messageUUID -> [chain indices]
        for (i, entry) in chain.enumerated() {
            guard let msgUUID = entry.message?.uuid else { continue }
            chainByMessageId[msgUUID, default: []].append(i)
        }

        // Find entries NOT on the chain that share a message UUID with a chain entry.
        var orphansToInsert = [(afterChainIdx: Int, entry: SessionTranscriptEntry)]()

        for entry in entryMap.values {
            guard !seen.contains(entry.uuid),
                  let msgUUID = entry.message?.uuid,
                  let chainIndices = chainByMessageId[msgUUID],
                  !chainIndices.isEmpty
            else { continue }

            // This is a sibling of a chain entry. Find the tool_result that follows it.
            let anchorIdx = chainIndices.last!

            // Find tool_result entries that point to this entry as parent.
            let toolResults = entryMap.values.filter { candidate in
                candidate.parentUuid == entry.uuid && !seen.contains(candidate.uuid)
            }

            // Insert after the anchor in the chain.
            orphansToInsert.append((afterChainIdx: anchorIdx, entry: entry))
            for tr in toolResults {
                orphansToInsert.append((afterChainIdx: anchorIdx, entry: tr))
            }
        }

        guard !orphansToInsert.isEmpty else { return chain }

        // Sort by insertion point (descending to preserve indices).
        let sorted = orphansToInsert.sorted { $0.afterChainIdx > $1.afterChainIdx }

        var result = chain
        for orphan in sorted {
            let insertIdx = orphan.afterChainIdx + 1
            if insertIdx <= result.count {
                result.insert(orphan.entry, at: insertIdx)
            } else {
                result.append(orphan.entry)
            }
        }

        return result
    }

    // MARK: - Private: Re-append Metadata

    /// After compaction, metadata entries (title, last-prompt) may end up
    /// before the boundary, outside the tail read window. This function
    /// re-appends them to the end of the file so they remain accessible
    /// during lite reads.
    private func reAppendMetadataLocked(sessionID: String) {
        let fileURL = transcriptPath(for: sessionID)
        guard let data = try? Data(contentsOf: fileURL),
              let text = String(data: data, encoding: .utf8)
        else { return }

        var lastCustomTitle: String?
        var lastPromptValue: String?
        var lastTag: String?

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty,
                  let lineData = line.data(using: .utf8),
                  let entry = try? JSONDecoder().decode(SessionTranscriptEntry.self, from: lineData)
            else { continue }

            switch entry.type {
            case "custom-title": lastCustomTitle = entry.customTitle
            case "ai-title": break // intentionally skipped: don't re-append AI title
            case "last-prompt": lastPromptValue = entry.lastPrompt
            case "tag": lastTag = entry.tag
            default: break
            }
        }

        // Re-append each metadata type (they won't advance the chain).
        if let title = lastCustomTitle {
            appendEntryLocked(
                type: "custom-title",
                sessionID: sessionID,
                parentUuid: nil,
                customTitle: title
            )
        }
        // Do NOT re-append AI title — it would override user-set custom title.
        if let prompt = lastPromptValue {
            appendEntryLocked(
                type: "last-prompt",
                sessionID: sessionID,
                parentUuid: nil,
                lastPrompt: prompt
            )
        }
        if let tag = lastTag {
            appendEntryLocked(
                type: "tag",
                sessionID: sessionID,
                parentUuid: nil,
                tag: tag
            )
        }
    }

    private func extractStatusFromEntry(_ entry: SessionTranscriptEntry) -> String? {
        switch entry.type {
        case "system" where entry.subtype == "status":
            return entry.text
        case "result":
            switch entry.subtype {
            case "success": return "idle"
            case "error": return "failed"
            case "interrupted": return "interrupted"
            default: return nil
            }
        default: return nil
        }
    }

    private func reconcileIncompleteToolCalls(in messages: inout [ConversationMessage], sessionStatus: String) {
        guard sessionStatus != "executing" else { return }

        for message in messages where message.role == .assistant {
            let toolResultIDs = Set(message.parts.compactMap { part -> String? in
                guard case let .toolResult(value) = part else { return nil }
                return value.toolCallID
            })

            for (index, part) in message.parts.enumerated() {
                guard case var .toolCall(toolCall) = part,
                      toolCall.state == .running,
                      !toolResultIDs.contains(toolCall.id)
                else {
                    continue
                }
                toolCall.state = .failed
                message.parts[index] = .toolCall(toolCall)
            }
        }
    }

    // MARK: - Private: Core Append (Write Path)

    /// The single write primitive. Every entry goes through this.
    /// For chain participants, parentUuid is set to the current chain tip.
    /// For non-chain entries, parentUuid is nil.
    /// The actual file I/O is buffered and flushed by the write queue.
    private func appendEntryLocked(
        type: String,
        subtype: String? = nil,
        sessionID: String,
        parentUuid: String? = nil,
        logicalParentUuid: String? = nil,
        message: TranscriptMessageRecord? = nil,
        messageUUIDs: [String]? = nil,
        customTitle: String? = nil,
        aiTitle: String? = nil,
        lastPrompt: String? = nil,
        summary: String? = nil,
        tag: String? = nil,
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

        let entryUuid = UUID().uuidString
        let entry = SessionTranscriptEntry(
            uuid: entryUuid,
            parentUuid: parentUuid,
            logicalParentUuid: logicalParentUuid,
            sessionId: sessionID,
            type: type,
            subtype: subtype,
            timestamp: timestamp,
            sequence: nextSequence,
            message: message,
            messageUUIDs: messageUUIDs,
            customTitle: customTitle,
            aiTitle: aiTitle,
            lastPrompt: lastPrompt,
            summary: summary,
            tag: tag,
            toolUseID: toolUseID,
            toolName: toolName,
            toolUseState: toolUseState,
            text: text,
            usage: usage,
            isError: isError,
            result: result
        )

        // Track the entry UUID for chain cursor advancement.
        lastAppendedEntryUuidBySession[sessionID] = entryUuid

        guard let data = try? JSONEncoder().encode(entry),
              let jsonLine = String(data: data, encoding: .utf8)
        else {
            return
        }

        // Write directly to the JSONL file (synchronous, durable).
        let directoryURL = sessionDirectory(for: sessionID)
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        let fileURL = transcriptPath(for: sessionID)
        let lineData = Data((jsonLine + "\n").utf8)

        if FileManager.default.fileExists(atPath: fileURL.path) {
            guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: lineData)
            try? handle.synchronize() // fsync for durability
            try? handle.close()
        } else {
            FileManager.default.createFile(atPath: fileURL.path, contents: lineData, attributes: [.posixPermissions: 0o600])
        }
    }

    private func appendToolDiffEntriesLocked(
        sessionID: String,
        previous: ConversationMessage?,
        current: ConversationMessage
    ) {
        let previousToolCalls = Dictionary(uniqueKeysWithValues: toolCallParts(in: previous).map { ($0.id, $0) })
        let currentToolCalls = toolCallParts(in: current)
        for toolCall in currentToolCalls where previousToolCalls[toolCall.id] == nil {
            appendEntryLocked(
                type: "tool_progress",
                sessionID: sessionID,
                parentUuid: nil,
                toolUseID: toolCall.id,
                toolName: toolCall.apiName.isEmpty ? toolCall.toolName : toolCall.apiName,
                toolUseState: toolCall.state.rawValue,
                text: toolCall.parameters
            )
        }

        let previousToolResults = Set(toolResultParts(in: previous).map(toolResultIdentity(_:)))
        for toolResult in toolResultParts(in: current) where !previousToolResults.contains(toolResultIdentity(toolResult)) {
            appendEntryLocked(
                type: "tool_use_summary",
                sessionID: sessionID,
                parentUuid: nil,
                toolUseID: toolResult.toolCallID,
                text: toolResult.result
            )
        }
    }

    // MARK: - Private: Entry Kind Classification

    private func entryKind(from entry: SessionTranscriptEntry) -> TranscriptEntryKind {
        switch entry.type {
        case MessageRole.user.rawValue: return .user
        case MessageRole.assistant.rawValue: return .assistant
        case "system":
            if entry.subtype == "compact_boundary" { return .compactBoundary }
            if entry.subtype == "status" { return .status }
            return .system
        case "summary": return .summary
        case "ai-title": return .aiTitle
        case "custom-title": return .customTitle
        case "last-prompt": return .lastPrompt
        case "tool_progress": return .toolProgress
        case "tool_use_summary": return .toolUseSummary
        case "usage": return .usage
        case "messages-deleted": return .messagesDeleted
        case "result": return .status
        case "tag": return .tag
        default: return .status
        }
    }

    // MARK: - Private: File I/O

    private func loadTranscriptEntriesLocked(_ sessionID: String) -> [SessionTranscriptEntry] {
        let fileURL = transcriptPath(for: sessionID)

        // For large files, use optimized stream reading that skips pre-compact data.
        if let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
           let fileSize = attrs[.size] as? Int,
           fileSize > Self.skipPreCompactThreshold
        {
            return loadTranscriptEntriesStreamLocked(fileURL: fileURL, fileSize: fileSize)
        }

        return loadTranscriptEntriesFullLocked(fileURL: fileURL)
    }

    /// Full file read and parse for normal-sized transcript files.
    private func loadTranscriptEntriesFullLocked(fileURL: URL) -> [SessionTranscriptEntry] {
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

    /// Stream-read a large transcript file, skipping data before the last
    /// compact_boundary to avoid O(n) parse of dead history.
    /// Also recovers metadata from the pre-boundary region.
    private func loadTranscriptEntriesStreamLocked(fileURL: URL, fileSize: Int) -> [SessionTranscriptEntry] {
        // Implementation strategy (Claude Code-like):
        // 1) Find the start offset of the LAST compact boundary line.
        // 2) Read and decode from that boundary to EOF (forward, whole lines).
        // 3) Separately scan [0, boundaryStart) for metadata lines and decode only those.
        //
        // This avoids broken JSON lines at chunk boundaries and guarantees we
        // preserve the full post-boundary segment.

        let chunkSize = 64 * 1024
        let boundaryMarkers = ["\"type\":\"system\"", "\"subtype\":\"compact_boundary\""]

        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return [] }
        defer { try? handle.close() }

        // Step 1: locate last compact boundary line start.
        var boundaryLineStartOffset: Int? = nil
        var scanOffset = fileSize
        var carry = "" // leading partial line from the *next* chunk (closer to EOF)

        while scanOffset > 0, boundaryLineStartOffset == nil {
            let readSize = min(scanOffset, chunkSize)
            scanOffset -= readSize
            try? handle.seek(toOffset: UInt64(scanOffset))
            guard let chunkData = try? handle.read(upToCount: readSize),
                  let chunkTextRaw = String(data: chunkData, encoding: .utf8)
            else { break }

            // Join with carry so we can safely inspect complete lines.
            // Note: `chunkTextRaw` may start mid-line; we only consider lines that
            // have a newline terminator within this combined string.
            let combined = chunkTextRaw + carry
            let parts = combined.components(separatedBy: "\n")
            if parts.isEmpty {
                carry = combined
                continue
            }

            // Keep the first element as the next carry (it may be partial, because
            // `chunkTextRaw` could start mid-line).
            carry = parts.first ?? ""

            // We need to compute absolute file offsets for line starts.
            // We can do this by walking lines forward within chunkTextRaw+carry, but
            // to keep it robust (and since boundaries are rare), we compute the
            // boundary start by re-encoding the prefix lengths.

            // Build a forward index of line start byte offsets within `combined`.
            // Then map to absolute file offset: scanOffset + lineStartInCombined.
            let combinedData = combined.data(using: .utf8) ?? Data()
            let baseOffset = scanOffset

            var lineStarts = [0]
            for (i, b) in combinedData.enumerated() {
                if b == 0x0A { // \n
                    lineStarts.append(i + 1)
                }
            }

            // Now check from last complete line backward.
            // The last element in `parts` is after the last '\n' and is complete (since we appended carry)
            // but we still only trust lines with both start and end within `combinedData`.
            // We'll use string predicates to avoid JSON decode here.
            for idx in stride(from: parts.count - 1, through: 1, by: -1) {
                let line = parts[idx]
                if line.isEmpty { continue }
                // Cheap marker check.
                var ok = true
                for m in boundaryMarkers {
                    if !line.contains(m) {
                        ok = false
                        break
                    }
                }
                if !ok { continue }

                // Confirm by decoding to avoid false positives.
                if let lineData = line.data(using: .utf8),
                   let entry = try? JSONDecoder().decode(SessionTranscriptEntry.self, from: lineData),
                   entryKind(from: entry) == .compactBoundary
                {
                    // Compute this line's byte start within combined.
                    // `idx` in `parts` corresponds to the `idx`th line segment.
                    let startInCombined = idx < lineStarts.count ? lineStarts[idx] : nil
                    if let startInCombined {
                        boundaryLineStartOffset = max(0, baseOffset + startInCombined)
                    }
                    break
                }
            }
        }

        guard let boundaryStart = boundaryLineStartOffset else {
            // No boundary in the tail scan — fall back to full read.
            return loadTranscriptEntriesFullLocked(fileURL: fileURL)
        }

        // Step 2: decode from boundaryStart to EOF using a forward, line-safe stream reader.
        let postBoundaryEntries = readEntriesFromOffsetLocked(fileURL: fileURL, startOffset: boundaryStart)

        // Step 3: scan [0, boundaryStart) for metadata using a forward chunked scan.
        let preBoundaryMetadata = scanMetadataEntriesBeforeOffsetLocked(fileURL: fileURL, endOffset: boundaryStart)

        // Combine: post-boundary segment plus recovered metadata.
        var allEntries = postBoundaryEntries
        allEntries.append(contentsOf: preBoundaryMetadata)

        return allEntries.sorted { lhs, rhs in
            if lhs.sequence == rhs.sequence {
                return lhs.timestamp < rhs.timestamp
            }
            return lhs.sequence < rhs.sequence
        }
    }

    private func readEntriesFromOffsetLocked(fileURL: URL, startOffset: Int) -> [SessionTranscriptEntry] {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return [] }
        defer { try? handle.close() }

        try? handle.seek(toOffset: UInt64(startOffset))

        var entries: [SessionTranscriptEntry] = []
        var carry = ""

        while let chunkData = try? handle.read(upToCount: 64 * 1024),
              !chunkData.isEmpty
        {
            let chunkText = String(data: chunkData, encoding: .utf8) ?? ""
            let combined = carry + chunkText
            let parts = combined.components(separatedBy: "\n")
            carry = parts.last ?? ""

            for line in parts.dropLast() {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty,
                      let lineData = trimmed.data(using: .utf8),
                      let entry = try? JSONDecoder().decode(SessionTranscriptEntry.self, from: lineData)
                else { continue }
                entries.append(entry)
            }
        }

        let trimmedCarry = carry.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedCarry.isEmpty,
           let lineData = trimmedCarry.data(using: .utf8),
           let entry = try? JSONDecoder().decode(SessionTranscriptEntry.self, from: lineData)
        {
            entries.append(entry)
        }

        return entries
    }

    private func scanMetadataEntriesBeforeOffsetLocked(fileURL: URL, endOffset: Int) -> [SessionTranscriptEntry] {
        guard endOffset > 0,
              let handle = try? FileHandle(forReadingFrom: fileURL)
        else { return [] }
        defer { try? handle.close() }

        var entries: [SessionTranscriptEntry] = []
        var carry = ""
        var bytesRemaining = endOffset

        while bytesRemaining > 0 {
            let readSize = min(bytesRemaining, 64 * 1024)
            guard let chunkData = try? handle.read(upToCount: readSize),
                  !chunkData.isEmpty
            else { break }

            bytesRemaining -= chunkData.count

            let chunkText = String(data: chunkData, encoding: .utf8) ?? ""
            let combined = carry + chunkText
            let parts = combined.components(separatedBy: "\n")
            carry = parts.last ?? ""

            for line in parts.dropLast() {
                appendMetadataEntryIfNeeded(from: line, into: &entries)
            }
        }

        if !carry.isEmpty {
            appendMetadataEntryIfNeeded(from: carry, into: &entries)
        }

        return entries
    }

    private func appendMetadataEntryIfNeeded(from rawLine: String, into entries: inout [SessionTranscriptEntry]) {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty, looksLikeRecoverableMetadataLine(line) else { return }
        guard let lineData = line.data(using: .utf8),
              let entry = try? JSONDecoder().decode(SessionTranscriptEntry.self, from: lineData)
        else { return }
        let kind = entryKind(from: entry)
        if !kind.isChainParticipant {
            entries.append(entry)
        }
    }

    private func looksLikeRecoverableMetadataLine(_ line: String) -> Bool {
        line.contains("\"type\":\"custom-title\"") ||
            line.contains("\"type\":\"ai-title\"") ||
            line.contains("\"type\":\"last-prompt\"") ||
            line.contains("\"type\":\"tag\"") ||
            line.contains("\"type\":\"summary\"") ||
            line.contains("\"type\":\"messages-deleted\"") ||
            line.contains("\"type\":\"usage\"") ||
            line.contains("\"type\":\"tool_progress\"") ||
            line.contains("\"type\":\"tool_use_summary\"") ||
            line.contains("\"type\":\"result\"")
    }

    // MARK: - Private: Message Helpers

    private func upsertMessage(_ message: ConversationMessage, into messages: inout [ConversationMessage]) {
        if let index = messages.firstIndex(where: { $0.id == message.id }) {
            messages[index] = message
        } else {
            messages.append(message)
        }
    }

    private func copyMessage(_ message: ConversationMessage) -> ConversationMessage {
        ConversationMessage(
            id: message.id,
            sessionID: message.sessionID,
            role: message.role,
            parts: message.parts,
            createdAt: message.createdAt,
            metadata: message.metadata
        )
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

    private func previewText(from messages: [ConversationMessage]) -> String? {
        for message in messages.reversed() {
            if message.isCompactBoundary {
                continue
            }
            if let heartbeatPreview = HeartbeatSupport.previewText(for: message) {
                return heartbeatPreview
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

    private func lastPromptText(from message: ConversationMessage) -> String? {
        guard message.role == .user else { return nil }
        let trimmed = message.textContent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.count > 200 ? String(trimmed.prefix(200)) + "…" : trimmed
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

    // MARK: - Private: Serialization

    private func makeTranscriptMessageRecord(from message: ConversationMessage) -> TranscriptMessageRecord? {
        let blocks = mapContentBlocks(from: message.parts)
        let fallbackBlock = TranscriptContentBlock(type: "text", text: message.textContent)
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
                return TranscriptContentBlock(type: "text", text: textPart.text)
            case let .reasoning(reasoningPart):
                return TranscriptContentBlock(
                    type: "reasoning",
                    text: reasoningPart.text,
                    reasoningDuration: reasoningPart.duration,
                    isCollapsed: reasoningPart.isCollapsed
                )
            case let .toolCall(toolCallPart):
                return TranscriptContentBlock(
                    type: "tool_use",
                    text: toolCallPart.parameters,
                    toolUseID: toolCallPart.id,
                    toolName: toolCallPart.toolName,
                    apiName: toolCallPart.apiName,
                    toolUseState: toolCallPart.state.rawValue
                )
            case let .toolResult(resultPart):
                return TranscriptContentBlock(
                    type: "tool_result",
                    text: resultPart.result,
                    toolUseID: resultPart.toolCallID,
                    isCollapsed: resultPart.isCollapsed
                )
            case let .image(imagePart):
                return TranscriptContentBlock(type: "image", text: "[\(imagePart.name ?? "image")]")
            case let .audio(audioPart):
                return TranscriptContentBlock(type: "audio", text: "[\(audioPart.name ?? "audio")]")
            case let .file(filePart):
                return TranscriptContentBlock(type: "file", text: "[\(filePart.name ?? "file")]")
            }
        }
    }

    private func firstToolCallPart(in parts: [ContentPart]) -> ToolCallContentPart? {
        parts.lazy.compactMap { if case let .toolCall(v) = $0 { v } else { nil } }.first
    }

    private func firstToolResultPart(in parts: [ContentPart]) -> ToolResultContentPart? {
        parts.lazy.compactMap { if case let .toolResult(v) = $0 { v } else { nil } }.first
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
                    result.append(
                        .reasoning(
                            ReasoningContentPart(
                                text: text,
                                duration: block.reasoningDuration,
                                isCollapsed: block.isCollapsed ?? false
                            )
                        )
                    )
                }
            case "tool_use":
                let toolName = block.toolName ?? record.toolName ?? "Tool"
                let apiName = block.apiName
                let parameters = block.text ?? "{}"
                let toolUseState = ToolCallState(rawValue: block.toolUseState ?? "") ?? .succeeded
                result.append(
                    .toolCall(
                        ToolCallContentPart(
                            id: block.toolUseID ?? record.toolUseID ?? UUID().uuidString,
                            toolName: toolName,
                            apiName: apiName ?? toolName,
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
                            isCollapsed: block.isCollapsed ?? true
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

    // MARK: - Private: Session Index

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
        lastPromptOverride: String?,
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
            preview: previewOverride ?? existing?.preview,
            lastPrompt: lastPromptOverride ?? existing?.lastPrompt
        )
    }

    private func persistSessionsLocked() {
        let sorted = sessionsByKey.values.sorted { $0.updatedAtMs > $1.updatedAtMs }
        let envelope = SessionEnvelope(sessions: sorted)
        guard let data = try? JSONEncoder().encode(envelope) else { return }
        try? data.write(to: indexPath, options: [.atomic])
    }
}
