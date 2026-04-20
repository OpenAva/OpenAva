import ChatClient
import XCTest
@testable import OpenAva

@MainActor
final class ConversationSessionSystemPromptMemoryTests: XCTestCase {
    func testBuildInstructionMessageAddsDynamicMemoryRecallForCurrentRequest() async throws {
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
            runtimeRootURL: runtimeRoot,
            chatClient: nil,
            agentName: "Test Agent",
            agentEmoji: "",
            shouldExtractDurableMemory: false
        )
        let session = ConversationSession(
            id: "session-1",
            configuration: .init(
                storage: DisposableStorageProvider(),
                delegate: delegate,
                systemPromptProvider: {
                    AgentContextLoader.composeSystemPrompt(
                        baseSystemPrompt: "You are a helpful assistant.",
                        workspaceRootURL: runtimeRoot
                    ) ?? "You are a helpful assistant."
                }
            )
        )

        _ = session.appendNewMessage(role: .user) { message in
            message.textContent = "Response style"
        }

        let builtRequestMessages = await session.buildMessages(capabilities: [])

        guard case let .system(content, _) = try XCTUnwrap(builtRequestMessages.first) else {
            XCTFail("Expected injected system prompt at first position")
            return
        }
        let promptText = try extractPromptText(from: content)

        XCTAssertTrue(promptText.contains("## Dynamic Memory Recall"))
        XCTAssertTrue(promptText.contains("Response style"))
        XCTAssertTrue(promptText.contains("Prefer concise answers and avoid wrap-up summaries."))
        XCTAssertFalse(promptText.contains("Indexed durable memories:"))
    }

    func testBuildInstructionMessageOmitsDynamicRecallWhenNoMemoryMatches() async throws {
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
            runtimeRootURL: runtimeRoot,
            chatClient: nil,
            agentName: "Test Agent",
            agentEmoji: "",
            shouldExtractDurableMemory: false
        )
        let session = ConversationSession(
            id: "session-2",
            configuration: .init(
                storage: DisposableStorageProvider(),
                delegate: delegate,
                systemPromptProvider: {
                    AgentContextLoader.composeSystemPrompt(
                        baseSystemPrompt: "You are a helpful assistant.",
                        workspaceRootURL: runtimeRoot
                    ) ?? "You are a helpful assistant."
                }
            )
        )

        _ = session.appendNewMessage(role: .user) { message in
            message.textContent = "Summarize the latest build pipeline issue."
        }

        let builtRequestMessages = await session.buildMessages(capabilities: [])

        guard case let .system(content, _) = try XCTUnwrap(builtRequestMessages.first) else {
            XCTFail("Expected injected system prompt at first position")
            return
        }
        let promptText = try extractPromptText(from: content)

        XCTAssertFalse(promptText.contains("## Dynamic Memory Recall"))
        XCTAssertFalse(promptText.contains("Indexed durable memories:"))
        XCTAssertTrue(promptText.contains("Relevant memories may be recalled dynamically for the current request or fetched with memory tools when needed."))
    }

    func testBuildInstructionMessageUsesOnlyCurrentRequestQueryForDynamicRecall() async throws {
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
            runtimeRootURL: runtimeRoot,
            chatClient: nil,
            agentName: "Test Agent",
            agentEmoji: "",
            shouldExtractDurableMemory: false
        )
        let session = ConversationSession(
            id: "session-3",
            configuration: .init(
                storage: DisposableStorageProvider(),
                delegate: delegate,
                systemPromptProvider: {
                    AgentContextLoader.composeSystemPrompt(
                        baseSystemPrompt: "You are a helpful assistant.",
                        workspaceRootURL: runtimeRoot
                    ) ?? "You are a helpful assistant."
                }
            )
        )

        _ = session.appendNewMessage(role: .user) { message in
            message.textContent = "Investigate the catalystHostRefreshToken build failure in ChatRootView and explain the regression."
        }
        _ = session.appendNewMessage(role: .assistant) { message in
            message.textContent = "I found the likely source of the failure."
        }
        _ = session.appendNewMessage(role: .user) { message in
            message.textContent = "Catalyst host refresh token regression"
        }

        let builtRequestMessages = await session.buildMessages(capabilities: [])

        guard case let .system(content, _) = try XCTUnwrap(builtRequestMessages.first) else {
            XCTFail("Expected injected system prompt at first position")
            return
        }
        let promptText = try extractPromptText(from: content)

        XCTAssertTrue(promptText.contains("## Dynamic Memory Recall"))
        XCTAssertTrue(promptText.contains("Current request query: Catalyst host refresh token regression"))
        XCTAssertTrue(promptText.contains("Build pipeline issue"))
        XCTAssertTrue(promptText.contains("missing catalystHostRefreshToken symbol in ChatRootView"))
        XCTAssertFalse(promptText.contains("Investigate the catalystHostRefreshToken build failure in ChatRootView and explain the regression."))
    }

    func testBuildMessagesUsesDeveloperRoleForInstructionPrompt() async throws {
        let session = ConversationSession(
            id: "session-developer-role",
            configuration: .init(
                storage: DisposableStorageProvider(),
                systemPromptProvider: { "You are a helpful assistant." }
            )
        )
        _ = session.appendNewMessage(role: .user) { message in
            message.textContent = "Hello"
        }

        let builtRequestMessages = await session.buildMessages(capabilities: [.developerRole])

        guard case let .developer(content, _) = try XCTUnwrap(builtRequestMessages.first) else {
            XCTFail("Expected developer instruction prompt at first position")
            return
        }
        let promptText = try extractPromptText(from: content)
        XCTAssertEqual(promptText, "You are a helpful assistant.")
    }

    private func extractPromptText(
        from content: ChatRequestBody.Message.MessageContent<String, [String]>
    ) throws -> String {
        guard case let .text(promptText) = content else {
            XCTFail("Expected injected system prompt to use text content")
            return ""
        }
        return promptText
    }
}
