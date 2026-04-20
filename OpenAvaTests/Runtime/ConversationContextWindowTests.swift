import ChatClient
import ChatUI
import XCTest
@testable import OpenAva

@MainActor
final class ConversationContextWindowTests: XCTestCase {
    func testContextUsageSnapshotReportsCompactThresholds() async {
        let session = ConversationSession(
            id: "context-usage",
            configuration: .init(storage: InMemoryContextStorageProvider())
        )
        seedConversation(into: session)

        let model = ConversationSession.Model(
            client: NoopChatClient(),
            capabilities: [],
            contextLength: 32000,
            maxOutputTokens: 8000,
            autoCompactEnabled: true
        )

        let snapshot = await session.contextUsageSnapshot(for: model)

        XCTAssertEqual(snapshot.rawContextWindowTokens, 32000)
        XCTAssertEqual(snapshot.contextWindowTokens, 24000)
        XCTAssertEqual(snapshot.compactOutputReserveTokens, 8000)
        XCTAssertEqual(snapshot.autoCompactTriggerTokens, 11000)
        XCTAssertEqual(snapshot.blockingLimitTokens, 21000)
        XCTAssertTrue(snapshot.isAutoCompactEnabled)
        XCTAssertFalse(snapshot.isAboveAutoCompactThreshold)
        XCTAssertFalse(snapshot.isAtBlockingLimit)

        let messagesCategory = snapshot.categories.first { $0.kind == .messages }
        XCTAssertEqual(messagesCategory?.messageBreakdown?.userMessageCount, 1)
        XCTAssertEqual(messagesCategory?.messageBreakdown?.assistantMessageCount, 1)
        XCTAssertEqual(messagesCategory?.messageBreakdown?.toolMessageCount, 0)

        let autoCompactBufferCategory = snapshot.categories.first { $0.kind == .autoCompactBuffer }
        XCTAssertEqual(autoCompactBufferCategory?.tokens, 13000)

        let freeSpaceCategory = snapshot.categories.first { $0.kind == .freeSpace }
        XCTAssertNotNil(freeSpaceCategory)
    }

    func testEnsureBelowBlockingLimitThrowsWithoutAutoCompact() async throws {
        let session = ConversationSession(
            id: "manual-limit",
            configuration: .init(storage: InMemoryContextStorageProvider())
        )
        let requestMessages = [
            ChatRequestBody.Message.user(
                content: .text(String(repeating: "abcd ", count: 80))
            ),
        ]
        let model = ConversationSession.Model(
            client: NoopChatClient(),
            capabilities: [],
            contextLength: 100,
            autoCompactEnabled: false
        )

        do {
            try await session.ensureBelowBlockingLimit(
                requestMessages: requestMessages,
                tools: nil,
                model: model
            )
            XCTFail("Expected blocking limit to block oversized request")
        } catch let error as QueryExecutionError {
            guard case let .contextWindowExceeded(message) = error else {
                return XCTFail("Unexpected query execution error: \(error)")
            }
            XCTAssertTrue(message.contains("Conversation too long"))
        }
    }

    func testEnsureBelowBlockingLimitSkipsBlockingWhenAutoCompactEnabled() async throws {
        let session = ConversationSession(
            id: "auto-compact-limit",
            configuration: .init(storage: InMemoryContextStorageProvider())
        )
        let requestMessages = [
            ChatRequestBody.Message.user(
                content: .text(String(repeating: "abcd ", count: 80))
            ),
        ]
        let model = ConversationSession.Model(
            client: NoopChatClient(),
            capabilities: [],
            contextLength: 100,
            autoCompactEnabled: true
        )

        try await session.ensureBelowBlockingLimit(
            requestMessages: requestMessages,
            tools: nil,
            model: model
        )
    }

    func testPromptTooLongTokenParsingAndGapMatchClaudeStyleHelpers() {
        let rawMessage = "prompt is too long: 137500 tokens > 135000 maximum"
        let counts = parsePromptTooLongTokenCounts(from: rawMessage)

        XCTAssertEqual(counts.actualTokens, 137_500)
        XCTAssertEqual(counts.limitTokens, 135_000)

        struct PromptTooLongError: LocalizedError {
            let rawMessage: String
            var errorDescription: String? {
                rawMessage
            }
        }

        let gap = getPromptTooLongTokenGap(from: PromptTooLongError(rawMessage: rawMessage))
        XCTAssertEqual(gap, 2500)
    }

    func testAutoCompactCircuitBreakerStopsAfterThreeFailures() async {
        let session = ConversationSession(
            id: "auto-compact-circuit-breaker",
            configuration: .init(storage: InMemoryContextStorageProvider())
        )
        seedLongConversation(into: session, messageCount: 8)

        let client = FailingCompactChatClient(message: "PROMPT TOO LONG")
        let model = ConversationSession.Model(
            client: client,
            capabilities: [],
            contextLength: 100,
            autoCompactEnabled: true
        )
        let baseRequestMessages = [
            ChatRequestBody.Message.user(
                content: .text(String(repeating: "abcd ", count: 120))
            ),
        ]
        var tracking: AutoCompactTrackingState?

        for _ in 0 ..< 4 {
            var requestMessages = baseRequestMessages
            let result = await session.autoCompactIfNeeded(
                &requestMessages,
                tools: nil,
                model: model,
                tracking: tracking
            )
            await applyAutoCompactResultForTest(
                result,
                session: session,
                model: model,
                requestMessages: &requestMessages,
                tracking: &tracking
            )
        }

        XCTAssertEqual(client.chatCallCount, 12)
        XCTAssertEqual(session.autoCompactTrackingState.consecutiveFailures, 3)
    }

    func testContextUsageSnapshotReportsDetailSectionsAndTools() async {
        let session = ConversationSession(
            id: "context-usage-details",
            configuration: .init(
                storage: InMemoryContextStorageProvider(),
                tools: StaticToolProvider(),
                systemPromptProvider: {
                    """
                    You are a focused assistant.

                    ## Custom Instructions
                    Keep answers concise.

                    ## Runtime
                    App=OpenAva
                    """
                }
            )
        )
        seedConversation(into: session)

        let model = ConversationSession.Model(
            client: NoopChatClient(),
            capabilities: [.tool],
            contextLength: 32000,
            maxOutputTokens: 8000,
            autoCompactEnabled: true
        )

        let snapshot = await session.contextUsageSnapshot(for: model)

        XCTAssertTrue(snapshot.systemPromptSections.contains { $0.name == "Custom Instructions" })
        XCTAssertTrue(snapshot.systemPromptSections.contains { $0.name == "Runtime" })
        XCTAssertEqual(snapshot.systemTools.map(\.name), ["read_file"])
        XCTAssertEqual(snapshot.categories.first { $0.kind == .tools }?.entryCount, 1)
        XCTAssertNotNil(snapshot.messageBreakdown)
        XCTAssertGreaterThan(snapshot.messageBreakdown?.userMessageTokens ?? 0, 0)
        XCTAssertGreaterThan(snapshot.messageBreakdown?.assistantMessageTokens ?? 0, 0)
    }

    func testExplicitMaxOutputTokensDrivesEffectiveContextWindow() {
        let session = ConversationSession(
            id: "explicit-max-output",
            configuration: .init(storage: InMemoryContextStorageProvider())
        )

        let model = ConversationSession.Model(
            client: NoopChatClient(),
            capabilities: [],
            contextLength: 48000,
            maxOutputTokens: 12000,
            autoCompactEnabled: true
        )

        XCTAssertEqual(session.getReservedTokensForSummary(for: model), 12000)
        XCTAssertEqual(session.getEffectiveContextWindowSize(for: model), 36000)
        XCTAssertEqual(session.getAutoCompactThreshold(for: model), 23000)
        XCTAssertEqual(session.getBlockingLimit(for: model), 33000)
    }

    func testShouldAutoCompactSkipsCompactQuerySource() async {
        let session = ConversationSession(
            id: "compact-query-source-guard",
            configuration: .init(storage: InMemoryContextStorageProvider())
        )
        let requestMessages = [
            ChatRequestBody.Message.user(
                content: .text(String(repeating: "abcd ", count: 120))
            ),
        ]
        let model = ConversationSession.Model(
            client: NoopChatClient(),
            capabilities: [],
            contextLength: 100,
            autoCompactEnabled: true
        )

        let shouldCompact = await session.shouldAutoCompact(
            requestMessages: requestMessages,
            tools: nil,
            model: model,
            querySource: .compact
        )

        XCTAssertFalse(shouldCompact)
    }

    func testAutoCompactTracksRecompactionChainAndContinuationSummary() async throws {
        let session = ConversationSession(
            id: "auto-compact-recompaction-chain",
            configuration: .init(storage: InMemoryContextStorageProvider())
        )
        seedLongConversation(into: session, messageCount: 8)

        let client = ScriptedCompactChatClient(
            responses: [
                "<summary>First auto compact summary.</summary>",
                "<summary>Second auto compact summary.</summary>",
            ]
        )
        let model = ConversationSession.Model(
            client: client,
            capabilities: [],
            contextLength: 100,
            autoCompactEnabled: true
        )
        var tracking: AutoCompactTrackingState?

        var firstRequestMessages = [
            ChatRequestBody.Message.user(
                content: .text(String(repeating: "abcd ", count: 120))
            ),
        ]
        let firstCompacted = await session.autoCompactIfNeeded(
            &firstRequestMessages,
            tools: nil,
            model: model,
            tracking: tracking,
            querySource: .user
        )
        await applyAutoCompactResultForTest(
            firstCompacted,
            session: session,
            model: model,
            requestMessages: &firstRequestMessages,
            tracking: &tracking
        )

        XCTAssertTrue(firstCompacted.wasCompacted)
        XCTAssertTrue(session.autoCompactTrackingState.compacted)
        XCTAssertEqual(session.autoCompactTrackingState.turnCounter, 0)
        XCTAssertEqual(session.autoCompactTrackingState.consecutiveFailures, 0)

        let firstTurnId = session.autoCompactTrackingState.turnId
        XCTAssertFalse(firstTurnId.isEmpty)

        let firstSummary = try XCTUnwrap(session.messages.first(where: { $0.isCompactSummary }))
        XCTAssertTrue(firstSummary.textContent.contains("Continue the conversation from where it left off without asking the user any further questions."))

        markAutoCompactTurnCompletedForTest(&tracking, session: session)
        XCTAssertEqual(session.autoCompactTrackingState.turnCounter, 1)

        seedLongConversation(into: session, messageCount: 8, startIndex: 8)

        var secondRequestMessages = [
            ChatRequestBody.Message.user(
                content: .text(String(repeating: "abcd ", count: 120))
            ),
        ]
        let secondCompacted = await session.autoCompactIfNeeded(
            &secondRequestMessages,
            tools: nil,
            model: model,
            tracking: tracking,
            querySource: .heartbeat
        )
        await applyAutoCompactResultForTest(
            secondCompacted,
            session: session,
            model: model,
            requestMessages: &secondRequestMessages,
            tracking: &tracking
        )

        XCTAssertTrue(secondCompacted.wasCompacted)

        let latestBoundary = try XCTUnwrap(session.messages.last(where: { $0.isCompactBoundary }))
        let metadata = try XCTUnwrap(latestBoundary.compactBoundaryMetadata)
        XCTAssertEqual(metadata.autoCompactThreshold, session.getAutoCompactThreshold(for: model))
        XCTAssertEqual(metadata.querySource, QuerySource.heartbeat.rawValue)
        XCTAssertEqual(metadata.isRecompactionInChain, true)
        XCTAssertEqual(metadata.turnsSincePreviousCompact, 1)
        XCTAssertEqual(metadata.previousCompactTurnId, firstTurnId)
    }

    func testReactiveCompactDoesNotContinueRecompactionChain() async throws {
        let session = ConversationSession(
            id: "reactive-compact-resets-tracking",
            configuration: .init(storage: InMemoryContextStorageProvider())
        )
        seedLongConversation(into: session, messageCount: 8)

        let client = PromptTooLongThenStopChatClient(
            compactResponses: [
                "<summary>Proactive auto compact summary.</summary>",
                "<summary>Reactive compact summary.</summary>",
            ]
        )
        let model = ConversationSession.Model(
            client: client,
            capabilities: [],
            contextLength: 100,
            autoCompactEnabled: true
        )

        await session.submitPrompt(
            model: model,
            prompt: .init(text: String(repeating: "abcd ", count: 120))
        )

        XCTAssertEqual(client.streamingChatCallCount, 1)
        XCTAssertTrue(session.autoCompactTrackingState.compacted)
        XCTAssertEqual(session.autoCompactTrackingState.turnCounter, 0)
        XCTAssertFalse(session.autoCompactTrackingState.turnId.isEmpty)

        let boundaries = session.messages.filter(\.isCompactBoundary)
        XCTAssertEqual(boundaries.count, 1)

        let onlyBoundary = try XCTUnwrap(boundaries.last)
        let metadata = try XCTUnwrap(onlyBoundary.compactBoundaryMetadata)
        XCTAssertEqual(metadata.querySource, QuerySource.user.rawValue)
        XCTAssertEqual(metadata.isRecompactionInChain, false)
        XCTAssertEqual(metadata.turnsSincePreviousCompact, -1)
        XCTAssertNil(metadata.previousCompactTurnId)

        let lastAssistant = try XCTUnwrap(session.messages.last)
        XCTAssertTrue(lastAssistant.textContent.contains("Prompt too long"))
    }

    private func applyAutoCompactResultForTest(
        _ autoCompactResult: AutoCompactResult,
        session: ConversationSession,
        model: ConversationSession.Model,
        requestMessages: inout [ChatRequestBody.Message],
        tracking: inout AutoCompactTrackingState?
    ) async {
        if let compactionResult = autoCompactResult.compactionResult {
            session.applyCompactionResult(compactionResult)
            tracking = AutoCompactTrackingState(
                compacted: true,
                turnCounter: 0,
                turnId: UUID().uuidString,
                consecutiveFailures: 0
            )
            session.autoCompactTrackingState = tracking ?? AutoCompactTrackingState()
            requestMessages = await session.buildMessages(capabilities: model.capabilities)
        } else if let consecutiveFailures = autoCompactResult.consecutiveFailures {
            var updatedTracking = tracking ?? AutoCompactTrackingState()
            updatedTracking.consecutiveFailures = consecutiveFailures
            tracking = updatedTracking
            session.autoCompactTrackingState = updatedTracking
        }
    }

    private func markAutoCompactTurnCompletedForTest(
        _ tracking: inout AutoCompactTrackingState?,
        session: ConversationSession
    ) {
        guard var updatedTracking = tracking, updatedTracking.compacted else { return }
        updatedTracking.turnCounter += 1
        tracking = updatedTracking
        session.autoCompactTrackingState = updatedTracking
    }

    private func seedConversation(into session: ConversationSession) {
        let user = session.appendNewMessage(role: .user)
        user.textContent = "Refactor the compaction path to match Claude Code."

        let assistant = session.appendNewMessage(role: .assistant)
        assistant.textContent = "I’ll align the context window and auto-compact behavior."
    }

    private func seedLongConversation(into session: ConversationSession, messageCount: Int, startIndex: Int = 0) {
        for index in 0 ..< messageCount {
            let absoluteIndex = startIndex + index
            let role: MessageRole = absoluteIndex.isMultiple(of: 2) ? .user : .assistant
            let message = session.appendNewMessage(role: role)
            message.textContent = "message-\(absoluteIndex)"
            message.createdAt = Date(timeIntervalSince1970: TimeInterval(absoluteIndex))
        }
        session.persistMessages()
    }
}

private final class InMemoryContextStorageProvider: StorageProvider {
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

private struct StaticToolExecutor: ToolExecutor {
    let displayName = "Read File"
}

private final class StaticToolProvider: ToolProvider {
    func enabledTools() async -> [ChatRequestBody.Tool] {
        [
            .function(
                name: "read_file",
                description: "Read a file from disk.",
                parameters: nil,
                strict: nil
            ),
        ]
    }

    func findTool(for _: ToolRequest) async -> ToolExecutor? {
        StaticToolExecutor()
    }

    func executeTool(_: ToolExecutor, parameters _: String) async throws -> ToolResult {
        ToolResult(text: "")
    }
}

private final class NoopChatClient: ChatClient, @unchecked Sendable {
    let errorCollector = ErrorCollector.new()

    func chat(body _: ChatRequestBody) async throws -> ChatResponse {
        ChatResponse(reasoning: "", text: "", images: [], tools: [])
    }

    func streamingChat(body _: ChatRequestBody) async throws -> AnyAsyncSequence<ChatResponseChunk> {
        AsyncStream<ChatResponseChunk> { continuation in
            continuation.finish()
        }.eraseToAnyAsyncSequence()
    }
}

private final class FailingCompactChatClient: ChatClient, @unchecked Sendable {
    let errorCollector = ErrorCollector.new()

    private let message: String
    private(set) var chatCallCount = 0

    init(message: String) {
        self.message = message
    }

    func chat(body _: ChatRequestBody) async throws -> ChatResponse {
        chatCallCount += 1
        await errorCollector.collect(message)
        struct CompactFailure: LocalizedError {
            let message: String
            var errorDescription: String? {
                message
            }
        }
        throw CompactFailure(message: message)
    }

    func streamingChat(body _: ChatRequestBody) async throws -> AnyAsyncSequence<ChatResponseChunk> {
        AsyncStream<ChatResponseChunk> { continuation in
            continuation.finish()
        }.eraseToAnyAsyncSequence()
    }
}

private final class ScriptedCompactChatClient: ChatClient, @unchecked Sendable {
    let errorCollector = ErrorCollector.new()

    private let lock = NSLock()
    private var responses: [String]

    init(responses: [String]) {
        self.responses = responses
    }

    func chat(body _: ChatRequestBody) async throws -> ChatResponse {
        lock.lock()
        let response = responses.isEmpty ? "<summary>fallback</summary>" : responses.removeFirst()
        lock.unlock()
        return ChatResponse(reasoning: "", text: response, images: [], tools: [])
    }

    func streamingChat(body _: ChatRequestBody) async throws -> AnyAsyncSequence<ChatResponseChunk> {
        AsyncStream<ChatResponseChunk> { continuation in
            continuation.finish()
        }.eraseToAnyAsyncSequence()
    }
}

private final class PromptTooLongThenStopChatClient: ChatClient, @unchecked Sendable {
    let errorCollector = ErrorCollector.new()

    private let lock = NSLock()
    private var compactResponses: [String]
    private(set) var streamingChatCallCount = 0

    init(compactResponses: [String]) {
        self.compactResponses = compactResponses
    }

    func chat(body _: ChatRequestBody) async throws -> ChatResponse {
        lock.lock()
        let response = compactResponses.isEmpty ? "<summary>fallback</summary>" : compactResponses.removeFirst()
        lock.unlock()
        return ChatResponse(reasoning: "", text: response, images: [], tools: [])
    }

    func streamingChat(body _: ChatRequestBody) async throws -> AnyAsyncSequence<ChatResponseChunk> {
        lock.lock()
        streamingChatCallCount += 1
        let callCount = streamingChatCallCount
        lock.unlock()

        if callCount == 1 {
            struct PromptTooLongFailure: LocalizedError {
                var errorDescription: String? {
                    "Prompt too long"
                }
            }
            throw PromptTooLongFailure()
        }

        return AsyncStream<ChatResponseChunk> { continuation in
            continuation.yield(.text("Recovered after reactive compact."))
            continuation.finish()
        }.eraseToAnyAsyncSequence()
    }
}
