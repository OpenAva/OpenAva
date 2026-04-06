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

        let summary = ConversationMessage(sessionID: sessionID, role: .system)
        summary.textContent = "\(ConversationMarkers.contextSummaryPrefix)\n\nEarlier conversation summary."

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

    init(responseText: String) {
        self.responseText = responseText
    }

    var chatCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    func chat(body _: ChatRequestBody) async throws -> ChatResponse {
        lock.lock()
        calls += 1
        lock.unlock()
        return ChatResponse(reasoning: "", text: responseText, images: [], tools: [])
    }

    func streamingChat(body _: ChatRequestBody) async throws -> AnyAsyncSequence<ChatResponseChunk> {
        AsyncStream<ChatResponseChunk> { continuation in
            continuation.finish()
        }.eraseToAnyAsyncSequence()
    }
}
