import ChatClient
import ChatUI
import XCTest
@testable import OpenAva

@MainActor
final class ConversationSessionUserInputTests: XCTestCase {
    func testUserInputStoresSourceMetadata() {
        let input = ConversationSession.UserInput(
            text: "internal request",
            source: .heartbeat,
            metadata: [HeartbeatSupport.metadataModeKey: HeartbeatSupport.metadataModeScheduledValue]
        )

        XCTAssertEqual(input.metadata[ConversationSession.UserInput.sourceMetadataKey], "heartbeat")
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
