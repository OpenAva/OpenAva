import ChatClient
import ChatUI
import XCTest
@testable import OpenAva

final class AgentDurableMemoryExtractorTests: XCTestCase {
    func testSessionDelegateCanDisableAutomaticDurableMemoryExtraction() async throws {
        let runtimeRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: runtimeRoot, withIntermediateDirectories: true)
        defer {
            TranscriptStorageProvider.removeProvider(runtimeRootURL: runtimeRoot)
            try? FileManager.default.removeItem(at: runtimeRoot)
        }

        let chatClient = StubChatClient(
            responseText: #"{"memories":[{"name":"User prefers terse answers","type":"feedback","description":"Response brevity preference","content":"Prefer concise answers with no trailing summaries.","slug":"response-style"}]}"#
        )
        let delegate = AgentSessionDelegate(
            sessionID: "session-1",
            workspaceRootURL: runtimeRoot,
            runtimeRootURL: runtimeRoot,
            baseSystemPrompt: nil,
            chatClient: chatClient,
            agentName: "Test Agent",
            agentEmoji: "",
            shouldExtractDurableMemory: false
        )
        let store = AgentMemoryStore(runtimeRootURL: runtimeRoot)

        await delegate.sessionDidPersistMessages(makeConversation(sessionID: "session-1"), for: "session-1")

        let entries = try await store.listEntries()
        XCTAssertTrue(entries.isEmpty)
        XCTAssertEqual(chatClient.chatCallCount, 0)
        XCTAssertEqual(chatClient.streamingChatCallCount, 0)
    }

    func testExtractorWritesDurableMemoryAndAdvancesCursor() async throws {
        let runtimeRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: runtimeRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: runtimeRoot) }

        let responseJSON = #"{"memories":[{"name":"User prefers terse answers","type":"feedback","description":"Response brevity preference","content":"Prefer concise answers with no trailing summaries.","slug":"response-style"}]}"#
        let chatClient = StubChatClient(responseText: responseJSON)
        let extractor = AgentDurableMemoryExtractor(runtimeRootURL: runtimeRoot, chatClient: chatClient)
        let store = AgentMemoryStore(runtimeRootURL: runtimeRoot)

        let messages = makeConversation(sessionID: "session-1")
        await extractor.extractIfNeeded(for: "session-1", messages: messages)
        await extractor.extractIfNeeded(for: "session-1", messages: messages)

        let entries = try await store.listEntries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.slug, "response-style")
        XCTAssertEqual(entries.first?.type, .feedback)
        XCTAssertEqual(chatClient.chatCallCount, 1)
        XCTAssertEqual(chatClient.streamingChatCallCount, 0)
    }

    func testExtractorSkipsPreservedSegmentWhenCursorWasCompactedAway() async throws {
        let runtimeRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: runtimeRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: runtimeRoot) }

        let chatClient = StubChatClient(responseText: #"{"memories":[]}"#)
        let extractor = AgentDurableMemoryExtractor(runtimeRootURL: runtimeRoot, chatClient: chatClient)
        let sessionID = "session-1"

        let cursorDirectory = runtimeRoot
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(sessionID, isDirectory: true)
        try FileManager.default.createDirectory(at: cursorDirectory, withIntermediateDirectories: true)
        try #"{"lastProcessedMessageID":"removed-message"}"#.write(
            to: cursorDirectory.appendingPathComponent("durable-memory-extraction-cursor.json", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )

        let keptUser = ConversationMessage(sessionID: sessionID, role: .user)
        keptUser.textContent = "记住我偏好简洁回复。"

        let keptAssistant = ConversationMessage(sessionID: sessionID, role: .assistant)
        keptAssistant.textContent = "好的，我会保持简洁。"

        let summary = ConversationMessage(sessionID: sessionID, role: .user)
        summary.textContent = "\(ConversationMarkers.contextSummaryPrefix)\n\nEarlier conversation summary."
        summary.metadata["isCompactionSummary"] = "true"

        let boundary = ConversationMessage(sessionID: sessionID, role: .system)
        boundary.textContent = "\(ConversationMarkers.compactBoundaryPrefix)\n\nConversation compacted."
        boundary.subtype = "compact_boundary"
        boundary.compactBoundaryMetadata = CompactBoundaryMetadata(
            trigger: "auto",
            preTokens: 1024,
            preservedSegment: .init(
                headUUID: keptUser.id,
                anchorUUID: summary.id,
                tailUUID: keptAssistant.id
            )
        )

        await extractor.extractIfNeeded(for: sessionID, messages: [boundary, summary, keptUser, keptAssistant])

        XCTAssertEqual(chatClient.chatCallCount, 0)
        XCTAssertEqual(chatClient.streamingChatCallCount, 0)
    }

    func testExtractorAcceptsWrappedJSONResponse() async throws {
        let runtimeRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: runtimeRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: runtimeRoot) }

        let responseText = #"""
        I found one durable memory.
        ```json
        {"memories":[{"name":"User prefers Chinese","type":"user","description":"Preferred response language","content":"Always reply in simplified Chinese unless asked otherwise.","slug":"language-preference"}]}
        ```
        """#
        let chatClient = StubChatClient(responseText: responseText)
        let extractor = AgentDurableMemoryExtractor(runtimeRootURL: runtimeRoot, chatClient: chatClient)
        let store = AgentMemoryStore(runtimeRootURL: runtimeRoot)

        await extractor.extractIfNeeded(for: "session-1", messages: makeConversation(sessionID: "session-1"))

        let entries = try await store.listEntries()
        XCTAssertEqual(entries.map(\.slug), ["language-preference"])
        XCTAssertEqual(entries.first?.type, .user)
        XCTAssertEqual(chatClient.chatCallCount, 1)
        XCTAssertEqual(chatClient.streamingChatCallCount, 0)
    }

    func testExtractorReusesExistingTopicSlugWhenResponseOmitsSlug() async throws {
        let runtimeRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: runtimeRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: runtimeRoot) }

        let store = AgentMemoryStore(runtimeRootURL: runtimeRoot)
        let existing = try await store.upsert(
            name: "Response style",
            type: .feedback,
            description: "Response brevity preference",
            content: "Prefer concise answers.",
            slug: "response-style"
        )
        let responseJSON = #"{"memories":[{"name":"User likes shorter responses","type":"feedback","description":"Response brevity preference","content":"Prefer concise answers and avoid wrap-up summaries."}]}"#
        let chatClient = StubChatClient(responseText: responseJSON)
        let extractor = AgentDurableMemoryExtractor(runtimeRootURL: runtimeRoot, chatClient: chatClient)

        await extractor.extractIfNeeded(for: "session-1", messages: makeConversation(sessionID: "session-1"))

        let entries = try await store.listEntries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.slug, existing.slug)
        XCTAssertEqual(entries.first?.version, 2)
        XCTAssertTrue(entries.first?.content.contains("wrap-up summaries") == true)

        let archivedVersionURL = runtimeRoot
            .appendingPathComponent("memory", isDirectory: true)
            .appendingPathComponent(".versions", isDirectory: true)
            .appendingPathComponent(existing.slug, isDirectory: true)
            .appendingPathComponent("v1.md", isDirectory: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: archivedVersionURL.path))
    }

    func testExtractorInfersConflictsForChangedPreferenceWhenNewSlugIsReturned() async throws {
        let runtimeRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: runtimeRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: runtimeRoot) }

        let store = AgentMemoryStore(runtimeRootURL: runtimeRoot)
        let existing = try await store.upsert(
            name: "Preferred response language English",
            type: .user,
            description: "Preferred response language",
            content: "Reply in English.",
            slug: "language-english"
        )
        let responseJSON = #"{"memories":[{"name":"Preferred response language Chinese","type":"user","description":"Preferred response language","content":"Reply in simplified Chinese.","slug":"language-chinese"}]}"#
        let chatClient = StubChatClient(responseText: responseJSON)
        let extractor = AgentDurableMemoryExtractor(runtimeRootURL: runtimeRoot, chatClient: chatClient)

        await extractor.extractIfNeeded(for: "session-1", messages: makeConversation(sessionID: "session-1"))

        let entries = try await store.listEntries()
        XCTAssertEqual(entries.map(\.slug), ["language-chinese"])

        let previousFileURL = runtimeRoot
            .appendingPathComponent("memory", isDirectory: true)
            .appendingPathComponent("\(existing.slug).md", isDirectory: false)
        let raw = try String(contentsOf: previousFileURL, encoding: .utf8)
        XCTAssertTrue(raw.contains("status: conflicted"))
        XCTAssertTrue(raw.contains("resolved_by: language-chinese"))
    }

    private func makeConversation(sessionID: String) -> [ConversationMessage] {
        let user = ConversationMessage(sessionID: sessionID, role: .user)
        user.textContent = "以后回答尽量简洁，不要在最后重复总结。"

        let assistant = ConversationMessage(sessionID: sessionID, role: .assistant)
        assistant.textContent = "收到，后续我会保持简洁。"

        return [user, assistant]
    }
}

@MainActor
final class ConversationCompactionTests: XCTestCase {
    func testManualCompactBuildsBoundarySummaryAndHiddenAttachments() async throws {
        let storage = DisposableStorageProvider()
        let toolProvider = StubToolProvider()
        let session = ConversationSession(
            id: "compact-session",
            configuration: .init(storage: storage, tools: toolProvider)
        )
        let originalIDs = seedConversation(into: session, turnCount: 8)

        let client = StubChatClient(
            responseText: """
            <analysis>scratch work</analysis>
            <summary>
            1. Primary request and intent: align compact behavior.
            2. Key technical concepts: boundary markers, summaries, PTL retry.
            </summary>
            """
        )
        let model = ConversationSession.Model(
            client: client,
            capabilities: [.tool],
            contextLength: 32000,
            autoCompactEnabled: true
        )

        try await session.compact(model: model)

        XCTAssertEqual(client.chatCallCount, 1)
        XCTAssertEqual(session.messages.filter(\.isCompactBoundary).count, 1)
        XCTAssertEqual(session.messages.filter(\.isCompactionSummary).count, 1)
        XCTAssertEqual(session.messages.filter(\.isCompactAttachment).count, 3)

        let summary = try XCTUnwrap(session.messages.first(where: { $0.isCompactionSummary }))
        XCTAssertFalse(summary.textContent.contains("<analysis>"))
        XCTAssertTrue(summary.textContent.contains("align compact behavior"))

        let preservedIDs = session.messages
            .filter { !$0.isCompactBoundary && !$0.isCompactionSummary && !$0.isCompactAttachment }
            .map(\.id)
        XCTAssertEqual(preservedIDs, Array(originalIDs.suffix(4)))
    }

    func testManualCompactRetriesWhenPromptTooLong() async throws {
        let storage = DisposableStorageProvider()
        let session = ConversationSession(id: "compact-retry", configuration: .init(storage: storage))
        _ = seedConversation(into: session, turnCount: 10)

        let client = StubChatClient(scriptedResponses: [
            .failure("PROMPT TOO LONG: reduce the length of the messages"),
            .success("<summary>Recovered compact summary.</summary>"),
        ])
        let model = ConversationSession.Model(client: client, capabilities: [], contextLength: 32000, autoCompactEnabled: true)

        try await session.compact(model: model)

        XCTAssertEqual(client.chatCallCount, 2)
        let summary = try XCTUnwrap(session.messages.first(where: { $0.isCompactionSummary }))
        XCTAssertTrue(summary.textContent.contains("Recovered compact summary."))
    }

    func testPartialCompactFromKeepsEarlierMessagesBeforeSummary() async throws {
        let storage = DisposableStorageProvider()
        let session = ConversationSession(id: "partial-from", configuration: .init(storage: storage))
        let ids = seedConversation(into: session, turnCount: 6)
        let pivotID = ids[4]

        let client = StubChatClient(responseText: "<summary>Later work compacted.</summary>")
        let model = ConversationSession.Model(client: client, capabilities: [], contextLength: 32000, autoCompactEnabled: true)

        try await session.partialCompact(around: pivotID, direction: .from, model: model)

        let visibleIDs = session.messages
            .filter { !$0.isCompactBoundary && !$0.isCompactionSummary && !$0.isCompactAttachment }
            .map(\.id)
        XCTAssertEqual(visibleIDs, Array(ids.prefix(4)))
        XCTAssertFalse(visibleIDs.contains(pivotID))

        let summaryIndex = try XCTUnwrap(session.messages.firstIndex(where: { $0.isCompactionSummary }))
        let boundaryIndex = try XCTUnwrap(session.messages.firstIndex(where: { $0.isCompactBoundary }))
        XCTAssertGreaterThan(summaryIndex, boundaryIndex)
    }

    func testReloadKeepsCompactedContextAfterCompact() async throws {
        let runtimeRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: runtimeRoot, withIntermediateDirectories: true)
        defer {
            TranscriptStorageProvider.removeProvider(runtimeRootURL: runtimeRoot)
            try? FileManager.default.removeItem(at: runtimeRoot)
        }

        let storage = TranscriptStorageProvider.provider(runtimeRootURL: runtimeRoot)
        let sessionID = "transcript-reload"
        let session = ConversationSession(id: sessionID, configuration: .init(storage: storage))
        let originalIDs = seedConversation(into: session, turnCount: 8)

        let client = StubChatClient(responseText: "<summary>Compacted history.</summary>")
        let model = ConversationSession.Model(client: client, capabilities: [], contextLength: 32000, autoCompactEnabled: true)

        try await session.compact(model: model)

        let compactedContextIDs = storage.messages(in: sessionID)
            .filter { !$0.isCompactBoundary && !$0.isCompactionSummary && !$0.isCompactAttachment }
            .map(\.id)
        XCTAssertLessThan(compactedContextIDs.count, originalIDs.count)

        let reloaded = ConversationSession(id: sessionID, configuration: .init(storage: storage))
        let reloadedIDs = reloaded.messages
            .filter { !$0.isCompactBoundary && !$0.isCompactionSummary && !$0.isCompactAttachment }
            .map(\.id)

        XCTAssertEqual(reloadedIDs, compactedContextIDs)
        XCTAssertTrue(reloaded.messages.contains(where: { $0.isCompactBoundary }))
    }

    func testRollbackAfterCompactDoesNotRestoreDeletedTranscriptMessages() async throws {
        let runtimeRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: runtimeRoot, withIntermediateDirectories: true)
        defer {
            TranscriptStorageProvider.removeProvider(runtimeRootURL: runtimeRoot)
            try? FileManager.default.removeItem(at: runtimeRoot)
        }

        let storage = TranscriptStorageProvider.provider(runtimeRootURL: runtimeRoot)
        let sessionID = "transcript-rollback"
        let session = ConversationSession(id: sessionID, configuration: .init(storage: storage))
        let originalIDs = seedConversation(into: session, turnCount: 8)

        let client = StubChatClient(responseText: "<summary>Compacted history.</summary>")
        let model = ConversationSession.Model(client: client, capabilities: [], contextLength: 32000, autoCompactEnabled: true)

        try await session.compact(model: model)

        let rollbackTargetID = originalIDs[4]
        session.delete(after: rollbackTargetID)
        session.delete(rollbackTargetID)

        let remainingVisibleIDs = session.messages
            .filter { !$0.isCompactBoundary && !$0.isCompactionSummary && !$0.isCompactAttachment }
            .map(\.id)
        XCTAssertTrue(remainingVisibleIDs.isEmpty)

        let reloaded = ConversationSession(id: sessionID, configuration: .init(storage: storage))
        let reloadedVisibleIDs = reloaded.messages
            .filter { !$0.isCompactBoundary && !$0.isCompactionSummary && !$0.isCompactAttachment }
            .map(\.id)
        XCTAssertTrue(reloadedVisibleIDs.isEmpty)
        XCTAssertTrue(reloaded.messages.contains(where: { $0.isCompactBoundary }))
    }

    private func seedConversation(into session: ConversationSession, turnCount: Int) -> [String] {
        var ids: [String] = []
        for index in 0 ..< turnCount {
            let role: MessageRole = index.isMultiple(of: 2) ? .user : .assistant
            let message = session.appendNewMessage(role: role)
            message.textContent = "message-\(index)"
            message.createdAt = Date(timeIntervalSince1970: TimeInterval(index))
            ids.append(message.id)
        }
        session.persistMessages()
        return ids
    }
}

private enum StubChatClientResponse {
    case success(String)
    case failure(String)
}

private struct StubChatClientError: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}

private final class StubChatClient: ChatClient, @unchecked Sendable {
    let errorCollector = ErrorCollector.new()

    private var scriptedResponses: [StubChatClientResponse]
    private let lock = NSLock()
    private var calls = 0
    private var streamingCalls = 0

    init(responseText: String) {
        scriptedResponses = [.success(responseText)]
    }

    init(scriptedResponses: [StubChatClientResponse]) {
        self.scriptedResponses = scriptedResponses
    }

    var chatCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    var streamingChatCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return streamingCalls
    }

    func chat(body _: ChatRequestBody) async throws -> ChatResponse {
        lock.lock()
        calls += 1
        let response: StubChatClientResponse
        if scriptedResponses.count > 1 {
            response = scriptedResponses.removeFirst()
        } else {
            response = scriptedResponses.first ?? .success("")
        }
        lock.unlock()
        switch response {
        case let .success(text):
            return ChatResponse(reasoning: "", text: text, images: [], tools: [])
        case let .failure(message):
            await errorCollector.collect(message)
            throw StubChatClientError(message: message)
        }
    }

    func streamingChat(body _: ChatRequestBody) async throws -> AnyAsyncSequence<ChatResponseChunk> {
        lock.lock()
        streamingCalls += 1
        lock.unlock()
        return AsyncStream<ChatResponseChunk> { continuation in
            continuation.finish()
        }.eraseToAnyAsyncSequence()
    }
}

private final class StubToolProvider: ToolProvider, @unchecked Sendable {
    func enabledTools() async -> [ChatRequestBody.Tool] {
        [
            .function(
                name: "Read",
                description: "Read a file",
                parameters: nil,
                strict: nil
            ),
        ]
    }

    func findTool(for _: ToolRequest) async -> ToolExecutor? {
        nil
    }

    func executeTool(
        _: ToolExecutor,
        parameters _: String
    ) async throws -> ToolResult {
        ToolResult(text: "")
    }
}
