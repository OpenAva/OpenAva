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

    func testHasActiveQueryReflectsCachedSessionQueryActivity() throws {
        let manager = ConversationSessionManager.shared
        manager.removeAllSessions()
        let storage = TestStorageProvider()
        let session = manager.session(
            for: "main",
            configuration: .init(storage: storage)
        )

        XCTAssertFalse(manager.hasActiveQuery())

        let reservationGeneration = try XCTUnwrap(session.queryGuard.reserve())
        XCTAssertTrue(manager.hasActiveQuery())
        XCTAssertTrue(manager.isQueryActive(session))
        XCTAssertTrue(manager.isQueryActive("main", storage: storage))

        let generation = try XCTUnwrap(session.queryGuard.tryStart(expectedGeneration: reservationGeneration))
        XCTAssertTrue(manager.hasActiveQuery())
        XCTAssertTrue(manager.isQueryActive(session))
        XCTAssertTrue(manager.isQueryActive("main", storage: storage))

        XCTAssertTrue(session.queryGuard.end(generation))
        XCTAssertFalse(manager.hasActiveQuery())
        XCTAssertFalse(manager.isQueryActive("main", storage: storage))
    }

    func testIsQueryActiveChecksSpecificSessionOnly() throws {
        let manager = ConversationSessionManager.shared
        manager.removeAllSessions()
        let storage = TestStorageProvider()
        let mainSession = manager.session(
            for: "main",
            configuration: .init(storage: storage)
        )
        _ = manager.session(
            for: "other",
            configuration: .init(storage: storage)
        )

        _ = try XCTUnwrap(mainSession.queryGuard.tryStart())

        XCTAssertTrue(manager.isQueryActive("main", storage: storage))
        XCTAssertFalse(manager.isQueryActive("other", storage: storage))

        mainSession.queryGuard.forceEnd()
        XCTAssertFalse(manager.isQueryActive("main", storage: storage))
    }

    func testExecutionTrackingSeparatesSameSessionIDAcrossDifferentStorageProviders() throws {
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

        let generationA = try XCTUnwrap(sessionA.queryGuard.tryStart())
        let generationB = try XCTUnwrap(sessionB.queryGuard.tryStart())

        XCTAssertTrue(manager.isQueryActive("main", storage: storageA))
        XCTAssertTrue(manager.isQueryActive("main", storage: storageB))
        XCTAssertTrue(manager.hasActiveQuery())

        XCTAssertTrue(sessionA.queryGuard.end(generationA))

        XCTAssertFalse(manager.isQueryActive("main", storage: storageA))
        XCTAssertTrue(manager.isQueryActive("main", storage: storageB))

        XCTAssertTrue(sessionB.queryGuard.end(generationB))
        XCTAssertFalse(manager.hasActiveQuery())
    }

    func testHasActiveQueryWithPrefixReflectsScopedSessions() throws {
        let manager = ConversationSessionManager.shared
        manager.removeAllSessions()
        let storage = TestStorageProvider()
        let mainSession = manager.session(
            for: "agent:123::main",
            configuration: .init(storage: storage)
        )
        let otherSession = manager.session(
            for: "agent:999::main",
            configuration: .init(storage: storage)
        )

        let mainGeneration = try XCTUnwrap(mainSession.queryGuard.tryStart())
        XCTAssertTrue(manager.hasActiveQuery(withPrefix: "agent:123::"))
        XCTAssertFalse(manager.hasActiveQuery(withPrefix: "agent:999::"))

        let otherGeneration = try XCTUnwrap(otherSession.queryGuard.tryStart())
        XCTAssertTrue(manager.hasActiveQuery(withPrefix: "agent:999::"))

        XCTAssertTrue(mainSession.queryGuard.end(mainGeneration))
        XCTAssertTrue(otherSession.queryGuard.end(otherGeneration))
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
