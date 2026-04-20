import ChatClient
import ChatUI
import Combine
import XCTest
@testable import OpenAva

@MainActor
final class QueryGuardTests: XCTestCase {
    func testCancelReservationIsNoOpAfterQueryStarts() throws {
        let queryGuard = QueryGuard()

        XCTAssertTrue(queryGuard.reserve())
        let generation = try XCTUnwrap(queryGuard.tryStart())

        queryGuard.cancelReservation()

        XCTAssertTrue(queryGuard.isActive)
        XCTAssertTrue(queryGuard.end(generation))
    }

    func testReserveAndCancelReservationToggleActivity() {
        let queryGuard = QueryGuard()

        XCTAssertFalse(queryGuard.isActive)
        XCTAssertTrue(queryGuard.reserve())
        XCTAssertTrue(queryGuard.isActive)

        queryGuard.cancelReservation()
        XCTAssertFalse(queryGuard.isActive)
    }

    func testTryStartAndEndToggleActivity() throws {
        let queryGuard = QueryGuard()

        XCTAssertFalse(queryGuard.isActive)

        let generation = try XCTUnwrap(queryGuard.tryStart())
        XCTAssertTrue(queryGuard.isActive)
        XCTAssertTrue(queryGuard.end(generation))
        XCTAssertFalse(queryGuard.isActive)
    }

    func testActivityPublisherEmitsStateTransitions() throws {
        let queryGuard = QueryGuard()
        var values: [Bool] = []
        let cancellable = queryGuard.activityDidChange.sink { values.append($0) }

        XCTAssertTrue(queryGuard.reserve())
        let generation = try XCTUnwrap(queryGuard.tryStart())
        XCTAssertTrue(queryGuard.end(generation))

        withExtendedLifetime(cancellable) {
            XCTAssertEqual(values, [false, true, true, false])
        }
    }

    func testForceEndInvalidatesOutstandingGeneration() throws {
        let queryGuard = QueryGuard()

        let firstGeneration = try XCTUnwrap(queryGuard.tryStart())
        queryGuard.forceEnd()

        XCTAssertFalse(queryGuard.isActive)
        XCTAssertFalse(queryGuard.end(firstGeneration))

        let secondGeneration = try XCTUnwrap(queryGuard.tryStart())
        XCTAssertNotEqual(firstGeneration, secondGeneration)
    }

    func testForceEndClearsReservationAndAllowsFreshStart() throws {
        let queryGuard = QueryGuard()

        XCTAssertTrue(queryGuard.reserve())
        queryGuard.forceEnd()

        XCTAssertFalse(queryGuard.isActive)
        let generation = try XCTUnwrap(queryGuard.tryStart())
        XCTAssertTrue(queryGuard.end(generation))
    }

    func testInterruptCurrentTurnForceEndsReservedSubmissionWithoutTask() async {
        let session = ConversationSession(
            id: "main",
            configuration: .init(storage: InMemoryTestStorageProvider())
        )
        let model = ConversationSession.Model(
            client: BlockingStreamingChatClient(),
            capabilities: [],
            contextLength: 32000,
            autoCompactEnabled: true
        )
        XCTAssertTrue(session.queryGuard.reserve())

        session.interruptCurrentTurn(reason: .userStop)

        XCTAssertFalse(session.isQueryActive)
        let accepted = session.submitPromptWithoutWaiting(
            model: model,
            prompt: .init(text: "should start")
        )
        XCTAssertTrue(accepted)

        for _ in 0 ..< 200 {
            if session.currentTask != nil {
                break
            }
            await Task.yield()
        }

        XCTAssertNotNil(session.currentTask)
        session.interruptCurrentTurn(reason: .userStop)

        for _ in 0 ..< 200 {
            if session.currentTask == nil {
                break
            }
            await Task.yield()
        }

        XCTAssertNil(session.currentTask)
        XCTAssertFalse(session.isQueryActive)
    }

    func testInterruptCurrentTurnClearsCurrentTaskAfterCancellation() async {
        let session = ConversationSession(
            id: "main",
            configuration: .init(storage: InMemoryTestStorageProvider())
        )
        let client = BlockingStreamingChatClient()
        let model = ConversationSession.Model(
            client: client,
            capabilities: [],
            contextLength: 32000,
            autoCompactEnabled: true
        )

        let accepted = session.submitPromptWithoutWaiting(model: model, prompt: .init(text: "please interrupt"))
        XCTAssertTrue(accepted)

        for _ in 0 ..< 200 {
            if session.currentTask != nil {
                break
            }
            await Task.yield()
        }

        XCTAssertNotNil(session.currentTask)
        XCTAssertTrue(session.isQueryActive)

        session.interruptCurrentTurn(reason: .userStop)

        for _ in 0 ..< 200 {
            if session.currentTask == nil {
                break
            }
            await Task.yield()
        }

        for _ in 0 ..< 200 {
            if !session.isQueryActive, session.showsInterruptedRetryAction {
                break
            }
            await Task.yield()
        }

        XCTAssertNil(session.currentTask)
        XCTAssertFalse(session.isQueryActive)
        XCTAssertTrue(session.showsInterruptedRetryAction)
    }
}

private final class InMemoryTestStorageProvider: StorageProvider {
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

private final class BlockingStreamingChatClient: ChatClient, @unchecked Sendable {
    let errorCollector = ErrorCollector.new()

    func chat(body _: ChatRequestBody) async throws -> ChatResponse {
        ChatResponse(reasoning: "", text: "", images: [], tools: [])
    }

    func streamingChat(body _: ChatRequestBody) async throws -> AnyAsyncSequence<ChatResponseChunk> {
        BlockingStreamingSequence().eraseToAnyAsyncSequence()
    }
}

private struct BlockingStreamingSequence: AsyncSequence {
    typealias Element = ChatResponseChunk

    struct AsyncIterator: AsyncIteratorProtocol {
        private var didEmitInitialChunk = false

        mutating func next() async throws -> ChatResponseChunk? {
            if !didEmitInitialChunk {
                didEmitInitialChunk = true
                return .text("working")
            }

            while true {
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: 10_000_000)
            }
        }
    }

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator()
    }
}
