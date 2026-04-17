import ChatUI
import XCTest
@testable import OpenAva

@MainActor
final class ConversationSessionUserInputTests: XCTestCase {
    func testUserInputStoresTranscriptMetadataForDisplayTextOverride() {
        let input = ConversationSession.UserInput(
            text: "internal request",
            displayText: "visible message",
            source: .heartbeat,
            metadata: [HeartbeatSupport.metadataModeKey: HeartbeatSupport.metadataModeScheduledValue]
        )

        XCTAssertEqual(input.transcriptText, "visible message")
        XCTAssertEqual(input.transcriptMetadata[ConversationSession.UserInput.sourceMetadataKey], "heartbeat")
        XCTAssertEqual(
            input.transcriptMetadata[ConversationSession.UserInput.requestTextMetadataKey],
            "internal request"
        )
    }

    func testUserRequestTextFallsBackToStoredRequestMetadata() {
        let session = ConversationSession(
            id: "main",
            configuration: .init(storage: InMemoryStorageProvider())
        )
        let message = ConversationMessage(sessionID: "main", role: .user)
        message.textContent = "visible message"
        message.metadata[ConversationSession.UserInput.requestTextMetadataKey] = "internal request"

        XCTAssertEqual(session.userRequestText(for: message), "internal request")
    }

    func testUserRequestTextFallsBackToTranscriptTextWhenMetadataMissing() {
        let session = ConversationSession(
            id: "main",
            configuration: .init(storage: InMemoryStorageProvider())
        )
        let message = ConversationMessage(sessionID: "main", role: .user)
        message.textContent = "visible message"

        XCTAssertEqual(session.userRequestText(for: message), "visible message")
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
}
