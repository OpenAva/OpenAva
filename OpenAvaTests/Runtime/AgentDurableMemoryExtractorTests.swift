import ChatClient
import ChatUI
import XCTest
@testable import OpenAva

final class AgentDurableMemoryExtractorTests: XCTestCase {
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

    private func makeConversation(sessionID: String) -> [ConversationMessage] {
        let user = ConversationMessage(sessionID: sessionID, role: .user)
        user.textContent = "以后回答尽量简洁，不要在最后重复总结。"

        let assistant = ConversationMessage(sessionID: sessionID, role: .assistant)
        assistant.textContent = "收到，后续我会保持简洁。"

        return [user, assistant]
    }
}

private final class StubChatClient: ChatClient, @unchecked Sendable {
    let errorCollector = ErrorCollector.new()

    private let responseText: String
    private let lock = NSLock()
    private var calls = 0
    private var streamingCalls = 0

    init(responseText: String) {
        self.responseText = responseText
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
        lock.unlock()
        return ChatResponse(reasoning: "", text: responseText, images: [], tools: [])
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
