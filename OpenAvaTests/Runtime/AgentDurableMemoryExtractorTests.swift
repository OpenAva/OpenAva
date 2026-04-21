import ChatClient
import ChatUI
import XCTest
@testable import OpenAva

final class AgentDurableMemoryExtractorTests: XCTestCase {
    func testSessionDelegateCanDisableAutomaticDurableMemoryExtraction() async throws {
        try resetSharedMemoryRoot()
        let runtimeRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: runtimeRoot, withIntermediateDirectories: true)
        defer {
            TranscriptStorageProvider.removeProvider(runtimeRootURL: runtimeRoot)
            try? FileManager.default.removeItem(at: runtimeRoot)
        }

        let chatClient = StubChatClient(
            responseText: #"{"memories":[{"name":"User prefers terse answers","type":"feedback","description":"Response brevity preference","content":"Prefer concise answers with no trailing summaries.","slug":"response-style"}]}"#
        )
        let delegate = AgentSessionDelegate(
            sessionID: "session-1",
            runtimeRootURL: runtimeRoot,
            chatClient: chatClient,
            agentName: "Test Agent",
            agentEmoji: "",
            shouldExtractDurableMemory: false
        )
        let store = AgentMemoryStore(runtimeRootURL: AgentStore.sharedRuntimeRootURL())

        await delegate.sessionDidPersistMessages(makeConversation(sessionID: "session-1"), for: "session-1")

        let entries = try await store.listEntries()
        XCTAssertTrue(entries.isEmpty)
        XCTAssertEqual(chatClient.chatCallCount, 0)
        XCTAssertEqual(chatClient.streamingChatCallCount, 0)
    }

    func testExtractorWritesDurableMemoryAndAdvancesCursor() async throws {
        try resetSharedMemoryRoot()
        let runtimeRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: runtimeRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: runtimeRoot) }

        let responseJSON = #"{"memories":[{"name":"User prefers terse answers","type":"feedback","description":"Response brevity preference","content":"Prefer concise answers with no trailing summaries.","slug":"response-style"}]}"#
        let chatClient = StubChatClient(responseText: responseJSON)
        let extractor = AgentDurableMemoryExtractor(runtimeRootURL: runtimeRoot, chatClient: chatClient)
        let store = AgentMemoryStore(runtimeRootURL: AgentStore.sharedRuntimeRootURL())

        let messages = makeConversation(sessionID: "session-1")
        await extractor.extractIfNeeded(for: "session-1", messages: messages)
        await extractor.extractIfNeeded(for: "session-1", messages: messages)

        let entries = try await store.listEntries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.slug, "response-style")
        XCTAssertEqual(entries.first?.type, .feedback)
        XCTAssertEqual(chatClient.chatCallCount, 1)
        XCTAssertEqual(chatClient.streamingChatCallCount, 0)
    }

    func testExtractorSkipsExtractionWhenCursorWasCompactedAway() async throws {
        try resetSharedMemoryRoot()
        let runtimeRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: runtimeRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: runtimeRoot) }

        let chatClient = StubChatClient(responseText: #"{"memories":[]}"#)
        let extractor = AgentDurableMemoryExtractor(runtimeRootURL: runtimeRoot, chatClient: chatClient)
        let sessionID = "session-1"

        let cursorDirectory = runtimeRoot
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(sessionID, isDirectory: true)
        try FileManager.default.createDirectory(at: cursorDirectory, withIntermediateDirectories: true)
        try #"{"lastProcessedMessageID":"removed-message"}"#.write(
            to: cursorDirectory.appendingPathComponent("durable-memory-extraction-cursor.json", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )

        let keptUser = ConversationMessage(sessionID: sessionID, role: .user)
        keptUser.textContent = "记住我偏好简洁回复。"

        let keptAssistant = ConversationMessage(sessionID: sessionID, role: .assistant)
        keptAssistant.textContent = "好的，我会保持简洁。"

        let summary = ConversationMessage(sessionID: sessionID, role: .user)
        summary.textContent = "Earlier conversation summary."
        summary.metadata["isCompactSummary"] = "true"

        let boundary = ConversationMessage(sessionID: sessionID, role: .system)
        boundary.textContent = "Conversation compacted."
        boundary.subtype = "compact_boundary"

        await extractor.extractIfNeeded(for: sessionID, messages: [boundary, summary, keptUser, keptAssistant])

        XCTAssertEqual(chatClient.chatCallCount, 0)
        XCTAssertEqual(chatClient.streamingChatCallCount, 0)
    }

    func testExtractorIgnoresNonJSONWrappedResponse() async throws {
        try resetSharedMemoryRoot()
        let runtimeRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: runtimeRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: runtimeRoot) }

        let responseText = #"""
        I found one durable memory.
        ```json
        {"memories":[{"name":"User prefers Chinese","type":"user","description":"Preferred response language","content":"Always reply in simplified Chinese unless asked otherwise.","slug":"language-preference"}]}
        ```
        """#
        let chatClient = StubChatClient(responseText: responseText)
        let extractor = AgentDurableMemoryExtractor(runtimeRootURL: runtimeRoot, chatClient: chatClient)
        let store = AgentMemoryStore(runtimeRootURL: AgentStore.sharedRuntimeRootURL())

        await extractor.extractIfNeeded(for: "session-1", messages: makeConversation(sessionID: "session-1"))

        let entries = try await store.listEntries()
        XCTAssertTrue(entries.isEmpty)
        XCTAssertEqual(chatClient.chatCallCount, 1)
        XCTAssertEqual(chatClient.streamingChatCallCount, 0)
    }

    func testExtractorDoesNotReuseExistingTopicSlugWhenResponseOmitsSlug() async throws {
        try resetSharedMemoryRoot()
        let runtimeRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: runtimeRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: runtimeRoot) }

        let store = AgentMemoryStore(runtimeRootURL: AgentStore.sharedRuntimeRootURL())
        let existing = try await store.upsert(
            name: "Response style",
            type: .feedback,
            description: "Response brevity preference",
            content: "Prefer concise answers.",
            slug: "response-style"
        )
        let responseJSON = #"{"memories":[{"name":"User likes shorter responses","type":"feedback","description":"Response brevity preference","content":"Prefer concise answers and avoid wrap-up summaries."}]}"#
        let chatClient = StubChatClient(responseText: responseJSON)
        let extractor = AgentDurableMemoryExtractor(runtimeRootURL: runtimeRoot, chatClient: chatClient)

        await extractor.extractIfNeeded(for: "session-1", messages: makeConversation(sessionID: "session-1"))

        let entries = try await store.listEntries()
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.map(\.slug).sorted(), ["user-likes-shorter-responses", existing.slug].sorted())

        let newEntry = try XCTUnwrap(entries.first(where: { $0.slug == "user-likes-shorter-responses" }))
        XCTAssertEqual(newEntry.version, 1)
        XCTAssertTrue(newEntry.content.contains("wrap-up summaries"))

        let archivedVersionURL = AgentStore.sharedRuntimeRootURL()
            .appendingPathComponent("memory", isDirectory: true)
            .appendingPathComponent(".versions", isDirectory: true)
            .appendingPathComponent(existing.slug, isDirectory: true)
            .appendingPathComponent("v1.md", isDirectory: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: archivedVersionURL.path))
    }

    func testExtractorDoesNotInferConflictsWhenResponseOmitsConflicts() async throws {
        try resetSharedMemoryRoot()
        let runtimeRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: runtimeRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: runtimeRoot) }

        let store = AgentMemoryStore(runtimeRootURL: AgentStore.sharedRuntimeRootURL())
        let existing = try await store.upsert(
            name: "Preferred response language English",
            type: .user,
            description: "Preferred response language",
            content: "Reply in English.",
            slug: "language-english"
        )
        let responseJSON = #"{"memories":[{"name":"Preferred response language Chinese","type":"user","description":"Preferred response language","content":"Reply in simplified Chinese.","slug":"language-chinese"}]}"#
        let chatClient = StubChatClient(responseText: responseJSON)
        let extractor = AgentDurableMemoryExtractor(runtimeRootURL: runtimeRoot, chatClient: chatClient)

        await extractor.extractIfNeeded(for: "session-1", messages: makeConversation(sessionID: "session-1"))

        let entries = try await store.listEntries()
        XCTAssertEqual(Set(entries.map(\.slug)), ["language-english", "language-chinese"])

        let previousFileURL = AgentStore.sharedRuntimeRootURL()
            .appendingPathComponent("memory", isDirectory: true)
            .appendingPathComponent("\(existing.slug).md", isDirectory: false)
        let raw = try String(contentsOf: previousFileURL, encoding: .utf8)
        XCTAssertTrue(raw.contains("status: active"))
        XCTAssertFalse(raw.contains("resolved_by: language-chinese"))
    }

    func testExtractorAppliesExplicitConflictsFromModelResponse() async throws {
        try resetSharedMemoryRoot()
        let runtimeRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: runtimeRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: runtimeRoot) }

        let store = AgentMemoryStore(runtimeRootURL: AgentStore.sharedRuntimeRootURL())
        let existing = try await store.upsert(
            name: "Preferred response language English",
            type: .user,
            description: "Preferred response language",
            content: "Reply in English.",
            slug: "language-english"
        )
        let responseJSON = #"{"memories":[{"name":"Preferred response language Chinese","type":"user","description":"Preferred response language","content":"Reply in simplified Chinese.","slug":"language-chinese","conflictsWith":["language-english"]}]}"#
        let chatClient = StubChatClient(responseText: responseJSON)
        let extractor = AgentDurableMemoryExtractor(runtimeRootURL: runtimeRoot, chatClient: chatClient)

        await extractor.extractIfNeeded(for: "session-1", messages: makeConversation(sessionID: "session-1"))

        let entries = try await store.listEntries()
        XCTAssertEqual(entries.map(\.slug), ["language-chinese"])

        let previousFileURL = AgentStore.sharedRuntimeRootURL()
            .appendingPathComponent("memory", isDirectory: true)
            .appendingPathComponent("\(existing.slug).md", isDirectory: false)
        let raw = try String(contentsOf: previousFileURL, encoding: .utf8)
        XCTAssertTrue(raw.contains("status: conflicted"))
        XCTAssertTrue(raw.contains("resolved_by: language-chinese"))
    }

    func testSkillExtractorWritesSkillAndAdvancesCursor() async throws {
        try resetSharedMemoryRoot()
        let runtimeRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: runtimeRoot, withIntermediateDirectories: true)
        defer {
            try? resetSharedMemoryRoot()
            try? FileManager.default.removeItem(at: runtimeRoot)
        }

        let responseJSON = #"{"skills":[{"name":"Regression Fix Workflow","description":"Capture regression fixes as a reusable verification workflow.","purpose":"Turn a tool-heavy regression fix into a repeatable playbook future agents can follow.","whenToUse":"Use when a complex debugging task uncovers a repeatable fix-and-verify sequence.","steps":["Inspect the failing behavior and isolate the actual failure mode before patching.","Apply the smallest code change that fixes the issue without widening scope.","Add or update regression coverage that locks the intended behavior in place.","Run focused verification and only save the workflow once the checks pass."],"slug":"regression-fix-workflow"}]}"#
        let chatClient = StubChatClient(responseText: responseJSON)
        let extractor = AgentSkillExtractor(runtimeRootURL: runtimeRoot, chatClient: chatClient)
        let store = AgentSkillStore(runtimeRootURL: AgentStore.sharedRuntimeRootURL())

        let messages = makeComplexWorkflowConversation(sessionID: "session-1")
        await extractor.extractIfNeeded(for: "session-1", messages: messages)
        await extractor.extractIfNeeded(for: "session-1", messages: messages)

        let entries = try await store.listEntries()
        XCTAssertEqual(entries.count, 1)

        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.slug, "regression-fix-workflow")
        XCTAssertEqual(entry.description, "Capture regression fixes as a reusable verification workflow.")
        XCTAssertEqual(entry.whenToUse, "Use when a complex debugging task uncovers a repeatable fix-and-verify sequence.")
        XCTAssertFalse(entry.userInvocable)
        XCTAssertEqual(entry.maturity, .draft)
        XCTAssertEqual(entry.origin, .extractor)
        XCTAssertEqual(chatClient.chatCallCount, 1)
        XCTAssertEqual(chatClient.streamingChatCallCount, 0)

        let skill = try XCTUnwrap(
            AgentSkillsLoader.listSkills(filterUnavailable: false).first(where: { $0.name == "regression-fix-workflow" })
        )
        XCTAssertEqual(skill.source, "shared")
        XCTAssertEqual(skill.description, entry.description)
        XCTAssertFalse(skill.userInvocable)
        XCTAssertEqual(skill.maturity, "draft")
        XCTAssertEqual(skill.origin, "extractor")
    }

    func testSkillExtractorSkipsSimpleConversationWithoutComplexitySignals() async throws {
        try resetSharedMemoryRoot()
        let runtimeRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: runtimeRoot, withIntermediateDirectories: true)
        defer {
            try? resetSharedMemoryRoot()
            try? FileManager.default.removeItem(at: runtimeRoot)
        }

        let responseJSON = #"{"skills":[{"name":"Should Not Be Written","description":"unexpected","purpose":"unexpected","whenToUse":"unexpected","steps":["unexpected one","unexpected two","unexpected three"]}]}"#
        let chatClient = StubChatClient(responseText: responseJSON)
        let extractor = AgentSkillExtractor(runtimeRootURL: runtimeRoot, chatClient: chatClient)
        let store = AgentSkillStore(runtimeRootURL: AgentStore.sharedRuntimeRootURL())

        await extractor.extractIfNeeded(for: "session-1", messages: makeConversation(sessionID: "session-1"))

        let entries = try await store.listEntries()
        XCTAssertTrue(entries.isEmpty)
        XCTAssertEqual(chatClient.chatCallCount, 0)
        XCTAssertEqual(chatClient.streamingChatCallCount, 0)
    }

    private func makeConversation(sessionID: String) -> [ConversationMessage] {
        let user = ConversationMessage(sessionID: sessionID, role: .user)
        user.textContent = "以后回答尽量简洁，不要在最后重复总结。"

        let assistant = ConversationMessage(sessionID: sessionID, role: .assistant)
        assistant.textContent = "收到，后续我会保持简洁。"

        return [user, assistant]
    }

    private func makeComplexWorkflowConversation(sessionID: String) -> [ConversationMessage] {
        let user = ConversationMessage(sessionID: sessionID, role: .user)
        user.textContent = "请修复 runtime skill 优先级回归，并把排查到的可复用 workflow 沉淀下来。"

        let assistantPlan = ConversationMessage(sessionID: sessionID, role: .assistant)
        assistantPlan.parts = [
            .text(TextContentPart(text: "我会先定位 skill loader 的优先级实现，再检查失败断言是不是路径标准化问题，最后补上稳定的回归验证。")),
            .toolCall(ToolCallContentPart(toolName: "Read", apiName: "Read")),
        ]

        let assistantFix = ConversationMessage(sessionID: sessionID, role: .assistant)
        assistantFix.parts = [
            .text(TextContentPart(text: "我确认 workspace > shared > builtin 的逻辑没问题，真正不稳定的是测试把 workspace 路径和临时目录字符串前缀强绑定了。修复方式是改成解析符号链接后的完整文件路径比较，然后重新跑聚焦测试，确认 runtime skill 仍能被 catalog 发现。")),
            .toolCall(ToolCallContentPart(toolName: "ApplyPatch", apiName: "ApplyPatch")),
            .toolCall(ToolCallContentPart(toolName: "Bash", apiName: "Bash")),
        ]

        return [user, assistantPlan, assistantFix]
    }

    private func resetSharedMemoryRoot(fileManager: FileManager = .default) throws {
        let sharedMemoryRoot = AgentStore.sharedRuntimeRootURL(fileManager: fileManager)
        if fileManager.fileExists(atPath: sharedMemoryRoot.path) {
            try fileManager.removeItem(at: sharedMemoryRoot)
        }
    }
}

@MainActor
final class ConversationCompactionTests: XCTestCase {
    func testManualCompactBuildsBoundarySummaryAndPreservedMessages() async throws {
        let storage = DisposableStorageProvider()
        let toolProvider = StubToolProvider()
        let session = ConversationSession(
            id: "compact-session",
            configuration: .init(storage: storage, tools: toolProvider)
        )
        let originalIDs = seedConversation(into: session, turnCount: 8)

        let client = StubChatClient(
            responseText: """
            <analysis>scratch work</analysis>
            <summary>
            1. Primary request and intent: align compact behavior.
            2. Key technical concepts: boundary markers, summaries, PTL retry.
            </summary>
            """
        )
        let model = ConversationSession.Model(
            client: client,
            capabilities: [.tool],
            contextLength: 32000,
            maxOutputTokens: 8000,
            autoCompactEnabled: true
        )

        try await session.compactConversation(model: model)

        XCTAssertEqual(client.chatCallCount, 1)
        XCTAssertEqual(client.lastChatBody?.maxCompletionTokens, 8000)
        XCTAssertEqual(session.messages.filter(\.isCompactBoundary).count, 1)
        XCTAssertEqual(session.messages.filter(\.isCompactSummary).count, 1)

        let summary = try XCTUnwrap(session.messages.first(where: { $0.isCompactSummary }))
        XCTAssertFalse(summary.textContent.contains("<analysis>"))
        XCTAssertTrue(summary.textContent.contains("align compact behavior"))
        XCTAssertFalse(summary.textContent.contains("Recent messages are preserved verbatim."))

        let preservedIDs = session.messages
            .filter { !$0.isCompactBoundary && !$0.isCompactSummary }
            .map(\.id)
        XCTAssertTrue(preservedIDs.isEmpty)
    }

    func testManualCompactFailsWhenSummaryGenerationFails() async throws {
        let storage = DisposableStorageProvider()
        let session = ConversationSession(id: "compact-retry", configuration: .init(storage: storage))
        _ = seedConversation(into: session, turnCount: 10)

        let client = StubChatClient(scriptedResponses: [
            .failure("PROMPT TOO LONG: reduce the length of the messages"),
        ])
        let model = ConversationSession.Model(client: client, capabilities: [], contextLength: 32000, autoCompactEnabled: true)

        do {
            try await session.compactConversation(model: model)
            XCTFail("Expected compaction to fail when summary generation fails")
        } catch {
            XCTAssertEqual(
                error.localizedDescription,
                "Conversation too long to compact. Try compacting a smaller range."
            )
        }

        XCTAssertEqual(client.chatCallCount, 4)
        XCTAssertFalse(session.messages.contains(where: { $0.isCompactSummary }))
    }

    func testCompactPTLRetryDropsWholeAssistantRounds() async throws {
        let storage = DisposableStorageProvider()
        let session = ConversationSession(id: "compact-ptl-rounds", configuration: .init(storage: storage))
        _ = seedConversation(into: session, turnCount: 10)

        let client = StubChatClient(scriptedResponses: [
            .failure("PROMPT TOO LONG"),
            .success("<summary>Recovered after dropping the oldest round.</summary>"),
        ])
        let model = ConversationSession.Model(client: client, capabilities: [], contextLength: 32000, autoCompactEnabled: true)

        try await session.compactConversation(model: model)

        XCTAssertEqual(client.chatCallCount, 2)
        XCTAssertEqual(client.chatBodies.count, 2)

        let firstRequest = try XCTUnwrap(compactPromptBody(from: client.chatBodies[0]))
        let retryRequest = try XCTUnwrap(compactPromptBody(from: client.chatBodies[1]))

        XCTAssertTrue(firstRequest.contains("message-0"))
        XCTAssertTrue(firstRequest.contains("message-1"))
        XCTAssertFalse(retryRequest.contains("message-0"))
        XCTAssertTrue(retryRequest.contains("message-1"))
    }

    func testPartialCompactFromPlacesSummaryBeforePreservedPrefix() async throws {
        let storage = DisposableStorageProvider()
        let session = ConversationSession(id: "partial-from", configuration: .init(storage: storage))
        let ids = seedConversation(into: session, turnCount: 6)
        let pivotID = ids[4]

        let client = StubChatClient(responseText: "<summary>Later work compacted.</summary>")
        let model = ConversationSession.Model(client: client, capabilities: [], contextLength: 32000, autoCompactEnabled: true)

        try await session.partialCompactConversation(around: pivotID, direction: .from, model: model)

        let visibleIDs = session.messages
            .filter { !$0.isCompactBoundary && !$0.isCompactSummary }
            .map(\.id)
        XCTAssertEqual(visibleIDs, Array(ids.prefix(4)))
        XCTAssertFalse(visibleIDs.contains(pivotID))

        let summaryIndex = try XCTUnwrap(session.messages.firstIndex(where: { $0.isCompactSummary }))
        let boundaryIndex = try XCTUnwrap(session.messages.firstIndex(where: { $0.isCompactBoundary }))
        let firstKeptIndex = try XCTUnwrap(session.messages.firstIndex(where: { $0.id == ids[0] }))
        XCTAssertGreaterThan(summaryIndex, boundaryIndex)
        XCTAssertLessThan(summaryIndex, firstKeptIndex)
    }

    func testReloadKeepsCompactedContextAfterCompact() async throws {
        let runtimeRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: runtimeRoot, withIntermediateDirectories: true)
        defer {
            TranscriptStorageProvider.removeProvider(runtimeRootURL: runtimeRoot)
            try? FileManager.default.removeItem(at: runtimeRoot)
        }

        let storage = TranscriptStorageProvider.provider(runtimeRootURL: runtimeRoot)
        let sessionID = "transcript-reload"
        let session = ConversationSession(id: sessionID, configuration: .init(storage: storage))
        let originalIDs = seedConversation(into: session, turnCount: 8)

        let client = StubChatClient(responseText: "<summary>Compacted history.</summary>")
        let model = ConversationSession.Model(client: client, capabilities: [], contextLength: 32000, autoCompactEnabled: true)

        try await session.compactConversation(model: model)

        let compactedContextIDs = storage.messages(in: sessionID)
            .filter { !$0.isCompactBoundary && !$0.isCompactSummary }
            .map(\.id)
        XCTAssertLessThan(compactedContextIDs.count, originalIDs.count)

        let reloaded = ConversationSession(id: sessionID, configuration: .init(storage: storage))
        let reloadedIDs = reloaded.messages
            .filter { !$0.isCompactBoundary && !$0.isCompactSummary }
            .map(\.id)

        XCTAssertEqual(reloadedIDs, compactedContextIDs)
        XCTAssertTrue(reloaded.messages.contains(where: { $0.isCompactBoundary }))
    }

    func testRollbackAfterCompactDoesNotRestoreDeletedTranscriptMessages() async throws {
        let runtimeRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: runtimeRoot, withIntermediateDirectories: true)
        defer {
            TranscriptStorageProvider.removeProvider(runtimeRootURL: runtimeRoot)
            try? FileManager.default.removeItem(at: runtimeRoot)
        }

        let storage = TranscriptStorageProvider.provider(runtimeRootURL: runtimeRoot)
        let sessionID = "transcript-rollback"
        let session = ConversationSession(id: sessionID, configuration: .init(storage: storage))
        let originalIDs = seedConversation(into: session, turnCount: 8)

        let client = StubChatClient(responseText: "<summary>Compacted history.</summary>")
        let model = ConversationSession.Model(client: client, capabilities: [], contextLength: 32000, autoCompactEnabled: true)

        try await session.compactConversation(model: model)

        let rollbackTargetID = originalIDs[4]
        session.delete(after: rollbackTargetID)
        session.delete(rollbackTargetID)

        let remainingVisibleIDs = session.messages
            .filter { !$0.isCompactBoundary && !$0.isCompactSummary }
            .map(\.id)
        XCTAssertTrue(remainingVisibleIDs.isEmpty)

        let reloaded = ConversationSession(id: sessionID, configuration: .init(storage: storage))
        let reloadedVisibleIDs = reloaded.messages
            .filter { !$0.isCompactBoundary && !$0.isCompactSummary }
            .map(\.id)
        XCTAssertTrue(reloadedVisibleIDs.isEmpty)
        XCTAssertTrue(reloaded.messages.contains(where: { $0.isCompactBoundary }))
    }

    private func seedConversation(into session: ConversationSession, turnCount: Int) -> [String] {
        var ids: [String] = []
        for index in 0 ..< turnCount {
            let role: MessageRole = index.isMultiple(of: 2) ? .user : .assistant
            let message = session.appendNewMessage(role: role)
            message.textContent = "message-\(index)"
            message.createdAt = Date(timeIntervalSince1970: TimeInterval(index))
            ids.append(message.id)
        }
        session.persistMessages()
        return ids
    }
}

private enum StubChatClientResponse {
    case success(String)
    case failure(String)
}

private struct StubChatClientError: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}

private final class StubChatClient: ChatClient, @unchecked Sendable {
    let errorCollector = ErrorCollector.new()

    private var scriptedResponses: [StubChatClientResponse]
    private let lock = NSLock()
    private var calls = 0
    private var streamingCalls = 0
    private var lastBody: ChatRequestBody?
    private var recordedBodies: [ChatRequestBody] = []

    init(responseText: String) {
        scriptedResponses = [.success(responseText)]
    }

    init(scriptedResponses: [StubChatClientResponse]) {
        self.scriptedResponses = scriptedResponses
    }

    var chatCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    var streamingChatCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return streamingCalls
    }

    var lastChatBody: ChatRequestBody? {
        lock.lock()
        defer { lock.unlock() }
        return lastBody
    }

    var chatBodies: [ChatRequestBody] {
        lock.lock()
        defer { lock.unlock() }
        return recordedBodies
    }

    func chat(body: ChatRequestBody) async throws -> ChatResponse {
        lock.lock()
        calls += 1
        lastBody = body
        recordedBodies.append(body)
        let response: StubChatClientResponse
        if scriptedResponses.count > 1 {
            response = scriptedResponses.removeFirst()
        } else {
            response = scriptedResponses.first ?? .success("")
        }
        lock.unlock()
        switch response {
        case let .success(text):
            return ChatResponse(reasoning: "", text: text, images: [], tools: [])
        case let .failure(message):
            await errorCollector.collect(message)
            throw StubChatClientError(message: message)
        }
    }

    func streamingChat(body _: ChatRequestBody) async throws -> AnyAsyncSequence<ChatResponseChunk> {
        lock.lock()
        streamingCalls += 1
        lock.unlock()
        return AsyncStream<ChatResponseChunk> { continuation in
            continuation.finish()
        }.eraseToAnyAsyncSequence()
    }
}

private final class StubToolProvider: ToolProvider, @unchecked Sendable {
    func enabledTools() async -> [ChatRequestBody.Tool] {
        [
            .function(
                name: "Read",
                description: "Read a file",
                parameters: nil,
                strict: nil
            ),
        ]
    }

    func findTool(for _: ToolRequest) async -> ToolExecutor? {
        nil
    }

    func executeTool(
        _: ToolExecutor,
        parameters _: String
    ) async throws -> ToolResult {
        ToolResult(text: "")
    }
}

private func compactPromptBody(from body: ChatRequestBody) -> String? {
    guard body.messages.count >= 2 else { return nil }
    guard case let .user(content, _) = body.messages[1] else { return nil }
    switch content {
    case let .text(text):
        return text
    case .parts:
        return nil
    }
}
