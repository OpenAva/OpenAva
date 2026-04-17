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

    func testLargeTranscriptStreamLoadRecoversPreBoundaryMetadata() throws {
        let runtimeRootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: runtimeRootURL, withIntermediateDirectories: true)
        TranscriptStorageProvider.removeProvider(runtimeRootURL: runtimeRootURL)
        defer {
            TranscriptStorageProvider.removeProvider(runtimeRootURL: runtimeRootURL)
            try? FileManager.default.removeItem(at: runtimeRootURL)
        }

        let sessionID = "large-stream-recovery"
        let transcriptDir = runtimeRootURL
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(sessionID, isDirectory: true)
        try FileManager.default.createDirectory(at: transcriptDir, withIntermediateDirectories: true)

        let transcriptURL = transcriptDir.appendingPathComponent("transcript.jsonl", isDirectory: false)
        let indexURL = runtimeRootURL.appendingPathComponent("session_index.json", isDirectory: false)

        var lines: [String] = []
        var previousEntryUUID: String?
        let largePayloadSize = 512 * 1024

        for index in 0 ..< 12 {
            let role: MessageRole = index.isMultiple(of: 2) ? .user : .assistant
            let entryUUID = UUID().uuidString
            let largeText = "pre-boundary-\(index)-" + String(repeating: String(index % 10), count: largePayloadSize)
            let entry = TestTranscriptEntry.message(
                entryUUID: entryUUID,
                parentUUID: previousEntryUUID,
                sessionID: sessionID,
                role: role.rawValue,
                sequence: Int64(index + 1),
                text: largeText,
                timestamp: Self.testTimestamp(seconds: index)
            )
            try lines.append(encodeJSONLine(entry))
            previousEntryUUID = entryUUID
        }

        try lines.append(
            encodeJSONLine(
                TestTranscriptEntry.metadata(
                    uuid: UUID().uuidString,
                    sessionID: sessionID,
                    type: "custom-title",
                    sequence: 100,
                    timestamp: Self.testTimestamp(seconds: 100),
                    customTitle: "Recovered Large Title",
                    aiTitle: nil,
                    lastPrompt: nil,
                    tag: nil,
                    text: nil,
                    result: nil,
                    subtype: nil,
                    isError: nil
                )
            )
        )
        try lines.append(
            encodeJSONLine(
                TestTranscriptEntry.metadata(
                    uuid: UUID().uuidString,
                    sessionID: sessionID,
                    type: "last-prompt",
                    sequence: 101,
                    timestamp: Self.testTimestamp(seconds: 101),
                    customTitle: nil,
                    aiTitle: nil,
                    lastPrompt: "Recovered prompt from metadata",
                    tag: nil,
                    text: nil,
                    result: nil,
                    subtype: nil,
                    isError: nil
                )
            )
        )
        try lines.append(
            encodeJSONLine(
                TestTranscriptEntry.metadata(
                    uuid: UUID().uuidString,
                    sessionID: sessionID,
                    type: "result",
                    sequence: 102,
                    timestamp: Self.testTimestamp(seconds: 102),
                    customTitle: nil,
                    aiTitle: nil,
                    lastPrompt: nil,
                    tag: nil,
                    text: nil,
                    result: "Synthetic failure",
                    subtype: "error",
                    isError: true
                )
            )
        )
        try lines.append(
            encodeJSONLine(
                TestTranscriptEntry.boundary(
                    uuid: UUID().uuidString,
                    sessionID: sessionID,
                    sequence: 103,
                    timestamp: Self.testTimestamp(seconds: 103)
                )
            )
        )

        let postUserEntryUUID = UUID().uuidString
        try lines.append(
            encodeJSONLine(
                TestTranscriptEntry.message(
                    entryUUID: postUserEntryUUID,
                    parentUUID: nil,
                    sessionID: sessionID,
                    role: MessageRole.user.rawValue,
                    sequence: 104,
                    text: "after-boundary-user",
                    timestamp: Self.testTimestamp(seconds: 104)
                )
            )
        )
        try lines.append(
            encodeJSONLine(
                TestTranscriptEntry.message(
                    entryUUID: UUID().uuidString,
                    parentUUID: postUserEntryUUID,
                    sessionID: sessionID,
                    role: MessageRole.assistant.rawValue,
                    sequence: 105,
                    text: "after-boundary-assistant",
                    timestamp: Self.testTimestamp(seconds: 105)
                )
            )
        )

        try Data(lines.joined(separator: "\n").utf8).write(to: transcriptURL, options: .atomic)

        let attrs = try FileManager.default.attributesOfItem(atPath: transcriptURL.path)
        let fileSize = try XCTUnwrap(attrs[.size] as? Int)
        XCTAssertGreaterThan(fileSize, 5 * 1024 * 1024)

        let storage = TranscriptStorageProvider.provider(runtimeRootURL: runtimeRootURL)
        let recoveredMessages = storage.messages(in: sessionID)

        XCTAssertEqual(recoveredMessages.map(\.textContent), ["after-boundary-user", "after-boundary-assistant"])
        XCTAssertEqual(storage.sessionStatus(for: sessionID), "failed")
        XCTAssertEqual(storage.title(for: sessionID), "Recovered Large Title")

        let indexData = try Data(contentsOf: indexURL)
        let persisted = try JSONDecoder().decode(PersistedSessionEnvelope.self, from: indexData)
        let record = try XCTUnwrap(persisted.sessions.first(where: { $0.key == sessionID }))
        XCTAssertEqual(record.displayName, "Recovered Large Title")
        XCTAssertEqual(record.lastPrompt, "Recovered prompt from metadata")
        XCTAssertEqual(record.status, "failed")
    }

    func testProtocolRecorderRoutesTranscriptEventsIntoSessionLog() throws {
        let runtimeRootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: runtimeRootURL, withIntermediateDirectories: true)
        TranscriptStorageProvider.removeProvider(runtimeRootURL: runtimeRootURL)
        defer {
            TranscriptStorageProvider.removeProvider(runtimeRootURL: runtimeRootURL)
            try? FileManager.default.removeItem(at: runtimeRootURL)
        }

        let storage: any StorageProvider = TranscriptStorageProvider.provider(runtimeRootURL: runtimeRootURL)
        storage.recordTranscript(.turnStarted, for: "main")
        storage.recordTranscript(.turnFinished(success: false, errorDescription: "boom"), for: "main")

        let generatedTitle = ConversationTitleMetadata(title: "Protocol Title", avatar: "🧪").storageValue
        storage.recordTranscript(.recordAITitle(generatedTitle), for: "main")
        storage.flushTranscript()

        XCTAssertEqual(storage.sessionStatus(for: "main"), "failed")
        XCTAssertEqual(ConversationTitleMetadata(storageValue: storage.title(for: "main"))?.title, "Protocol Title")

        TranscriptStorageProvider.removeProvider(runtimeRootURL: runtimeRootURL)
        let reloadedStorage = TranscriptStorageProvider.provider(runtimeRootURL: runtimeRootURL)

        XCTAssertEqual(reloadedStorage.sessionStatus(for: "main"), "failed")
        XCTAssertEqual(ConversationTitleMetadata(storageValue: reloadedStorage.title(for: "main"))?.title, "Protocol Title")
    }

    private static func testTimestamp(seconds: Int) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(seconds)))
    }

    private func encodeJSONLine<T: Encodable>(_ value: T) throws -> String {
        let data = try JSONEncoder().encode(value)
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }
}

private struct PersistedSessionEnvelope: Decodable {
    let sessions: [PersistedSessionRecord]
}

private struct PersistedSessionRecord: Decodable {
    let key: String
    let displayName: String
    let status: String
    let lastPrompt: String?
}

private struct TestTranscriptEntry: Encodable {
    let uuid: String
    let parentUuid: String?
    let logicalParentUuid: String?
    let sessionId: String
    let type: String
    let subtype: String?
    let timestamp: String
    let sequence: Int64
    let message: TestTranscriptMessageRecord?
    let messageUUIDs: [String]?
    let customTitle: String?
    let aiTitle: String?
    let lastPrompt: String?
    let summary: String?
    let tag: String?
    let toolUseID: String?
    let toolName: String?
    let toolUseState: String?
    let text: String?
    let usage: TestUsagePayload?
    let isError: Bool?
    let result: String?

    static func message(
        entryUUID: String,
        parentUUID: String?,
        sessionID: String,
        role: String,
        sequence: Int64,
        text: String,
        timestamp: String
    ) -> Self {
        Self(
            uuid: entryUUID,
            parentUuid: parentUUID,
            logicalParentUuid: nil,
            sessionId: sessionID,
            type: role,
            subtype: nil,
            timestamp: timestamp,
            sequence: sequence,
            message: TestTranscriptMessageRecord(
                uuid: entryUUID,
                role: role,
                timestamp: timestamp,
                content: [
                    TestTranscriptContentBlock(
                        type: "text",
                        text: text,
                        imageUrl: nil,
                        toolUseID: nil,
                        toolName: nil,
                        apiName: nil,
                        toolUseState: nil,
                        reasoningDuration: 0,
                        isCollapsed: nil
                    ),
                ],
                toolUseID: nil,
                toolName: nil,
                stopReason: nil,
                metadata: nil
            ),
            messageUUIDs: nil,
            customTitle: nil,
            aiTitle: nil,
            lastPrompt: nil,
            summary: nil,
            tag: nil,
            toolUseID: nil,
            toolName: nil,
            toolUseState: nil,
            text: nil,
            usage: nil,
            isError: nil,
            result: nil
        )
    }

    static func boundary(uuid: String, sessionID: String, sequence: Int64, timestamp: String) -> Self {
        Self(
            uuid: uuid,
            parentUuid: nil,
            logicalParentUuid: nil,
            sessionId: sessionID,
            type: "system",
            subtype: "compact_boundary",
            timestamp: timestamp,
            sequence: sequence,
            message: nil,
            messageUUIDs: nil,
            customTitle: nil,
            aiTitle: nil,
            lastPrompt: nil,
            summary: nil,
            tag: nil,
            toolUseID: nil,
            toolName: nil,
            toolUseState: nil,
            text: nil,
            usage: nil,
            isError: nil,
            result: nil
        )
    }

    static func metadata(
        uuid: String,
        sessionID: String,
        type: String,
        sequence: Int64,
        timestamp: String,
        customTitle: String?,
        aiTitle: String?,
        lastPrompt: String?,
        tag: String?,
        text: String?,
        result: String?,
        subtype: String?,
        isError: Bool?
    ) -> Self {
        Self(
            uuid: uuid,
            parentUuid: nil,
            logicalParentUuid: nil,
            sessionId: sessionID,
            type: type,
            subtype: subtype,
            timestamp: timestamp,
            sequence: sequence,
            message: nil,
            messageUUIDs: nil,
            customTitle: customTitle,
            aiTitle: aiTitle,
            lastPrompt: lastPrompt,
            summary: nil,
            tag: tag,
            toolUseID: nil,
            toolName: nil,
            toolUseState: nil,
            text: text,
            usage: nil,
            isError: isError,
            result: result
        )
    }
}

private struct TestTranscriptMessageRecord: Encodable {
    let uuid: String
    let role: String
    let timestamp: String
    let content: [TestTranscriptContentBlock]
    let toolUseID: String?
    let toolName: String?
    let stopReason: String?
    let metadata: [String: String]?
}

private struct TestTranscriptContentBlock: Encodable {
    let type: String
    let text: String?
    let imageUrl: TestImageURL?
    let toolUseID: String?
    let toolName: String?
    let apiName: String?
    let toolUseState: String?
    let reasoningDuration: Double
    let isCollapsed: Bool?
}

private struct TestImageURL: Encodable {
    let url: String
    let detail: String?
}

private struct TestUsagePayload: Encodable {
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let cacheWriteTokens: Int
    let costUSD: Double?
    let model: String?
}
