import ChatClient
import ChatUI
import Combine
import XCTest
@testable import OpenAva

@MainActor
final class QueryGuardTests: XCTestCase {
    func testCancelReservationIsNoOpAfterQueryStarts() throws {
        let queryGuard = QueryGuard()

        let reservationGeneration = try XCTUnwrap(queryGuard.reserve())
        let generation = try XCTUnwrap(queryGuard.tryStart(expectedGeneration: reservationGeneration))

        queryGuard.cancelReservation()

        XCTAssertTrue(queryGuard.isActive)
        XCTAssertTrue(queryGuard.end(generation))
    }

    func testReserveAndCancelReservationToggleActivity() throws {
        let queryGuard = QueryGuard()

        XCTAssertFalse(queryGuard.isActive)
        XCTAssertEqual(try XCTUnwrap(queryGuard.reserve()), 0)
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

        XCTAssertNotNil(queryGuard.reserve())
        let generation = try XCTUnwrap(queryGuard.tryStart(expectedGeneration: 0))
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

    func testTryStartFailsForStaleReservationAfterForceEnd() throws {
        let queryGuard = QueryGuard()

        let reservationGeneration = try XCTUnwrap(queryGuard.reserve())
        queryGuard.forceEnd()

        XCTAssertNil(queryGuard.tryStart(expectedGeneration: reservationGeneration))
        XCTAssertFalse(queryGuard.isActive)
    }

    func testInterruptCurrentTurnForceEndsReservedSubmissionWithoutTask() async throws {
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
        let reservationGeneration = try XCTUnwrap(session.queryGuard.reserve())

        session.interruptCurrentTurn(reason: .userStop)

        XCTAssertFalse(session.isQueryActive)
        let accepted = await session.submitPrompt(
            model: model,
            prompt: .init(text: "should not start"),
            reservationGeneration: reservationGeneration
        )
        XCTAssertFalse(accepted)
        XCTAssertNil(session.currentTask)
        XCTAssertNil(session.currentTaskGeneration)
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

        let submitTask = Task {
            await session.submitPrompt(model: model, prompt: .init(text: "please interrupt"))
        }

        for _ in 0 ..< 200 {
            if session.currentTask != nil {
                break
            }
            await Task.yield()
        }

        XCTAssertNotNil(session.currentTask)
        XCTAssertEqual(session.currentTaskGeneration, 1)
        XCTAssertTrue(session.isQueryActive)

        session.interruptCurrentTurn(reason: .userStop)
        await submitTask.value

        XCTAssertNil(session.currentTask)
        XCTAssertNil(session.currentTaskGeneration)
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
