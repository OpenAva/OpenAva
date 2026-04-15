import ChatClient
import XCTest
@testable import OpenAva

@MainActor
final class ConversationSessionSystemPromptMemoryTests: XCTestCase {
    func testInjectSystemPromptAddsDynamicMemoryRecallForCurrentRequest() async throws {
        let runtimeRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: runtimeRoot, withIntermediateDirectories: true)
        defer {
            TranscriptStorageProvider.removeProvider(runtimeRootURL: runtimeRoot)
            try? FileManager.default.removeItem(at: runtimeRoot)
        }

        let memoryStore = AgentMemoryStore(runtimeRootURL: runtimeRoot)
        _ = try await memoryStore.upsert(
            name: "Response style",
            type: .feedback,
            description: "Response brevity preference",
            content: "Prefer concise answers and avoid wrap-up summaries.",
            slug: "response-style"
        )

        let delegate = AgentSessionDelegate(
            sessionID: "session-1",
            workspaceRootURL: runtimeRoot,
            runtimeRootURL: runtimeRoot,
            baseSystemPrompt: "You are a helpful assistant.",
            chatClient: nil,
            agentName: "Test Agent",
            agentEmoji: "",
            shouldExtractDurableMemory: false
        )
        let session = ConversationSession(
            id: "session-1",
            configuration: .init(storage: DisposableStorageProvider(), delegate: delegate)
        )

        var requestMessages: [ChatRequestBody.Message] = [
            .user(content: .text("Please keep replies concise and skip repetitive summaries.")),
        ]

        await session.injectSystemPrompt(&requestMessages, capabilities: [])

        guard case let .system(content, _) = try XCTUnwrap(requestMessages.first) else {
            XCTFail("Expected injected system prompt at first position")
            return
        }
        guard case let .text(promptText) = content else {
            XCTFail("Expected injected system prompt to use text content")
            return
        }

        XCTAssertTrue(promptText.contains("## Dynamic Memory Recall"))
        XCTAssertTrue(promptText.contains("Response style"))
        XCTAssertTrue(promptText.contains("Prefer concise answers and avoid wrap-up summaries."))
        XCTAssertFalse(promptText.contains("Indexed durable memories:"))
    }

    func testInjectSystemPromptOmitsDynamicRecallWhenNoMemoryMatches() async throws {
        let runtimeRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: runtimeRoot, withIntermediateDirectories: true)
        defer {
            TranscriptStorageProvider.removeProvider(runtimeRootURL: runtimeRoot)
            try? FileManager.default.removeItem(at: runtimeRoot)
        }

        let memoryStore = AgentMemoryStore(runtimeRootURL: runtimeRoot)
        _ = try await memoryStore.upsert(
            name: "Preferred language",
            type: .user,
            description: "Preferred response language",
            content: "Reply in simplified Chinese.",
            slug: "language"
        )

        let delegate = AgentSessionDelegate(
            sessionID: "session-2",
            workspaceRootURL: runtimeRoot,
            runtimeRootURL: runtimeRoot,
            baseSystemPrompt: "You are a helpful assistant.",
            chatClient: nil,
            agentName: "Test Agent",
            agentEmoji: "",
            shouldExtractDurableMemory: false
        )
        let session = ConversationSession(
            id: "session-2",
            configuration: .init(storage: DisposableStorageProvider(), delegate: delegate)
        )

        var requestMessages: [ChatRequestBody.Message] = [
            .user(content: .text("Summarize the latest build pipeline issue.")),
        ]

        await session.injectSystemPrompt(&requestMessages, capabilities: [])

        guard case let .system(content, _) = try XCTUnwrap(requestMessages.first) else {
            XCTFail("Expected injected system prompt at first position")
            return
        }
        guard case let .text(promptText) = content else {
            XCTFail("Expected injected system prompt to use text content")
            return
        }

        XCTAssertFalse(promptText.contains("## Dynamic Memory Recall"))
        XCTAssertFalse(promptText.contains("Indexed durable memories:"))
        XCTAssertTrue(promptText.contains("No fixed durable memory index is injected for this turn."))
    }

    func testInjectSystemPromptExpandsContinuationQueryWithRecentUserContext() async throws {
        let runtimeRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: runtimeRoot, withIntermediateDirectories: true)
        defer {
            TranscriptStorageProvider.removeProvider(runtimeRootURL: runtimeRoot)
            try? FileManager.default.removeItem(at: runtimeRoot)
        }

        let memoryStore = AgentMemoryStore(runtimeRootURL: runtimeRoot)
        _ = try await memoryStore.upsert(
            name: "Build pipeline issue",
            type: .project,
            description: "Catalyst host refresh token regression",
            content: "The current build issue is the missing catalystHostRefreshToken symbol in ChatRootView.",
            slug: "build-pipeline-issue"
        )

        let delegate = AgentSessionDelegate(
            sessionID: "session-3",
            workspaceRootURL: runtimeRoot,
            runtimeRootURL: runtimeRoot,
            baseSystemPrompt: "You are a helpful assistant.",
            chatClient: nil,
            agentName: "Test Agent",
            agentEmoji: "",
            shouldExtractDurableMemory: false
        )
        let session = ConversationSession(
            id: "session-3",
            configuration: .init(storage: DisposableStorageProvider(), delegate: delegate)
        )

        var requestMessages: [ChatRequestBody.Message] = [
            .user(content: .text("Investigate the catalystHostRefreshToken build failure in ChatRootView and explain the regression.")),
            .assistant(content: .text("I found the likely source of the failure.")),
            .user(content: .text("继续优化一下")),
        ]

        await session.injectSystemPrompt(&requestMessages, capabilities: [])

        guard case let .system(content, _) = try XCTUnwrap(requestMessages.first) else {
            XCTFail("Expected injected system prompt at first position")
            return
        }
        guard case let .text(promptText) = content else {
            XCTFail("Expected injected system prompt to use text content")
            return
        }

        XCTAssertTrue(promptText.contains("## Dynamic Memory Recall"))
        XCTAssertTrue(promptText.contains("Current request query: 继续优化一下"))
        XCTAssertTrue(promptText.contains("Investigate the catalystHostRefreshToken build failure in ChatRootView and explain the regression."))
        XCTAssertTrue(promptText.contains("missing catalystHostRefreshToken symbol in ChatRootView"))
    }
}
