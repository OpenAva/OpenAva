import ChatUI
import XCTest
@testable import OpenAva

@MainActor
final class TranscriptStorageProviderCollapsePersistenceTests: XCTestCase {
    func testToggleToolResultCollapsePersistsAcrossReload() throws {
        let runtimeRootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: runtimeRootURL, withIntermediateDirectories: true)
        TranscriptStorageProvider.removeProvider(runtimeRootURL: runtimeRootURL)
        defer {
            TranscriptStorageProvider.removeProvider(runtimeRootURL: runtimeRootURL)
            try? FileManager.default.removeItem(at: runtimeRootURL)
        }

        let storage = TranscriptStorageProvider.provider(runtimeRootURL: runtimeRootURL)
        let session = ConversationSession(id: "main", configuration: .init(storage: storage))
        let toolCallID = "tool-call-1"

        let message = session.appendNewMessage(role: .assistant) { message in
            message.parts = [
                .toolCall(
                    ToolCallContentPart(
                        id: toolCallID,
                        toolName: "fs_read",
                        apiName: "fs_read",
                        parameters: "{\"file\":\"notes.txt\"}",
                        state: .succeeded
                    )
                ),
                .toolResult(
                    ToolResultContentPart(
                        toolCallID: toolCallID,
                        result: "file content",
                        isCollapsed: true
                    )
                ),
            ]
        }
        session.persistMessages()

        session.toggleToolResultCollapse(for: message.id, toolCallID: toolCallID)

        TranscriptStorageProvider.removeProvider(runtimeRootURL: runtimeRootURL)
        let reloadedStorage = TranscriptStorageProvider.provider(runtimeRootURL: runtimeRootURL)
        let reloadedMessages = reloadedStorage.messages(in: "main")

        guard let reloadedMessage = reloadedMessages.first else {
            return XCTFail("Expected reloaded message")
        }
        guard let toolResult = reloadedMessage.parts.compactMap({ part -> ToolResultContentPart? in
            guard case let .toolResult(value) = part else { return nil }
            return value
        }).first else {
            return XCTFail("Expected reloaded tool result")
        }

        XCTAssertFalse(toolResult.isCollapsed)
    }

    func testToggleReasoningCollapsePersistsAcrossReload() throws {
        let runtimeRootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: runtimeRootURL, withIntermediateDirectories: true)
        TranscriptStorageProvider.removeProvider(runtimeRootURL: runtimeRootURL)
        defer {
            TranscriptStorageProvider.removeProvider(runtimeRootURL: runtimeRootURL)
            try? FileManager.default.removeItem(at: runtimeRootURL)
        }

        let storage = TranscriptStorageProvider.provider(runtimeRootURL: runtimeRootURL)
        let session = ConversationSession(id: "main", configuration: .init(storage: storage))

        let message = session.appendNewMessage(role: .assistant) { message in
            message.parts = [
                .reasoning(
                    ReasoningContentPart(
                        text: "thinking",
                        duration: 1.5,
                        isCollapsed: false
                    )
                ),
                .text(TextContentPart(text: "done")),
            ]
        }
        session.persistMessages()

        session.toggleReasoningCollapse(for: message.id)

        TranscriptStorageProvider.removeProvider(runtimeRootURL: runtimeRootURL)
        let reloadedStorage = TranscriptStorageProvider.provider(runtimeRootURL: runtimeRootURL)
        let reloadedMessages = reloadedStorage.messages(in: "main")

        guard let reloadedMessage = reloadedMessages.first else {
            return XCTFail("Expected reloaded message")
        }
        guard let reasoning = reloadedMessage.parts.compactMap({ part -> ReasoningContentPart? in
            guard case let .reasoning(value) = part else { return nil }
            return value
        }).first else {
            return XCTFail("Expected reloaded reasoning part")
        }

        XCTAssertTrue(reasoning.isCollapsed)
    }

    func testReloadedExecutingSessionMarksOrphanRunningToolCallFailed() throws {
        let runtimeRootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: runtimeRootURL, withIntermediateDirectories: true)
        TranscriptStorageProvider.removeProvider(runtimeRootURL: runtimeRootURL)
        defer {
            TranscriptStorageProvider.removeProvider(runtimeRootURL: runtimeRootURL)
            try? FileManager.default.removeItem(at: runtimeRootURL)
        }

        let storage = TranscriptStorageProvider.provider(runtimeRootURL: runtimeRootURL)
        let session = ConversationSession(id: "main", configuration: .init(storage: storage))
        let toolCallID = "tool-call-running"

        _ = session.appendNewMessage(role: .assistant) { message in
            message.parts = [
                .toolCall(
                    ToolCallContentPart(
                        id: toolCallID,
                        toolName: "fs_read",
                        apiName: "fs_read",
                        parameters: "{\"file\":\"draft.md\"}",
                        state: .running
                    )
                ),
            ]
        }
        session.persistMessages()
        storage.recordTurnStarted(sessionID: "main")

        TranscriptStorageProvider.removeProvider(runtimeRootURL: runtimeRootURL)
        let reloadedStorage = TranscriptStorageProvider.provider(runtimeRootURL: runtimeRootURL)
        let reloadedMessages = reloadedStorage.messages(in: "main")

        guard let reloadedMessage = reloadedMessages.first else {
            return XCTFail("Expected reloaded assistant message")
        }
        guard let toolCall = reloadedMessage.parts.compactMap({ part -> ToolCallContentPart? in
            guard case let .toolCall(value) = part else { return nil }
            return value
        }).first else {
            return XCTFail("Expected reloaded tool call")
        }

        XCTAssertEqual(reloadedStorage.sessionStatus(for: "main"), "interrupted")
        XCTAssertEqual(toolCall.state, .failed)
    }

    func testReloadedInterruptedSessionShowsRetryAction() throws {
        let runtimeRootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: runtimeRootURL, withIntermediateDirectories: true)
        TranscriptStorageProvider.removeProvider(runtimeRootURL: runtimeRootURL)
        defer {
            TranscriptStorageProvider.removeProvider(runtimeRootURL: runtimeRootURL)
            try? FileManager.default.removeItem(at: runtimeRootURL)
        }

        let storage = TranscriptStorageProvider.provider(runtimeRootURL: runtimeRootURL)
        let session = ConversationSession(id: "main", configuration: .init(storage: storage))

        _ = session.appendNewMessage(role: .assistant) { message in
            message.parts = [
                .toolCall(
                    ToolCallContentPart(
                        id: "tool-call-2",
                        toolName: "fs_read",
                        apiName: "fs_read",
                        parameters: "{}",
                        state: .running
                    )
                ),
            ]
        }
        session.persistMessages()
        storage.recordTurnStarted(sessionID: "main")

        TranscriptStorageProvider.removeProvider(runtimeRootURL: runtimeRootURL)
        let reloadedStorage = TranscriptStorageProvider.provider(runtimeRootURL: runtimeRootURL)
        let reloadedSession = ConversationSession(id: "main", configuration: .init(storage: reloadedStorage))

        XCTAssertTrue(reloadedSession.showsInterruptedRetryAction)
    }
}
