import ChatClient
import ChatUI
import XCTest
@testable import OpenAva

@MainActor
final class ConversationSessionPromptInputTests: XCTestCase {
    func testPromptInputStoresSourceMetadata() {
        let input = ConversationSession.PromptInput(
            text: "internal request",
            source: .heartbeat,
            metadata: [HeartbeatSupport.metadataModeKey: HeartbeatSupport.metadataModeScheduledValue]
        )

        XCTAssertEqual(input.metadata[ConversationSession.PromptInput.sourceMetadataKey], "heartbeat")
    }

    func testTeamPromptInputStoresSourceAndTeamMetadata() {
        let input = ConversationSession.PromptInput(
            text: "team request",
            source: .teamTask,
            metadata: [
                ConversationSession.PromptInput.teamMessageTypeMetadataKey: "scheduled_message",
                ConversationSession.PromptInput.teamSenderMetadataKey: "Coordinator",
            ]
        )

        XCTAssertEqual(input.metadata[ConversationSession.PromptInput.sourceMetadataKey], "team_task")
        XCTAssertEqual(input.metadata[ConversationSession.PromptInput.teamMessageTypeMetadataKey], "scheduled_message")
        XCTAssertEqual(input.metadata[ConversationSession.PromptInput.teamSenderMetadataKey], "Coordinator")
    }

    func testPromptInputSourceOverridesConflictingMetadata() {
        let input = ConversationSession.PromptInput(
            text: "heartbeat request",
            source: .heartbeat,
            metadata: [ConversationSession.PromptInput.sourceMetadataKey: "user"]
        )

        XCTAssertEqual(input.metadata[ConversationSession.PromptInput.sourceMetadataKey], "heartbeat")
    }

    func testBuildRequestMessagesUsesUserMessageText() {
        let session = ConversationSession(
            id: "main",
            configuration: .init(storage: InMemoryStorageProvider())
        )
        let message = ConversationMessage(sessionID: "main", role: .user)
        message.textContent = "visible message"

        let requestMessages = session.buildRequestMessages(from: message, capabilities: [])
        guard case let .user(content, _) = requestMessages.first else {
            return XCTFail("Expected user request message")
        }
        guard case let .text(text) = content else {
            return XCTFail("Expected plain text user request")
        }
        XCTAssertEqual(text, "visible message")
    }
}

private final class InMemoryStorageProvider: StorageProvider {
    private var storeBySessionID: [String: [ConversationMessage]] = [:]
    private var titlesBySessionID: [String: String] = [:]

    func createMessage(in sessionID: String, role: MessageRole) -> ConversationMessage {
        ConversationMessage(sessionID: sessionID, role: role)
    }

    func save(_ messages: [ConversationMessage]) {
        guard let sessionID = messages.first?.sessionID else { return }
        storeBySessionID[sessionID] = messages
    }

    func messages(in sessionID: String) -> [ConversationMessage] {
        storeBySessionID[sessionID] ?? []
    }

    func delete(_ messageIDs: [String]) {
        guard !messageIDs.isEmpty else { return }
        for sessionID in storeBySessionID.keys {
            storeBySessionID[sessionID]?.removeAll { messageIDs.contains($0.id) }
        }
    }

    func title(for id: String) -> String? {
        titlesBySessionID[id]
    }

    func setTitle(_ title: String, for id: String) {
        titlesBySessionID[id] = title
    }

    func sessionExecutionState(for _: String) -> SessionExecutionState {
        .idle
    }
}
