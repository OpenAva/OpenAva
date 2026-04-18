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
    case customTitle
    case lastPrompt
    case unknown

    /// Whether this entry kind participates in the parentUuid chain.
    var isChainParticipant: Bool {
        switch self {
        case .user, .assistant, .system, .compactBoundary: return true
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

    private static let metadataScanChunkSize: Int = 64 * 1024

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

    private struct TranscriptEntryProbe: Decodable {
        let type: String
        let subtype: String?
    }

    private struct ChainTranscriptEntry: Codable {
        let uuid: String
        let parentUuid: String?
        let sessionId: String
        let type: String
        let subtype: String?
        let timestamp: String
        let message: TranscriptMessageRecord
    }

    private struct SummaryTranscriptEntry: Codable {
        let type: String
        let leafUuid: String
        let summary: String

        init(leafUuid: String, summary: String) {
            type = "summary"
            self.leafUuid = leafUuid
            self.summary = summary
        }
    }

    private struct CustomTitleTranscriptEntry: Codable {
        let type: String
        let customTitle: String

        init(customTitle: String) {
            type = "custom-title"
            self.customTitle = customTitle
        }
    }

    private struct LastPromptTranscriptEntry: Codable {
        let type: String
        let lastPrompt: String

        init(lastPrompt: String) {
            type = "last-prompt"
            self.lastPrompt = lastPrompt
        }
    }

    private struct UnknownTranscriptEntry: Codable {
        let type: String
        let subtype: String?
        let timestamp: String?
    }

    /// The on-disk transcript entry. Each JSONL line is encoded as a narrow
    /// per-kind payload, then wrapped by this enum for read/write dispatch.
    private enum SessionTranscriptEntry: Codable {
        case chain(ChainTranscriptEntry)
        case summary(SummaryTranscriptEntry)
        case customTitle(CustomTitleTranscriptEntry)
        case lastPrompt(LastPromptTranscriptEntry)
        case unknown(UnknownTranscriptEntry)

        init(from decoder: Decoder) throws {
            let probe = try TranscriptEntryProbe(from: decoder)
            switch (probe.type, probe.subtype) {
            case (MessageRole.user.rawValue, _),
                 (MessageRole.assistant.rawValue, _),
                 ("system", "compact_boundary"),
                 ("system", nil):
                if let entry = try? ChainTranscriptEntry(from: decoder) {
                    self = .chain(entry)
                } else {
                    self = try .unknown(UnknownTranscriptEntry(from: decoder))
                }
            case ("summary", _):
                if let entry = try? SummaryTranscriptEntry(from: decoder) {
                    self = .summary(entry)
                } else {
                    self = try .unknown(UnknownTranscriptEntry(from: decoder))
                }
            case ("custom-title", _):
                if let entry = try? CustomTitleTranscriptEntry(from: decoder) {
                    self = .customTitle(entry)
                } else {
                    self = try .unknown(UnknownTranscriptEntry(from: decoder))
                }
            case ("last-prompt", _):
                if let entry = try? LastPromptTranscriptEntry(from: decoder) {
                    self = .lastPrompt(entry)
                } else {
                    self = try .unknown(UnknownTranscriptEntry(from: decoder))
                }
            default:
                self = try .unknown(UnknownTranscriptEntry(from: decoder))
            }
        }

        func encode(to encoder: Encoder) throws {
            switch self {
            case let .chain(entry): try entry.encode(to: encoder)
            case let .summary(entry): try entry.encode(to: encoder)
            case let .customTitle(entry): try entry.encode(to: encoder)
            case let .lastPrompt(entry): try entry.encode(to: encoder)
            case let .unknown(entry): try entry.encode(to: encoder)
            }
        }

        var uuid: String? {
            if case let .chain(entry) = self { return entry.uuid }
            return nil
        }

        var parentUuid: String? {
            if case let .chain(entry) = self { return entry.parentUuid }
            return nil
        }

        var leafUuid: String? {
            if case let .summary(entry) = self { return entry.leafUuid }
            return nil
        }

        var type: String {
            switch self {
            case let .chain(entry): return entry.type
            case let .summary(entry): return entry.type
            case let .customTitle(entry): return entry.type
            case let .lastPrompt(entry): return entry.type
            case let .unknown(entry): return entry.type
            }
        }

        var subtype: String? {
            switch self {
            case let .chain(entry): return entry.subtype
            case let .unknown(entry): return entry.subtype
            default: return nil
            }
        }

        var timestamp: String? {
            switch self {
            case let .chain(entry): return entry.timestamp
            case let .unknown(entry): return entry.timestamp
            default: return nil
            }
        }

        var message: TranscriptMessageRecord? {
            if case let .chain(entry) = self { return entry.message }
            return nil
        }

        var customTitle: String? {
            if case let .customTitle(entry) = self { return entry.customTitle }
            return nil
        }

        var lastPrompt: String? {
            if case let .lastPrompt(entry) = self { return entry.lastPrompt }
            return nil
        }

        var summary: String? {
            if case let .summary(entry) = self { return entry.summary }
            return nil
        }
    }

    private struct SessionRecord {
        var key: String
        var displayName: String
        var updatedAtMs: Int64
    }

    private struct SessionMetadataCache {
        var customTitle: String?
        var lastPrompt: String?
    }

    private struct SessionInterruptionSnapshot {
        var shouldShowRetry = false
    }

    private struct LoadedSessionCache {
        var messages: [ConversationMessage] = []
        var metadata = SessionMetadataCache()
        var interruption = SessionInterruptionSnapshot()
    }

    // MARK: - Replay State

    private struct ReplayState {
        var messages: [ConversationMessage] = []
        var showsInterruptedRetryAction = false
        var title: String?
        var customTitle: String?
        var updatedAtMs: Int64 = 0
        var lastPrompt: String?
    }

    private struct LiteTranscriptRead {
        var modifiedAtMs: Int64
        var fileSize: Int
        var head: String
        var tail: String
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
    private let lock = NSLock()

    /// Loaded session state, derived from transcript replay and kept in sync with appends.
    private var loadedSessionCacheByID: [String: LoadedSessionCache] = [:]
    private var sessionsByKey: [String: SessionRecord] = [:]
    private var didLoadSessions = false

    private init(runtimeRootURL: URL) {
        self.runtimeRootURL = runtimeRootURL
        sessionsDir = runtimeRootURL.appendingPathComponent("sessions", isDirectory: true)
        prepareDirectories()
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

        let previousMessages = loadedSessionCacheByID[sessionID]?.messages ?? []
        let previousByID = Dictionary(uniqueKeysWithValues: previousMessages.map { ($0.id, $0) })
        let nextByID = Dictionary(uniqueKeysWithValues: sortedMessages.map { ($0.id, $0) })
        let removedIDs = previousMessages.map(\.id).filter { nextByID[$0] == nil }
        let summaryMessage = sortedMessages.first(where: { $0.isCompactionSummary })

        if let summaryMessage, !removedIDs.isEmpty {
            // Compaction metadata is intentionally narrow: keep the summary text
            // searchable/stream-recoverable, but persist the actual summary body
            // as an ordinary user chain message.
            _ = appendEntryLocked(
                type: "summary",
                sessionID: sessionID,
                parentUuid: nil,
                leafUuid: summaryMessage.id,
                summary: summaryText(from: summaryMessage)
            )
            // Re-append metadata so it stays in the tail window.
            reAppendMetadataLocked(sessionID: sessionID)
        } else if !removedIDs.isEmpty {
            var cache = loadedSessionCacheByID[sessionID] ?? LoadedSessionCache()
            var metadata = cache.metadata
            metadata.lastPrompt = sortedMessages.reversed().compactMap(lastPromptText(from:)).first
            cache.messages = sortedMessages.map(copyMessage(_:))
            cache.metadata = metadata
            cache.interruption = SessionInterruptionSnapshot(
                shouldShowRetry: Self.interruptionRetryVisible(for: sortedMessages)
            )
            loadedSessionCacheByID[sessionID] = cache
            rewriteTranscriptLocked(sessionID: sessionID, messages: sortedMessages, metadata: metadata)
            upsertSessionLocked(
                for: sessionID,
                displayNameOverride: sessionListDisplayNameLocked(sessionID: sessionID, messages: sortedMessages)
            )
            lock.unlock()
            return
        }

        let parentUUIDsByMessageID = parentUUIDsByMessageID(for: sortedMessages)

        for message in sortedMessages {
            let previous = previousByID[message.id]

            guard transcriptSignature(for: previous) != transcriptSignature(for: message) else {
                continue
            }

            _ = appendEntryLocked(
                type: message.role.rawValue,
                uuid: message.id,
                subtype: message.subtype,
                sessionID: sessionID,
                parentUuid: parentUUIDsByMessageID[message.id] ?? nil,
                message: makeTranscriptMessageRecord(from: message)
            )
        }

        var cache = loadedSessionCacheByID[sessionID] ?? LoadedSessionCache()
        cache.messages = sortedMessages.map(copyMessage(_:))
        var metadata = cache.metadata
        metadata.lastPrompt = sortedMessages.reversed().compactMap(lastPromptText(from:)).first
        cache.metadata = metadata
        cache.interruption = SessionInterruptionSnapshot(
            shouldShowRetry: Self.interruptionRetryVisible(for: sortedMessages)
        )
        loadedSessionCacheByID[sessionID] = cache
        upsertSessionLocked(
            for: sessionID,
            displayNameOverride: sessionListDisplayNameLocked(sessionID: sessionID, messages: sortedMessages)
        )
        lock.unlock()
    }

    func messages(in sessionID: String) -> [ConversationMessage] {
        lock.lock()
        ensureSessionLoadedLocked(sessionID)
        let messages = loadedSessionCacheByID[sessionID]?.messages ?? []
        lock.unlock()
        return messages.sorted { $0.createdAt < $1.createdAt }.map(copyMessage(_:))
    }

    func sessionStatus(for sessionID: String) -> String {
        lock.lock()
        ensureSessionLoadedLocked(sessionID)
        let shouldShowRetry = loadedSessionCacheByID[sessionID]?.interruption.shouldShowRetry ?? false
        lock.unlock()
        return shouldShowRetry ? "interrupted" : "idle"
    }

    func delete(_ messageIDs: [String]) {
        guard !messageIDs.isEmpty else { return }
        let deletedIDs = Set(messageIDs)
        lock.lock()
        for (sessionID, cache) in loadedSessionCacheByID {
            let messages = cache.messages
            let filtered = messages.filter { !deletedIDs.contains($0.id) }
            if filtered.count != messages.count {
                var nextCache = cache
                nextCache.messages = filtered
                var metadata = nextCache.metadata
                metadata.lastPrompt = filtered.reversed().compactMap(lastPromptText(from:)).first
                nextCache.metadata = metadata
                nextCache.interruption = SessionInterruptionSnapshot(
                    shouldShowRetry: Self.interruptionRetryVisible(for: filtered)
                )
                loadedSessionCacheByID[sessionID] = nextCache
                rewriteTranscriptLocked(sessionID: sessionID, messages: filtered, metadata: metadata)
                upsertSessionLocked(
                    for: sessionID,
                    displayNameOverride: sessionListDisplayNameLocked(sessionID: sessionID, messages: filtered)
                )
            }
        }
        lock.unlock()
    }

    func title(for id: String) -> String? {
        lock.lock()
        ensureSessionLoadedLocked(id)
        let title = effectiveTitleLocked(for: id)
        lock.unlock()
        return title
    }

    func setTitle(_ title: String, for id: String) {
        lock.lock()
        ensureSessionLoadedLocked(id)
        let currentTitle = effectiveTitleLocked(for: id)
        guard currentTitle != title else {
            lock.unlock()
            return
        }
        var cache = loadedSessionCacheByID[id] ?? LoadedSessionCache()
        var metadata = cache.metadata
        metadata.customTitle = title.isEmpty ? nil : title
        cache.metadata = metadata
        loadedSessionCacheByID[id] = cache
        upsertSessionLocked(
            for: id,
            displayNameOverride: sessionListDisplayNameLocked(sessionID: id, messages: cache.messages)
        )
        _ = appendEntryLocked(
            type: "custom-title",
            sessionID: id,
            parentUuid: nil,
            customTitle: title
        )
        lock.unlock()
    }

    // MARK: - Incremental Append API

    /// Record a single message snapshot immediately.
    func save(message: ConversationMessage) {
        let sessionID = message.sessionID
        lock.lock()
        ensureSessionLoadedLocked(sessionID)
        let existingMessageIDs = Set((loadedSessionCacheByID[sessionID]?.messages ?? []).map(\.id))
        let lastPromptOverride = existingMessageIDs.contains(message.id) ? nil : lastPromptText(from: message)
        recordMessageSnapshotLocked(message, to: sessionID, lastPromptOverride: lastPromptOverride)
        lock.unlock()
    }

    func removeSessions(_ sessionIDs: [String]) {
        let targets = Set(sessionIDs)
        guard !targets.isEmpty else { return }

        lock.lock()
        loadSessionsIfNeededLocked()

        for sessionID in targets {
            loadedSessionCacheByID.removeValue(forKey: sessionID)
            sessionsByKey.removeValue(forKey: sessionID)
            try? FileManager.default.removeItem(at: sessionDirectory(for: sessionID))
        }
        lock.unlock()
    }

    // MARK: - Interruption Detection

    /// Detect if the last turn in a session was interrupted.
    func detectInterruption(for sessionID: String) -> InterruptionKind {
        lock.lock()
        ensureSessionLoadedLocked(sessionID)
        let msgs = (loadedSessionCacheByID[sessionID]?.messages ?? []).sorted { $0.createdAt < $1.createdAt }
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

    static func interruptionRetryVisible(for messages: [ConversationMessage]) -> Bool {
        switch detectInterruption(in: messages) {
        case .interruptedPrompt, .interruptedTurn:
            return true
        case .none:
            return false
        }
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
        guard loadedSessionCacheByID[sessionID] == nil else { return }
        let replayState = replayStateLocked(for: sessionID)
        loadedSessionCacheByID[sessionID] = LoadedSessionCache(
            messages: replayState.messages,
            metadata: SessionMetadataCache(
                customTitle: replayState.customTitle,
                lastPrompt: replayState.lastPrompt
            ),
            interruption: SessionInterruptionSnapshot(
                shouldShowRetry: replayState.showsInterruptedRetryAction
            )
        )
        if !replayState.messages.isEmpty || replayState.title != nil || replayState.lastPrompt != nil {
            upsertSessionLocked(
                for: sessionID,
                displayNameOverride: sessionListDisplayNameLocked(sessionID: sessionID, messages: replayState.messages),
                updatedAtMs: transcriptModifiedAtMs(for: sessionID) ?? replayState.updatedAtMs
            )
        }
    }

    // MARK: - Private: Replay (Read Path) — Chain-based only

    private func replayStateLocked(for sessionID: String) -> ReplayState {
        let entries = loadTranscriptEntriesLocked(sessionID)
        return replayFromChainLocked(entries: entries, sessionID: sessionID)
    }

    /// Chain-based replay: build a Map<UUID, Entry>, find the leaf,
    /// walk parentUuid back to root, and apply last-wins semantics by UUID.
    private func replayFromChainLocked(
        entries: [SessionTranscriptEntry],
        sessionID: String
    ) -> ReplayState {
        var state = ReplayState()
        var entryMap = [String: SessionTranscriptEntry]()

        for entry in entries {
            state.updatedAtMs = max(state.updatedAtMs, timestampMs(from: entry.timestamp))
            let kind = entryKind(from: entry)

            // Process metadata regardless of chain.
            switch kind {
            case .customTitle:
                if let title = entry.customTitle { state.customTitle = title }
                continue
            case .lastPrompt:
                if let prompt = entry.lastPrompt { state.lastPrompt = prompt }
                continue
            case .summary:
                continue
            case .unknown:
                continue
            default: break
            }

            guard kind.isChainParticipant else { continue }
            guard let uuid = entry.uuid else { continue }
            entryMap[uuid] = entry
        }

        state.title = state.customTitle

        // Find leaves: chain entries whose UUID is not referenced as a parentUuid.
        var parentRefs = Set<String>()
        for entry in entryMap.values {
            if let p = entry.parentUuid {
                parentRefs.insert(p)
            }
        }

        var leafUuids = Set<String>()
        for entry in entryMap.values {
            guard let uuid = entry.uuid else { continue }
            if !parentRefs.contains(uuid) {
                leafUuids.insert(uuid)
            }
        }

        let leaf = leafUuids.compactMap { uuid -> SessionTranscriptEntry? in
            entryMap[uuid]
        }.sorted { timestampMs(from: $0.timestamp) > timestampMs(from: $1.timestamp) }.first

        guard let leaf else {
            state.showsInterruptedRetryAction = Self.interruptionRetryVisible(for: state.messages)
            return state
        }

        // Walk the chain from leaf to root.
        var chainEntries: [SessionTranscriptEntry] = []
        var current: SessionTranscriptEntry? = leaf
        var seen = Set<String>()
        while let entry = current {
            guard let uuid = entry.uuid else { break }
            if seen.contains(uuid) { break } // cycle guard
            seen.insert(uuid)
            chainEntries.append(entry)
            if let parentUuid = entry.parentUuid {
                current = entryMap[parentUuid]
            } else {
                current = nil
            }
        }
        chainEntries.reverse()

        // Keep only the latest compacted segment, including the boundary marker.
        var lastBoundaryIdx = -1
        for (i, entry) in chainEntries.enumerated() {
            if entry.type == "system" && entry.subtype == "compact_boundary" {
                lastBoundaryIdx = i
            }
        }
        if lastBoundaryIdx >= 0 {
            chainEntries = Array(chainEntries[lastBoundaryIdx...])
        }

        for entry in chainEntries {
            let kind = entryKind(from: entry)
            if kind.isChainParticipant, let msg = entry.message {
                let message = makeConversationMessage(from: msg, sessionID: sessionID)
                upsertMessage(message, into: &state.messages)
            }
        }

        state.showsInterruptedRetryAction = Self.interruptionRetryVisible(for: state.messages)
        reconcileIncompleteToolCalls(in: &state.messages)

        return state
    }

    // MARK: - Private: Re-append Metadata

    /// After compaction, metadata entries (title, last-prompt) may end up
    /// before the boundary, outside the tail read window. This function
    /// re-appends them to the end of the file so they remain accessible
    /// during lite reads.
    private func reAppendMetadataLocked(sessionID: String) {
        let metadata = loadedSessionCacheByID[sessionID]?.metadata ?? SessionMetadataCache()

        // Re-append each metadata type (they won't advance the chain).
        if let prompt = metadata.lastPrompt {
            _ = appendEntryLocked(
                type: "last-prompt",
                sessionID: sessionID,
                parentUuid: nil,
                lastPrompt: prompt
            )
        }
        if let title = metadata.customTitle {
            _ = appendEntryLocked(
                type: "custom-title",
                sessionID: sessionID,
                parentUuid: nil,
                customTitle: title
            )
        }
    }

    private func reconcileIncompleteToolCalls(in messages: inout [ConversationMessage]) {
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
        uuid: String? = nil,
        subtype: String? = nil,
        sessionID: String,
        parentUuid: String? = nil,
        leafUuid: String? = nil,
        message: TranscriptMessageRecord? = nil,
        customTitle: String? = nil,
        lastPrompt: String? = nil,
        summary: String? = nil
    ) -> String? {
        let timestamp = Self.iso8601Formatter.string(from: Date())
        let kind = entryKind(forEntryType: type, subtype: subtype)
        let entryUuid = kind.isChainParticipant ? (uuid ?? UUID().uuidString) : nil
        let entry: SessionTranscriptEntry

        switch kind {
        case .user, .assistant, .system, .compactBoundary:
            guard let entryUuid, let message else { return nil }
            entry = .chain(
                ChainTranscriptEntry(
                    uuid: entryUuid,
                    parentUuid: parentUuid,
                    sessionId: sessionID,
                    type: type,
                    subtype: subtype,
                    timestamp: timestamp,
                    message: message
                )
            )
        case .summary:
            guard let leafUuid, let summary else { return nil }
            entry = .summary(SummaryTranscriptEntry(leafUuid: leafUuid, summary: summary))
        case .customTitle:
            guard let customTitle else { return nil }
            entry = .customTitle(CustomTitleTranscriptEntry(customTitle: customTitle))
        case .lastPrompt:
            guard let lastPrompt else { return nil }
            entry = .lastPrompt(LastPromptTranscriptEntry(lastPrompt: lastPrompt))
        case .unknown:
            return nil
        }

        guard let jsonLine = encodedTranscriptLine(for: entry) else { return nil }
        appendJSONLineLocked(jsonLine, to: sessionID)

        return entry.uuid
    }

    private func rewriteTranscriptLocked(
        sessionID: String,
        messages: [ConversationMessage],
        metadata: SessionMetadataCache
    ) {
        let sortedMessages = messages.sorted { $0.createdAt < $1.createdAt }
        let parentUUIDsByMessageID = parentUUIDsByMessageID(for: sortedMessages)
        var lines: [String] = []

        if let summaryMessage = sortedMessages.first(where: { $0.isCompactionSummary }),
           let summary = summaryText(from: summaryMessage),
           let summaryLine = encodedTranscriptLine(for: .summary(SummaryTranscriptEntry(leafUuid: summaryMessage.id, summary: summary)))
        {
            lines.append(summaryLine)
        }

        for message in sortedMessages {
            let kind = entryKind(for: message)
            guard kind.isChainParticipant,
                  let record = makeTranscriptMessageRecord(from: message),
                  let line = encodedTranscriptLine(
                      for: .chain(
                          ChainTranscriptEntry(
                              uuid: message.id,
                              parentUuid: parentUUIDsByMessageID[message.id] ?? nil,
                              sessionId: sessionID,
                              type: message.role.rawValue,
                              subtype: message.subtype,
                              timestamp: Self.iso8601Formatter.string(from: message.createdAt),
                              message: record
                          )
                      )
                  )
            else {
                continue
            }
            lines.append(line)
        }

        if let customTitle = metadata.customTitle,
           let line = encodedTranscriptLine(for: .customTitle(CustomTitleTranscriptEntry(customTitle: customTitle)))
        {
            lines.append(line)
        }
        if let lastPrompt = metadata.lastPrompt,
           let line = encodedTranscriptLine(for: .lastPrompt(LastPromptTranscriptEntry(lastPrompt: lastPrompt)))
        {
            lines.append(line)
        }

        writeJSONLinesLocked(lines, to: sessionID)
    }

    // MARK: - Private: Entry Kind Classification

    private func entryKind(from entry: SessionTranscriptEntry) -> TranscriptEntryKind {
        entryKind(forEntryType: entry.type, subtype: entry.subtype)
    }

    private func entryKind(forEntryType type: String, subtype: String?) -> TranscriptEntryKind {
        switch type {
        case MessageRole.user.rawValue: return .user
        case MessageRole.assistant.rawValue: return .assistant
        case "system":
            if subtype == "compact_boundary" { return .compactBoundary }
            return .system
        case "summary": return .summary
        case "custom-title": return .customTitle
        case "last-prompt": return .lastPrompt
        default: return .unknown
        }
    }

    private func encodedTranscriptLine(for entry: SessionTranscriptEntry) -> String? {
        guard let data = try? JSONEncoder().encode(entry) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func appendJSONLineLocked(_ jsonLine: String, to sessionID: String) {
        let directoryURL = sessionDirectory(for: sessionID)
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        let fileURL = transcriptPath(for: sessionID)
        let lineData = Data((jsonLine + "\n").utf8)

        if FileManager.default.fileExists(atPath: fileURL.path) {
            guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: lineData)
            try? handle.synchronize()
            try? handle.close()
        } else {
            FileManager.default.createFile(atPath: fileURL.path, contents: lineData, attributes: [.posixPermissions: 0o600])
        }
    }

    private func writeJSONLinesLocked(_ jsonLines: [String], to sessionID: String) {
        let directoryURL = sessionDirectory(for: sessionID)
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        let fileURL = transcriptPath(for: sessionID)
        let content = jsonLines.isEmpty ? "" : jsonLines.joined(separator: "\n") + "\n"
        let data = Data(content.utf8)

        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: data, attributes: [.posixPermissions: 0o600])
            return
        }

        try? data.write(to: fileURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    // MARK: - Private: File I/O

    private func loadTranscriptEntriesLocked(_ sessionID: String) -> [SessionTranscriptEntry] {
        loadTranscriptEntriesLocked(fileURL: transcriptPath(for: sessionID))
    }

    private func loadTranscriptEntriesLocked(fileURL: URL) -> [SessionTranscriptEntry] {
        loadTranscriptEntriesFullLocked(fileURL: fileURL)
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
        // JSONL is append-only; preserve file order.
        return entries
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

    private func entryKind(for message: ConversationMessage) -> TranscriptEntryKind {
        switch message.role {
        case .user: return .user
        case .assistant: return .assistant
        default: return .system
        }
    }

    private func recordMessageSnapshotLocked(_ message: ConversationMessage, to sessionID: String, lastPromptOverride: String?) {
        let previous = loadedSessionCacheByID[sessionID]?.messages.first(where: { $0.id == message.id })

        var cache = loadedSessionCacheByID[sessionID] ?? LoadedSessionCache()
        var nextMessages = cache.messages
        upsertMessage(copyMessage(message), into: &nextMessages)
        nextMessages.sort { $0.createdAt < $1.createdAt }

        if transcriptSignature(for: previous) != transcriptSignature(for: message) {
            let parentUuid = parentUUIDsByMessageID(for: nextMessages)[message.id] ?? nil
            _ = appendEntryLocked(
                type: message.role.rawValue,
                uuid: message.id,
                sessionID: sessionID,
                parentUuid: parentUuid,
                message: makeTranscriptMessageRecord(from: message)
            )
        }

        cache.messages = nextMessages
        var metadata = cache.metadata
        if let lastPromptOverride {
            metadata.lastPrompt = lastPromptOverride
        }
        cache.metadata = metadata
        cache.interruption = SessionInterruptionSnapshot(
            shouldShowRetry: Self.interruptionRetryVisible(for: nextMessages)
        )
        loadedSessionCacheByID[sessionID] = cache
        upsertSessionLocked(
            for: sessionID,
            displayNameOverride: sessionListDisplayNameLocked(sessionID: sessionID, messages: nextMessages)
        )
    }

    private func parentUUIDsByMessageID(
        for messages: [ConversationMessage]
    ) -> [String: String?] {
        let sortedMessages = messages.sorted { $0.createdAt < $1.createdAt }
        var parentUUIDs = [String: String?]()
        var currentParentUUID: String?

        for message in sortedMessages {
            let kind = entryKind(for: message)
            guard kind.isChainParticipant else { continue }

            if message.isCompactBoundary {
                parentUUIDs[message.id] = nil
                currentParentUUID = message.id
                continue
            }

            parentUUIDs[message.id] = currentParentUUID
            currentParentUUID = message.id
        }

        return parentUUIDs
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

    private func effectiveTitleLocked(for sessionID: String) -> String? {
        let metadata = loadedSessionCacheByID[sessionID]?.metadata ?? SessionMetadataCache()
        return metadata.customTitle
    }

    private func sessionListDisplayNameLocked(sessionID: String, messages: [ConversationMessage]?) -> String {
        if let title = effectiveTitleLocked(for: sessionID), !title.isEmpty {
            return title
        }

        let metadata = loadedSessionCacheByID[sessionID]?.metadata ?? SessionMetadataCache()
        if let lastPrompt = metadata.lastPrompt, !lastPrompt.isEmpty {
            return lastPrompt
        }

        if let messages, let preview = previewText(from: messages), !preview.isEmpty {
            return preview
        }

        if let cachedMessages = loadedSessionCacheByID[sessionID]?.messages,
           let preview = previewText(from: cachedMessages),
           !preview.isEmpty
        {
            return preview
        }

        return sessionID
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

    private func timestampMs(from timestamp: String?) -> Int64 {
        guard let timestamp,
              let date = Self.iso8601Formatter.date(from: timestamp)
        else { return 0 }
        return Int64(date.timeIntervalSince1970 * 1000)
    }

    // MARK: - Private: Session Cache

    private func loadSessionsIfNeededLocked() {
        guard !didLoadSessions else { return }
        didLoadSessions = true
        sessionsByKey = scanSessionRecordsLocked()
    }

    private func scanSessionRecordsLocked() -> [String: SessionRecord] {
        guard let sessionDirectories = try? FileManager.default.contentsOfDirectory(
            at: sessionsDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return [:]
        }

        var records: [String: SessionRecord] = [:]
        for directoryURL in sessionDirectories {
            let transcriptURL = directoryURL.appendingPathComponent("transcript.jsonl", isDirectory: false)
            guard FileManager.default.fileExists(atPath: transcriptURL.path),
                  let record = liteSessionRecordLocked(fromTranscriptAt: transcriptURL, fallbackSessionID: directoryURL.lastPathComponent)
            else {
                continue
            }
            records[record.key] = record
        }

        return records
    }

    private func liteSessionRecordLocked(fromTranscriptAt transcriptURL: URL, fallbackSessionID: String) -> SessionRecord? {
        guard let liteRead = readLiteTranscriptLocked(fileURL: transcriptURL) else { return nil }

        let headEntries = decodeLiteEntries(from: liteRead.head, dropFirstPartialLine: false, dropLastPartialLine: liteRead.fileSize > Self.metadataScanChunkSize)
        let tailEntries = liteRead.head == liteRead.tail
            ? headEntries
            : decodeLiteEntries(from: liteRead.tail, dropFirstPartialLine: true, dropLastPartialLine: false)

        let sessionID = fallbackSessionID

        let title = lastMetadataValue(in: tailEntries, extractor: { $0.customTitle })
            ?? lastMetadataValue(in: headEntries, extractor: { $0.customTitle })
        let lastPrompt = lastMetadataValue(in: tailEntries, extractor: { $0.lastPrompt })
            ?? lastMetadataValue(in: headEntries, extractor: { $0.lastPrompt })
        let summary = lastMetadataValue(in: tailEntries, extractor: { $0.summary })
            ?? lastMetadataValue(in: headEntries, extractor: { $0.summary })
        let firstPrompt = firstPromptText(in: headEntries)
        let displayName = title ?? lastPrompt ?? summary ?? firstPrompt
        guard let displayName, !displayName.isEmpty else { return nil }

        return SessionRecord(
            key: sessionID,
            displayName: displayName,
            updatedAtMs: liteRead.modifiedAtMs
        )
    }

    private func readLiteTranscriptLocked(fileURL: URL) -> LiteTranscriptRead? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let modifiedAt = attrs[.modificationDate] as? Date,
              let fileSize = attrs[.size] as? Int,
              let handle = try? FileHandle(forReadingFrom: fileURL)
        else {
            return nil
        }
        defer { try? handle.close() }

        let readSize = min(fileSize, Self.metadataScanChunkSize)
        let headData = (try? handle.read(upToCount: readSize)) ?? Data()
        let head = String(data: headData, encoding: .utf8) ?? ""

        let tailOffset = max(0, fileSize - Self.metadataScanChunkSize)
        let tail: String
        if tailOffset == 0 {
            tail = head
        } else {
            try? handle.seek(toOffset: UInt64(tailOffset))
            let tailData = (try? handle.read(upToCount: readSize)) ?? Data()
            tail = String(data: tailData, encoding: .utf8) ?? ""
        }

        return LiteTranscriptRead(
            modifiedAtMs: Int64(modifiedAt.timeIntervalSince1970 * 1000),
            fileSize: fileSize,
            head: head,
            tail: tail
        )
    }

    private func decodeLiteEntries(
        from rawText: String,
        dropFirstPartialLine: Bool,
        dropLastPartialLine: Bool
    ) -> [SessionTranscriptEntry] {
        var lines = rawText.components(separatedBy: "\n")
        if dropFirstPartialLine, !lines.isEmpty {
            lines.removeFirst()
        }
        if dropLastPartialLine, !rawText.hasSuffix("\n"), !lines.isEmpty {
            lines.removeLast()
        }

        var entries: [SessionTranscriptEntry] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let data = trimmed.data(using: .utf8),
                  let entry = try? JSONDecoder().decode(SessionTranscriptEntry.self, from: data)
            else {
                continue
            }
            entries.append(entry)
        }
        return entries
    }

    private func firstPromptText(in entries: [SessionTranscriptEntry]) -> String? {
        for entry in entries {
            guard entry.type == MessageRole.user.rawValue,
                  let message = entry.message,
                  message.metadata?["isCompactionSummary"] != "true"
            else {
                continue
            }

            let text = message.content
                .filter { $0.type == "text" }
                .compactMap(\.text)
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            return text.count > 200 ? String(text.prefix(200)) + "…" : text
        }
        return nil
    }

    private func lastMetadataValue(
        in entries: [SessionTranscriptEntry],
        extractor: (SessionTranscriptEntry) -> String?
    ) -> String? {
        for entry in entries.reversed() {
            if let value = extractor(entry), !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private func transcriptModifiedAtMs(for sessionID: String) -> Int64? {
        transcriptModifiedAtMs(fileURL: transcriptPath(for: sessionID))
    }

    private func transcriptModifiedAtMs(fileURL: URL) -> Int64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let modifiedAt = attrs[.modificationDate] as? Date
        else {
            return nil
        }
        return Int64(modifiedAt.timeIntervalSince1970 * 1000)
    }

    private func upsertSessionLocked(
        for sessionID: String,
        displayNameOverride: String?,
        updatedAtMs: Int64? = nil
    ) {
        loadSessionsIfNeededLocked()
        let existing = sessionsByKey[sessionID]
        let resolvedDisplayName = displayNameOverride ?? existing?.displayName ?? sessionID

        sessionsByKey[sessionID] = SessionRecord(
            key: sessionID,
            displayName: resolvedDisplayName,
            updatedAtMs: updatedAtMs ?? Int64(Date().timeIntervalSince1970 * 1000)
        )
    }
}
