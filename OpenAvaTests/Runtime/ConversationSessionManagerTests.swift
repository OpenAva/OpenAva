import ChatUI
import XCTest
@testable import OpenAva

@MainActor
final class ConversationSessionManagerTests: XCTestCase {
    override func tearDown() {
        ConversationSessionManager.shared.removeAllSessions()
        super.tearDown()
    }

    func testSessionCacheSeparatesSameSessionIDByStorageProvider() {
        let manager = ConversationSessionManager.shared
        manager.removeAllSessions()

        let storageA = TestStorageProvider()
        let storageB = TestStorageProvider()

        let sessionA = manager.session(
            for: "main",
            configuration: .init(storage: storageA)
        )
        let sessionB = manager.session(
            for: "main",
            configuration: .init(storage: storageB)
        )

        XCTAssertFalse(sessionA === sessionB)
    }

    func testSessionCacheReusesSessionForSameStorageProvider() {
        let manager = ConversationSessionManager.shared
        manager.removeAllSessions()

        let storage = TestStorageProvider()
        let first = manager.session(
            for: "main",
            configuration: .init(storage: storage)
        )
        let second = manager.session(
            for: "main",
            configuration: .init(storage: storage)
        )

        XCTAssertTrue(first === second)
    }

    func testExecutionTrackingUsesReferenceCountForSameSessionID() {
        let manager = ConversationSessionManager.shared
        manager.removeAllSessions()
        let storage = TestStorageProvider()

        manager.markSessionExecuting("main", storage: storage)
        manager.markSessionExecuting("main", storage: storage)
        XCTAssertTrue(manager.hasExecutingSession())

        manager.markSessionCompleted("main", storage: storage)
        XCTAssertTrue(manager.hasExecutingSession())

        manager.markSessionCompleted("main", storage: storage)
        XCTAssertFalse(manager.hasExecutingSession())
    }

    func testIsSessionExecutingChecksSpecificSessionOnly() {
        let manager = ConversationSessionManager.shared
        manager.removeAllSessions()
        let storage = TestStorageProvider()

        manager.markSessionExecuting("main", storage: storage)

        XCTAssertTrue(manager.isSessionExecuting("main", storage: storage))
        XCTAssertFalse(manager.isSessionExecuting("other", storage: storage))

        manager.markSessionCompleted("main", storage: storage)
        XCTAssertFalse(manager.isSessionExecuting("main", storage: storage))
    }

    func testExecutionTrackingSeparatesSameSessionIDAcrossDifferentStorageProviders() {
        let manager = ConversationSessionManager.shared
        manager.removeAllSessions()
        let storageA = TestStorageProvider()
        let storageB = TestStorageProvider()

        manager.markSessionExecuting("main", storage: storageA)
        manager.markSessionExecuting("main", storage: storageB)

        XCTAssertTrue(manager.isSessionExecuting("main", storage: storageA))
        XCTAssertTrue(manager.isSessionExecuting("main", storage: storageB))

        manager.markSessionCompleted("main", storage: storageA)

        XCTAssertFalse(manager.isSessionExecuting("main", storage: storageA))
        XCTAssertTrue(manager.isSessionExecuting("main", storage: storageB))
    }
}

private final class TestStorageProvider: StorageProvider {
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
