import ChatClient
import ChatUI
import XCTest
@testable import OpenAva

@MainActor
final class TranscriptStorageProviderCollapsePersistenceTests: XCTestCase {
    func testSupportRootWritesTranscriptToAgentSessionsFile() throws {
        let supportRootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: supportRootURL, withIntermediateDirectories: true)
        TranscriptStorageProvider.removeProvider(supportRootURL: supportRootURL)
        defer {
            TranscriptStorageProvider.removeProvider(supportRootURL: supportRootURL)
            try? FileManager.default.removeItem(at: supportRootURL)
        }

        let storage = TranscriptStorageProvider.provider(supportRootURL: supportRootURL)
        let message = ConversationMessage(sessionID: "main", role: .user)
        message.textContent = "hello"
        storage.save(message: message)

        let transcriptURL = supportRootURL
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("main.jsonl", isDirectory: false)

        XCTAssertTrue(FileManager.default.fileExists(atPath: transcriptURL.path))
    }

    func testStreamingTextPersistsSingleAssistantTranscriptEntry() async throws {
        let supportRootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: supportRootURL, withIntermediateDirectories: true)
        TranscriptStorageProvider.removeProvider(supportRootURL: supportRootURL)
        defer {
            TranscriptStorageProvider.removeProvider(supportRootURL: supportRootURL)
            try? FileManager.default.removeItem(at: supportRootURL)
        }

        let storage = TranscriptStorageProvider.provider(supportRootURL: supportRootURL)
        let session = ConversationSession(id: "main", configuration: .init(storage: storage))

        let part1 = String(repeating: "甲", count: 300)
        let part2 = String(repeating: "乙", count: 300)
        let part3 = String(repeating: "丙", count: 300)
        let expectedText = part1 + part2 + part3

        let client = StreamingStubChatClient(chunks: [
            .text(part1),
            .text(part2),
            .text(part3),
        ])

        await session.submitPrompt(
            model: .init(client: client, capabilities: [], contextLength: 32000, autoCompactEnabled: true),
            prompt: .init(text: "请输出长文本")
        )

        let transcriptURL = supportRootURL
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("main.jsonl", isDirectory: false)
        let transcriptText = try String(contentsOf: transcriptURL, encoding: .utf8)
        let entries = transcriptText
            .split(separator: "\n")
            .compactMap { line -> [String: Any]? in
                guard let data = line.data(using: .utf8) else { return nil }
                return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            }

        let assistantEntries = entries.filter { ($0["type"] as? String) == MessageRole.assistant.rawValue }
        XCTAssertEqual(assistantEntries.count, 1, transcriptText)

        let assistantMessageUUIDs = assistantEntries.compactMap { entry -> String? in
            (entry["message"] as? [String: Any])?["uuid"] as? String
        }
        XCTAssertEqual(Set(assistantMessageUUIDs).count, 1)
        XCTAssertEqual(session.messages.map(\.textContent), ["请输出长文本", expectedText])
    }

    func testNoResponseErrorStaysTransientAndDoesNotEnterTranscriptOrHistory() async throws {
        let supportRootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: supportRootURL, withIntermediateDirectories: true)
        TranscriptStorageProvider.removeProvider(supportRootURL: supportRootURL)
        defer {
            TranscriptStorageProvider.removeProvider(supportRootURL: supportRootURL)
            try? FileManager.default.removeItem(at: supportRootURL)
        }

        let storage = TranscriptStorageProvider.provider(supportRootURL: supportRootURL)
        let session = ConversationSession(id: "main", configuration: .init(storage: storage))
        let client = StreamingStubChatClient(chunks: [])

        await session.submitPrompt(
            model: .init(client: client, capabilities: [], contextLength: 32000, autoCompactEnabled: true),
            prompt: .init(text: "会失败的问题")
        )

        XCTAssertEqual(session.messages.count, 2)
        XCTAssertEqual(session.messages[0].role, .user)
        XCTAssertEqual(session.messages[1].role, .assistant)
        XCTAssertEqual(session.messages[1].finishReason, .error)
        XCTAssertTrue(session.messages[1].isTransientExecutionError)
        XCTAssertEqual(session.historyMessages().map(\.id), [session.messages[0].id])

        let entries = try transcriptEntries(at: supportRootURL, sessionID: "main")
        XCTAssertEqual(entries.filter { ($0["type"] as? String) == MessageRole.user.rawValue }.count, 1)
        XCTAssertEqual(entries.filter { ($0["type"] as? String) == MessageRole.assistant.rawValue }.count, 0)

        let transcriptURL = supportRootURL
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("main.jsonl", isDirectory: false)
        let transcriptText = try String(contentsOf: transcriptURL, encoding: .utf8)
        XCTAssertFalse(transcriptText.contains("No response from model"), transcriptText)
    }

    func testSubmitPromptDoesNotDuplicateCurrentUserMessageInFirstRequest() async throws {
        let supportRootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: supportRootURL, withIntermediateDirectories: true)
        TranscriptStorageProvider.removeProvider(supportRootURL: supportRootURL)
        defer {
            TranscriptStorageProvider.removeProvider(supportRootURL: supportRootURL)
            try? FileManager.default.removeItem(at: supportRootURL)
        }

        let storage = TranscriptStorageProvider.provider(supportRootURL: supportRootURL)
        let session = ConversationSession(id: "main", configuration: .init(storage: storage))
        let client = StreamingStubChatClient(chunks: [])

        await session.submitPrompt(
            model: .init(client: client, capabilities: [], contextLength: 32000, autoCompactEnabled: true),
            prompt: .init(text: "只保留一条当前用户消息")
        )

        let firstBody = try XCTUnwrap(client.firstStreamingBody)
        let userTexts = firstBody.messages.compactMap { message -> String? in
            guard case let .user(content, _) = message,
                  case let .text(text) = content
            else {
                return nil
            }
            return text
        }
        XCTAssertEqual(userTexts, ["只保留一条当前用户消息"])
    }

    func testSubmitPromptFailsWhenToolCallArrivesWithoutToolProvider() async throws {
        let supportRootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: supportRootURL, withIntermediateDirectories: true)
        TranscriptStorageProvider.removeProvider(supportRootURL: supportRootURL)
        defer {
            TranscriptStorageProvider.removeProvider(supportRootURL: supportRootURL)
            try? FileManager.default.removeItem(at: supportRootURL)
        }

        let storage = TranscriptStorageProvider.provider(supportRootURL: supportRootURL)
        let session = ConversationSession(id: "main", configuration: .init(storage: storage))
        let client = StreamingStubChatClient(chunks: [
            .tool(.init(id: "tool-call-1", name: "bash", arguments: "{}")),
        ])

        await session.submitPrompt(
            model: .init(client: client, capabilities: [.tool], contextLength: 32000, autoCompactEnabled: true),
            prompt: .init(text: "调用工具")
        )

        XCTAssertEqual(session.messages.count, 3)
        XCTAssertEqual(session.messages[0].role, .user)
        XCTAssertEqual(session.messages[1].role, .assistant)
        XCTAssertEqual(session.messages[1].finishReason, .toolCalls)
        XCTAssertEqual(session.messages[2].role, .tool)
        let toolResult = try XCTUnwrap(session.messages[2].parts.compactMap { part -> ToolResultContentPart? in
            guard case let .toolResult(value) = part else { return nil }
            return value
        }.first)
        XCTAssertTrue(toolResult.result.contains("Tool execution is unavailable."))
    }

    func testReadOnlyToolPersistsAllowPermissionMetadata() async throws {
        let supportRootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: supportRootURL, withIntermediateDirectories: true)
        TranscriptStorageProvider.removeProvider(supportRootURL: supportRootURL)
        defer {
            TranscriptStorageProvider.removeProvider(supportRootURL: supportRootURL)
            try? FileManager.default.removeItem(at: supportRootURL)
        }

        let definition = ToolDefinition(
            functionName: "tool_read_only",
            command: "tool.read.only",
            description: "",
            parametersSchema: .init([:] as [String: Any]),
            isReadOnly: true,
            isConcurrencySafe: true
        )
        let provider = PermissionPolicyStubToolProvider(
            tool: definition,
            result: ToolResult(text: "read ok")
        )
        let storage = TranscriptStorageProvider.provider(supportRootURL: supportRootURL)
        let session = ConversationSession(
            id: "main",
            configuration: .init(storage: storage, tools: provider)
        )
        let client = SequencedStreamingStubChatClient(chunkSequences: [
            [.tool(.init(id: "tool-call-allow", name: definition.functionName, arguments: "{}"))],
            [.text("完成")],
        ])

        await session.submitPrompt(
            model: .init(client: client, capabilities: [.tool], contextLength: 32000, autoCompactEnabled: true),
            prompt: .init(text: "调用只读工具")
        )

        XCTAssertEqual(provider.executeCallCount, 1)
        let toolMessage = try XCTUnwrap(session.messages.last(where: { $0.role == .tool }))
        XCTAssertEqual(toolMessage.metadata[ToolMessageMetadata.toolCallState], ToolCallState.succeeded.rawValue)
        XCTAssertEqual(toolMessage.metadata[ToolMessageMetadata.permissionBehavior], ToolPermissionBehavior.allow.rawValue)
        XCTAssertEqual(toolMessage.metadata[ToolMessageMetadata.permissionReason], "read_only_tool")
        XCTAssertNil(toolMessage.metadata[ToolMessageMetadata.permissionMessage])

        let entries = try transcriptEntries(at: supportRootURL, sessionID: "main")
        let persistedToolEntry = try XCTUnwrap(entries.last(where: { ($0["type"] as? String) == MessageRole.tool.rawValue }))
        let persistedMetadata = try XCTUnwrap((persistedToolEntry["message"] as? [String: Any])?["metadata"] as? [String: Any])
        XCTAssertEqual(persistedMetadata[ToolMessageMetadata.permissionBehavior] as? String, ToolPermissionBehavior.allow.rawValue)
        XCTAssertEqual(persistedMetadata[ToolMessageMetadata.permissionReason] as? String, "read_only_tool")
        XCTAssertNil(persistedMetadata[ToolMessageMetadata.permissionMessage])
    }

    func testDestructiveToolIsBlockedWithAskPermissionMetadata() async throws {
        let supportRootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: supportRootURL, withIntermediateDirectories: true)
        TranscriptStorageProvider.removeProvider(supportRootURL: supportRootURL)
        defer {
            TranscriptStorageProvider.removeProvider(supportRootURL: supportRootURL)
            try? FileManager.default.removeItem(at: supportRootURL)
        }

        let definition = ToolDefinition(
            functionName: "tool_destructive",
            command: "tool.destructive",
            description: "",
            parametersSchema: .init([:] as [String: Any]),
            isDestructive: true
        )
        let provider = PermissionPolicyStubToolProvider(
            tool: definition,
            result: ToolResult(text: "should not execute")
        )
        let storage = TranscriptStorageProvider.provider(supportRootURL: supportRootURL)
        let session = ConversationSession(
            id: "main",
            configuration: .init(storage: storage, tools: provider)
        )
        let client = SequencedStreamingStubChatClient(chunkSequences: [
            [.tool(.init(id: "tool-call-ask", name: definition.functionName, arguments: "{}"))],
            [.text("完成")],
        ])

        await session.submitPrompt(
            model: .init(client: client, capabilities: [.tool], contextLength: 32000, autoCompactEnabled: true),
            prompt: .init(text: "调用破坏性工具")
        )

        XCTAssertEqual(provider.executeCallCount, 0)
        let toolMessage = try XCTUnwrap(session.messages.last(where: { $0.role == .tool }))
        XCTAssertEqual(toolMessage.metadata[ToolMessageMetadata.toolCallState], ToolCallState.failed.rawValue)
        XCTAssertEqual(toolMessage.metadata[ToolMessageMetadata.permissionBehavior], ToolPermissionBehavior.ask.rawValue)
        XCTAssertEqual(toolMessage.metadata[ToolMessageMetadata.permissionReason], "destructive_tool_requires_approval")
        XCTAssertEqual(toolMessage.metadata[ToolMessageMetadata.permissionMessage], "Tool execution requires approval because this tool can modify or delete data.")

        let toolResult = try XCTUnwrap(toolMessage.parts.compactMap { part -> ToolResultContentPart? in
            guard case let .toolResult(value) = part else { return nil }
            return value
        }.first)
        XCTAssertTrue(toolResult.result.contains("requires approval"))
    }

    func testDeniedToolPersistsPermissionMetadata() async throws {
        let supportRootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: supportRootURL, withIntermediateDirectories: true)
        TranscriptStorageProvider.removeProvider(supportRootURL: supportRootURL)
        defer {
            TranscriptStorageProvider.removeProvider(supportRootURL: supportRootURL)
            try? FileManager.default.removeItem(at: supportRootURL)
        }

        let definition = ToolDefinition(
            functionName: "tool_unclassified",
            command: "tool.unclassified",
            description: "",
            parametersSchema: .init([:] as [String: Any])
        )
        let provider = PermissionPolicyStubToolProvider(
            tool: definition,
            result: ToolResult(text: "should not execute")
        )
        let storage = TranscriptStorageProvider.provider(supportRootURL: supportRootURL)
        let session = ConversationSession(
            id: "main",
            configuration: .init(storage: storage, tools: provider)
        )
        session.addSessionToolPermissionRule(
            ToolPermissionRule(
                behavior: .deny,
                toolName: definition.functionName,
                matcher: .tool
            )
        )
        let client = SequencedStreamingStubChatClient(chunkSequences: [
            [.tool(.init(id: "tool-call-deny", name: definition.functionName, arguments: "{}"))],
            [.text("完成")],
        ])

        await session.submitPrompt(
            model: .init(client: client, capabilities: [.tool], contextLength: 32000, autoCompactEnabled: true),
            prompt: .init(text: "调用被拒绝的工具")
        )

        XCTAssertEqual(provider.executeCallCount, 0)
        let toolMessage = try XCTUnwrap(session.messages.last(where: { $0.role == .tool }))
        XCTAssertEqual(toolMessage.metadata[ToolMessageMetadata.toolCallState], ToolCallState.failed.rawValue)
        XCTAssertEqual(toolMessage.metadata[ToolMessageMetadata.permissionBehavior], ToolPermissionBehavior.deny.rawValue)
        XCTAssertEqual(toolMessage.metadata[ToolMessageMetadata.permissionReason], "permission_rule_deny_session")
        XCTAssertEqual(toolMessage.metadata[ToolMessageMetadata.permissionMessage], "Tool execution was denied by a remembered permission rule.")

        let toolResult = try XCTUnwrap(toolMessage.parts.compactMap { part -> ToolResultContentPart? in
            guard case let .toolResult(value) = part else { return nil }
            return value
        }.first)
        XCTAssertTrue(toolResult.result.contains("denied by a remembered permission rule"))
    }

    func testFileContentPartPersistsSourcePathAndTextAcrossReload() throws {
        let supportRootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: supportRootURL, withIntermediateDirectories: true)
        TranscriptStorageProvider.removeProvider(supportRootURL: supportRootURL)
        defer {
            TranscriptStorageProvider.removeProvider(supportRootURL: supportRootURL)
            try? FileManager.default.removeItem(at: supportRootURL)
        }

        let storage = TranscriptStorageProvider.provider(supportRootURL: supportRootURL)
        let session = ConversationSession(id: "main", configuration: .init(storage: storage))
        let sourceFileURL = supportRootURL.appendingPathComponent("workspace/report.md", isDirectory: false)
        try FileManager.default.createDirectory(at: sourceFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "# Report\n\nSaved content".write(to: sourceFileURL, atomically: true, encoding: .utf8)

        _ = session.appendNewMessage(role: .assistant) { message in
            message.parts = [
                .file(
                    FileContentPart(
                        mediaType: "text/markdown",
                        data: Data("# Report\n\nSaved content".utf8),
                        textContent: "# Report\n\nSaved content",
                        name: "report.md",
                        sourceFilePath: sourceFileURL.path
                    )
                ),
            ]
        }
        session.persistMessages()

        TranscriptStorageProvider.removeProvider(supportRootURL: supportRootURL)
        let reloadedStorage = TranscriptStorageProvider.provider(supportRootURL: supportRootURL)
        let reloadedMessages = reloadedStorage.messages(in: "main")

        let reloadedFile = try XCTUnwrap(reloadedMessages.first?.parts.compactMap { part -> FileContentPart? in
            guard case let .file(value) = part else { return nil }
            return value
        }.first)

        XCTAssertEqual(reloadedFile.name, "report.md")
        XCTAssertEqual(reloadedFile.mediaType, "text/markdown")
        XCTAssertEqual(reloadedFile.sourceFilePath, sourceFileURL.path)
        XCTAssertEqual(reloadedFile.textContent, "# Report\n\nSaved content")
    }

    func testFirstPersistedAssistantUpdateKeepsUserChainAcrossReload() throws {
        let supportRootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: supportRootURL, withIntermediateDirectories: true)
        TranscriptStorageProvider.removeProvider(supportRootURL: supportRootURL)
        defer {
            TranscriptStorageProvider.removeProvider(supportRootURL: supportRootURL)
            try? FileManager.default.removeItem(at: supportRootURL)
        }

        let storage = TranscriptStorageProvider.provider(supportRootURL: supportRootURL)
        let session = ConversationSession(id: "main", configuration: .init(storage: storage))

        let userMessage = session.appendNewMessage(role: .user) { message in
            message.textContent = "测试用户消息"
        }
        session.recordMessageInTranscript(userMessage)

        let assistantMessage = session.appendNewMessage(role: .assistant) { message in
            message.textContent = "第一次 assistant 更新落盘"
        }
        session.recordMessageInTranscript(assistantMessage)

        assistantMessage.textContent = "第二次 assistant 更新落盘"
        session.recordMessageInTranscript(assistantMessage)

        TranscriptStorageProvider.removeProvider(supportRootURL: supportRootURL)
        let reloadedStorage = TranscriptStorageProvider.provider(supportRootURL: supportRootURL)
        let reloadedMessages = reloadedStorage.messages(in: "main")

        XCTAssertEqual(reloadedMessages.map(\.role), [.user, .assistant])
        XCTAssertEqual(reloadedMessages.map(\.textContent), ["测试用户消息", "第二次 assistant 更新落盘"])
    }

    func testIncrementalAssistantUpdatesDoNotAppendDuplicateMessageEntriesBeforeFinalSync() throws {
        let supportRootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: supportRootURL, withIntermediateDirectories: true)
        TranscriptStorageProvider.removeProvider(supportRootURL: supportRootURL)
        defer {
            TranscriptStorageProvider.removeProvider(supportRootURL: supportRootURL)
            try? FileManager.default.removeItem(at: supportRootURL)
        }

        let storage = TranscriptStorageProvider.provider(supportRootURL: supportRootURL)
        let session = ConversationSession(id: "main", configuration: .init(storage: storage))

        let userMessage = session.appendNewMessage(role: .user) { message in
            message.textContent = "hello"
        }
        session.recordMessageInTranscript(userMessage)

        let assistantMessage = session.appendNewMessage(role: .assistant) { message in
            message.textContent = "draft"
        }
        session.recordMessageInTranscript(assistantMessage)

        assistantMessage.textContent = "draft 2"
        session.recordMessageInTranscript(assistantMessage)
        assistantMessage.textContent = "draft 3"
        session.recordMessageInTranscript(assistantMessage)

        let entries = try transcriptEntries(at: supportRootURL, sessionID: "main")
        let assistantEntries = entries.filter { ($0["type"] as? String) == MessageRole.assistant.rawValue }
        let assistantUUIDs = assistantEntries.compactMap { entry -> String? in
            (entry["message"] as? [String: Any])?["uuid"] as? String
        }
        XCTAssertEqual(assistantEntries.count, 1)
        XCTAssertEqual(Set(assistantUUIDs), [assistantMessage.id])
        XCTAssertEqual(
            ((assistantEntries.last?["message"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String,
            "draft 3"
        )

        TranscriptStorageProvider.removeProvider(supportRootURL: supportRootURL)
        let reloadedStorage = TranscriptStorageProvider.provider(supportRootURL: supportRootURL)
        let reloadedMessages = reloadedStorage.messages(in: "main")
        XCTAssertEqual(reloadedMessages.map(\.textContent), ["hello", "draft 3"])
    }

    func testPersistMessagesRewritesUpdatedMessageSnapshotWithoutDuplicatingMessageUUIDs() throws {
        let supportRootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: supportRootURL, withIntermediateDirectories: true)
        TranscriptStorageProvider.removeProvider(supportRootURL: supportRootURL)
        defer {
            TranscriptStorageProvider.removeProvider(supportRootURL: supportRootURL)
            try? FileManager.default.removeItem(at: supportRootURL)
        }

        let storage = TranscriptStorageProvider.provider(supportRootURL: supportRootURL)
        let session = ConversationSession(id: "main", configuration: .init(storage: storage))

        let userMessage = session.appendNewMessage(role: .user) { message in
            message.textContent = "hello"
        }
        session.recordMessageInTranscript(userMessage)

        let assistantMessage = session.appendNewMessage(role: .assistant) { message in
            message.textContent = "draft"
        }
        session.recordMessageInTranscript(assistantMessage)

        assistantMessage.textContent = "final answer"
        session.persistMessages()

        TranscriptStorageProvider.removeProvider(supportRootURL: supportRootURL)
        let reloadedStorage = TranscriptStorageProvider.provider(supportRootURL: supportRootURL)
        let reloadedMessages = reloadedStorage.messages(in: "main")
        XCTAssertEqual(reloadedMessages.map(\.textContent), ["hello", "final answer"])

        let entries = try transcriptEntries(at: supportRootURL, sessionID: "main")
        let assistantEntries = entries.filter { ($0["type"] as? String) == MessageRole.assistant.rawValue }
        let assistantUUIDs = assistantEntries.compactMap { entry -> String? in
            (entry["message"] as? [String: Any])?["uuid"] as? String
        }
        XCTAssertEqual(Set(assistantUUIDs).count, 1)
        XCTAssertEqual(assistantEntries.count, 1)
        XCTAssertEqual(
            ((assistantEntries.last?["message"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String,
            "final answer"
        )
    }

    func testDeleteRewritesTranscriptWithoutMessagesDeletedEntries() throws {
        let supportRootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: supportRootURL, withIntermediateDirectories: true)
        TranscriptStorageProvider.removeProvider(supportRootURL: supportRootURL)
        defer {
            TranscriptStorageProvider.removeProvider(supportRootURL: supportRootURL)
            try? FileManager.default.removeItem(at: supportRootURL)
        }

        let storage = TranscriptStorageProvider.provider(supportRootURL: supportRootURL)
        let session = ConversationSession(id: "main", configuration: .init(storage: storage))

        let user1 = session.appendNewMessage(role: .user) { message in
            message.textContent = "hello"
            message.createdAt = Date(timeIntervalSince1970: 1)
        }
        let assistant1 = session.appendNewMessage(role: .assistant) { message in
            message.textContent = "reply 1"
            message.createdAt = Date(timeIntervalSince1970: 2)
        }
        let user2 = session.appendNewMessage(role: .user) { message in
            message.textContent = "follow up"
            message.createdAt = Date(timeIntervalSince1970: 3)
        }
        let assistant2 = session.appendNewMessage(role: .assistant) { message in
            message.textContent = "reply 2"
            message.createdAt = Date(timeIntervalSince1970: 4)
        }
        session.persistMessages()
        storage.setTitle("Pinned title", for: "main")

        session.delete(assistant2.id)

        let entries = try transcriptEntries(at: supportRootURL, sessionID: "main")
        XCTAssertFalse(entries.contains(where: { ($0["type"] as? String) == "messages-deleted" }))

        let messageTexts = entries.compactMap { entry -> String? in
            ((entry["message"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String
        }
        XCTAssertEqual(messageTexts, ["hello", "reply 1", "follow up"])

        let customTitleEntry = try XCTUnwrap(entries.last(where: { ($0["type"] as? String) == "custom-title" }))
        XCTAssertEqual(customTitleEntry["customTitle"] as? String, "Pinned title")

        let lastPromptEntry = try XCTUnwrap(entries.last(where: { ($0["type"] as? String) == "last-prompt" }))
        XCTAssertEqual(lastPromptEntry["lastPrompt"] as? String, "follow up")

        TranscriptStorageProvider.removeProvider(supportRootURL: supportRootURL)
        let reloadedStorage = TranscriptStorageProvider.provider(supportRootURL: supportRootURL)
        let reloadedMessages = reloadedStorage.messages(in: "main")

        XCTAssertEqual(reloadedMessages.map(\.textContent), ["hello", "reply 1", "follow up"])
        XCTAssertEqual(reloadedStorage.title(for: "main"), "Pinned title")
    }

    func testCompactionPersistsBoundaryAndSummaryAsChainMessages() async throws {
        let supportRootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: supportRootURL, withIntermediateDirectories: true)
        TranscriptStorageProvider.removeProvider(supportRootURL: supportRootURL)
        defer {
            TranscriptStorageProvider.removeProvider(supportRootURL: supportRootURL)
            try? FileManager.default.removeItem(at: supportRootURL)
        }

        let storage = TranscriptStorageProvider.provider(supportRootURL: supportRootURL)
        let sessionID = "compact-main"
        let session = ConversationSession(id: sessionID, configuration: .init(storage: storage))

        for index in 0 ..< 8 {
            let role: MessageRole = index.isMultiple(of: 2) ? .user : .assistant
            let message = session.appendNewMessage(role: role)
            message.textContent = "message-\(index)"
            message.createdAt = Date(timeIntervalSince1970: TimeInterval(index))
        }
        session.persistMessages()

        let client = StubChatClient(responseText: "<summary>Compacted history.</summary>")
        let model = ConversationSession.Model(client: client, capabilities: [], contextLength: 32000, autoCompactEnabled: true)
        try await session.compactConversation(model: model)

        let entries = try transcriptEntries(at: supportRootURL, sessionID: sessionID)
        XCTAssertFalse(entries.contains(where: { ($0["type"] as? String) == "summary" }))

        let boundaryEntries = entries.filter {
            ($0["type"] as? String) == MessageRole.system.rawValue &&
                ($0["subtype"] as? String) == "compact_boundary"
        }
        XCTAssertEqual(boundaryEntries.count, 1)
        XCTAssertNotNil(boundaryEntries.first?["message"])

        let compactionSummaryMessages = entries.filter {
            ($0["type"] as? String) == MessageRole.user.rawValue &&
                (((($0["message"] as? [String: Any])?["metadata"] as? [String: Any])?["isCompactSummary"] as? String) == "true")
        }
        XCTAssertEqual(compactionSummaryMessages.count, 1)
        let compactionSummaryEntry = try XCTUnwrap(compactionSummaryMessages.first)
        let summaryText = (((compactionSummaryEntry["message"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        XCTAssertTrue(summaryText.contains("Compacted history."))
    }

    func testToggleToolResultCollapsePersistsAcrossReload() throws {
        let supportRootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: supportRootURL, withIntermediateDirectories: true)
        TranscriptStorageProvider.removeProvider(supportRootURL: supportRootURL)
        defer {
            TranscriptStorageProvider.removeProvider(supportRootURL: supportRootURL)
            try? FileManager.default.removeItem(at: supportRootURL)
        }

        let storage = TranscriptStorageProvider.provider(supportRootURL: supportRootURL)
        let session = ConversationSession(id: "main", configuration: .init(storage: storage))
        let toolCallID = "tool-call-1"

        _ = session.appendNewMessage(role: .assistant) { message in
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
            ]
        }
        let message = session.appendNewMessage(role: .tool) { message in
            message.parts = [
                .toolResult(
                    ToolResultContentPart(
                        toolCallID: toolCallID,
                        result: "file content",
                        isCollapsed: true
                    )
                ),
            ]
            message.metadata[ToolMessageMetadata.toolCallState] = ToolCallState.succeeded.rawValue
            message.metadata[ToolMessageMetadata.terminalResult] = "true"
        }
        session.persistMessages()

        session.toggleToolResultCollapse(for: message.id, toolCallID: toolCallID)

        TranscriptStorageProvider.removeProvider(supportRootURL: supportRootURL)
        let reloadedStorage = TranscriptStorageProvider.provider(supportRootURL: supportRootURL)
        let reloadedMessages = reloadedStorage.messages(in: "main")

        guard let reloadedMessage = reloadedMessages.first(where: { $0.role == .tool }) else {
            return XCTFail("Expected reloaded tool message")
        }
        guard let toolResult = reloadedMessage.parts.compactMap({ part -> ToolResultContentPart? in
            guard case let .toolResult(value) = part else { return nil }
            return value
        }).first else {
            return XCTFail("Expected reloaded tool result")
        }

        XCTAssertFalse(toolResult.isCollapsed)

        let entries = try transcriptEntries(at: supportRootURL, sessionID: "main")
        let assistantEntries = entries.filter { ($0["type"] as? String) == MessageRole.assistant.rawValue }
        XCTAssertEqual(assistantEntries.count, 1)
        let toolEntries = entries.filter { ($0["type"] as? String) == MessageRole.tool.rawValue }
        XCTAssertEqual(toolEntries.count, 1)
    }

    func testToggleReasoningCollapsePersistsAcrossReload() throws {
        let supportRootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: supportRootURL, withIntermediateDirectories: true)
        TranscriptStorageProvider.removeProvider(supportRootURL: supportRootURL)
        defer {
            TranscriptStorageProvider.removeProvider(supportRootURL: supportRootURL)
            try? FileManager.default.removeItem(at: supportRootURL)
        }

        let storage = TranscriptStorageProvider.provider(supportRootURL: supportRootURL)
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

        TranscriptStorageProvider.removeProvider(supportRootURL: supportRootURL)
        let reloadedStorage = TranscriptStorageProvider.provider(supportRootURL: supportRootURL)
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

        let entries = try transcriptEntries(at: supportRootURL, sessionID: "main")
        let assistantEntries = entries.filter { ($0["type"] as? String) == MessageRole.assistant.rawValue }
        XCTAssertEqual(assistantEntries.count, 1)
    }

    func testReloadedInterruptedSessionMarksOrphanRunningToolCallFailed() throws {
        let supportRootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: supportRootURL, withIntermediateDirectories: true)
        TranscriptStorageProvider.removeProvider(supportRootURL: supportRootURL)
        defer {
            TranscriptStorageProvider.removeProvider(supportRootURL: supportRootURL)
            try? FileManager.default.removeItem(at: supportRootURL)
        }

        let storage = TranscriptStorageProvider.provider(supportRootURL: supportRootURL)
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

        TranscriptStorageProvider.removeProvider(supportRootURL: supportRootURL)
        let reloadedStorage = TranscriptStorageProvider.provider(supportRootURL: supportRootURL)
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

        XCTAssertEqual(reloadedStorage.sessionExecutionState(for: "main"), .interrupted)
        XCTAssertEqual(toolCall.state, .failed)
    }

    func testReloadedInterruptedSessionShowsRetryAction() throws {
        let supportRootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: supportRootURL, withIntermediateDirectories: true)
        TranscriptStorageProvider.removeProvider(supportRootURL: supportRootURL)
        defer {
            TranscriptStorageProvider.removeProvider(supportRootURL: supportRootURL)
            try? FileManager.default.removeItem(at: supportRootURL)
        }

        let storage = TranscriptStorageProvider.provider(supportRootURL: supportRootURL)
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

        TranscriptStorageProvider.removeProvider(supportRootURL: supportRootURL)
        let reloadedStorage = TranscriptStorageProvider.provider(supportRootURL: supportRootURL)
        let reloadedSession = ConversationSession(id: "main", configuration: .init(storage: reloadedStorage))

        XCTAssertTrue(reloadedSession.showsInterruptedRetryAction)
    }

    func testLargeTranscriptFullReplayAppliesPreBoundaryMetadataLastWins() throws {
        let supportRootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: supportRootURL, withIntermediateDirectories: true)
        TranscriptStorageProvider.removeProvider(supportRootURL: supportRootURL)
        defer {
            TranscriptStorageProvider.removeProvider(supportRootURL: supportRootURL)
            try? FileManager.default.removeItem(at: supportRootURL)
        }

        let sessionID = "large-stream-recovery"
        let transcriptDir = supportRootURL
            .appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: transcriptDir, withIntermediateDirectories: true)

        let transcriptURL = transcriptDir.appendingPathComponent("\(sessionID).jsonl", isDirectory: false)

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
                text: largeText,
                timestamp: Self.testTimestamp(seconds: index)
            )
            try lines.append(encodeJSONLine(entry))
            previousEntryUUID = entryUUID
        }

        try lines.append(
            encodeJSONLine(
                TestTranscriptEntry.metadata(
                    sessionID: sessionID,
                    type: "custom-title",
                    customTitle: "Recovered Large Title",
                    lastPrompt: nil,
                    subtype: nil
                )
            )
        )
        try lines.append(
            encodeJSONLine(
                TestTranscriptEntry.metadata(
                    sessionID: sessionID,
                    type: "last-prompt",
                    customTitle: nil,
                    lastPrompt: "Recovered prompt from metadata",
                    subtype: nil
                )
            )
        )
        let boundaryUUID = UUID().uuidString
        try lines.append(
            encodeJSONLine(
                TestTranscriptEntry.boundary(
                    uuid: boundaryUUID,
                    sessionID: sessionID,
                    timestamp: Self.testTimestamp(seconds: 103)
                )
            )
        )

        let postUserEntryUUID = UUID().uuidString
        try lines.append(
            encodeJSONLine(
                TestTranscriptEntry.message(
                    entryUUID: postUserEntryUUID,
                    parentUUID: boundaryUUID,
                    sessionID: sessionID,
                    role: MessageRole.user.rawValue,
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
                    text: "after-boundary-assistant",
                    timestamp: Self.testTimestamp(seconds: 105)
                )
            )
        )

        try Data(lines.joined(separator: "\n").utf8).write(to: transcriptURL, options: .atomic)

        let attrs = try FileManager.default.attributesOfItem(atPath: transcriptURL.path)
        let fileSize = try XCTUnwrap(attrs[.size] as? Int)
        XCTAssertGreaterThan(fileSize, 5 * 1024 * 1024)

        let storage = TranscriptStorageProvider.provider(supportRootURL: supportRootURL)
        let recoveredMessages = storage.messages(in: sessionID)

        XCTAssertEqual(recoveredMessages.map(\.textContent), ["Conversation compacted.", "after-boundary-user", "after-boundary-assistant"])
        XCTAssertTrue(recoveredMessages.first?.isCompactBoundary == true)
        XCTAssertEqual(storage.sessionExecutionState(for: sessionID), .idle)
        XCTAssertEqual(storage.title(for: sessionID), "Recovered Large Title")

        let entries = try transcriptEntries(at: supportRootURL, sessionID: sessionID)
        let customTitleEntry = try XCTUnwrap(entries.last(where: { ($0["type"] as? String) == "custom-title" }))
        XCTAssertNil(customTitleEntry["sessionId"])
        XCTAssertNil(customTitleEntry["timestamp"])

        let lastPromptEntry = try XCTUnwrap(entries.last(where: { ($0["type"] as? String) == "last-prompt" }))
        XCTAssertNil(lastPromptEntry["sessionId"])
        XCTAssertNil(lastPromptEntry["timestamp"])

        let listedSession = try XCTUnwrap(storage.listSessions().first(where: { $0.key == sessionID }))
        XCTAssertEqual(listedSession.displayName, "Recovered Large Title")
        TranscriptStorageProvider.removeProvider(supportRootURL: supportRootURL)
        let reloadedStorage = TranscriptStorageProvider.provider(supportRootURL: supportRootURL)
        let reloadedSession = try XCTUnwrap(reloadedStorage.listSessions().first(where: { $0.key == sessionID }))
        XCTAssertEqual(reloadedSession.displayName, "Recovered Large Title")
        XCTAssertEqual(reloadedStorage.title(for: sessionID), "Recovered Large Title")
        XCTAssertEqual(reloadedStorage.sessionExecutionState(for: sessionID), .idle)
    }

    func testLargeTranscriptStreamLoadDoesNotRecoverPreBoundaryUpdatedSnapshot() throws {
        let supportRootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: supportRootURL, withIntermediateDirectories: true)
        TranscriptStorageProvider.removeProvider(supportRootURL: supportRootURL)
        defer {
            TranscriptStorageProvider.removeProvider(supportRootURL: supportRootURL)
            try? FileManager.default.removeItem(at: supportRootURL)
        }

        let sessionID = "large-stream-no-preboundary-patch"
        let transcriptDir = supportRootURL
            .appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: transcriptDir, withIntermediateDirectories: true)

        let transcriptURL = transcriptDir.appendingPathComponent("\(sessionID).jsonl", isDirectory: false)

        var lines: [String] = []
        var previousEntryUUID: String?
        let largePayloadSize = 512 * 1024
        let legacyAssistantMessageID = "legacy-assistant-message"

        for index in 0 ..< 12 {
            let role: MessageRole = index.isMultiple(of: 2) ? .user : .assistant
            let entryUUID = role == .assistant && index == 1 ? legacyAssistantMessageID : UUID().uuidString
            let largeText = "pre-boundary-\(index)-" + String(repeating: String(index % 10), count: largePayloadSize)
            let entry = TestTranscriptEntry.message(
                entryUUID: entryUUID,
                parentUUID: previousEntryUUID,
                sessionID: sessionID,
                role: role.rawValue,
                text: largeText,
                timestamp: Self.testTimestamp(seconds: index)
            )
            try lines.append(encodeJSONLine(entry))
            previousEntryUUID = entryUUID
        }

        let updatedSnapshotEntry = TestTranscriptEntry.message(
            entryUUID: legacyAssistantMessageID,
            parentUUID: previousEntryUUID,
            sessionID: sessionID,
            role: MessageRole.assistant.rawValue,
            text: "patched-pre-boundary-assistant",
            timestamp: Self.testTimestamp(seconds: 100)
        )
        try lines.append(encodeJSONLine(updatedSnapshotEntry))

        let boundaryUUID = UUID().uuidString
        try lines.append(
            encodeJSONLine(
                TestTranscriptEntry.boundary(
                    uuid: boundaryUUID,
                    sessionID: sessionID,
                    timestamp: Self.testTimestamp(seconds: 101)
                )
            )
        )

        let postUserEntryUUID = UUID().uuidString
        try lines.append(
            encodeJSONLine(
                TestTranscriptEntry.message(
                    entryUUID: postUserEntryUUID,
                    parentUUID: boundaryUUID,
                    sessionID: sessionID,
                    role: MessageRole.user.rawValue,
                    text: "after-boundary-user",
                    timestamp: Self.testTimestamp(seconds: 102)
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
                    text: "after-boundary-assistant",
                    timestamp: Self.testTimestamp(seconds: 103)
                )
            )
        )

        try Data(lines.joined(separator: "\n").utf8).write(to: transcriptURL, options: .atomic)

        let attrs = try FileManager.default.attributesOfItem(atPath: transcriptURL.path)
        let fileSize = try XCTUnwrap(attrs[.size] as? Int)
        XCTAssertGreaterThan(fileSize, 5 * 1024 * 1024)

        let storage = TranscriptStorageProvider.provider(supportRootURL: supportRootURL)
        let recoveredMessages = storage.messages(in: sessionID)

        XCTAssertEqual(recoveredMessages.map(\.textContent), ["Conversation compacted.", "after-boundary-user", "after-boundary-assistant"])
        XCTAssertTrue(recoveredMessages.first?.isCompactBoundary == true)
        XCTAssertFalse(recoveredMessages.contains(where: { $0.id == legacyAssistantMessageID }))
        XCTAssertFalse(recoveredMessages.contains(where: { $0.textContent == "patched-pre-boundary-assistant" }))
    }

    func testProtocolRecorderRoutesTranscriptMetadataIntoSessionLog() throws {
        let supportRootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: supportRootURL, withIntermediateDirectories: true)
        TranscriptStorageProvider.removeProvider(supportRootURL: supportRootURL)
        defer {
            TranscriptStorageProvider.removeProvider(supportRootURL: supportRootURL)
            try? FileManager.default.removeItem(at: supportRootURL)
        }

        let storage: any StorageProvider = TranscriptStorageProvider.provider(supportRootURL: supportRootURL)
        let generatedTitle = ConversationTitleMetadata(title: "Protocol Title", avatar: "🧪").storageValue
        storage.setTitle(generatedTitle, for: "main")
        XCTAssertEqual(storage.sessionExecutionState(for: "main"), .idle)
        XCTAssertEqual(ConversationTitleMetadata(storageValue: storage.title(for: "main"))?.title, "Protocol Title")

        TranscriptStorageProvider.removeProvider(supportRootURL: supportRootURL)
        let reloadedStorage = TranscriptStorageProvider.provider(supportRootURL: supportRootURL)

        XCTAssertEqual(reloadedStorage.sessionExecutionState(for: "main"), .idle)
        XCTAssertEqual(ConversationTitleMetadata(storageValue: reloadedStorage.title(for: "main"))?.title, "Protocol Title")
    }

    func testListSessionsFallsBackToLastPromptWithoutSynthesizingTitleMetadata() throws {
        let supportRootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: supportRootURL, withIntermediateDirectories: true)
        TranscriptStorageProvider.removeProvider(supportRootURL: supportRootURL)
        defer {
            TranscriptStorageProvider.removeProvider(supportRootURL: supportRootURL)
            try? FileManager.default.removeItem(at: supportRootURL)
        }

        let sessionID = "list-fallback-last-prompt"
        let transcriptDir = supportRootURL
            .appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: transcriptDir, withIntermediateDirectories: true)

        let transcriptURL = transcriptDir.appendingPathComponent("\(sessionID).jsonl", isDirectory: false)
        let lines = try [
            encodeJSONLine(
                TestTranscriptEntry.message(
                    entryUUID: UUID().uuidString,
                    parentUUID: nil,
                    sessionID: sessionID,
                    role: MessageRole.user.rawValue,
                    text: "请帮我总结一下最近这个模块的改动",
                    timestamp: Self.testTimestamp(seconds: 1)
                )
            ),
            encodeJSONLine(
                TestTranscriptEntry.metadata(
                    sessionID: sessionID,
                    type: "last-prompt",
                    customTitle: nil,
                    lastPrompt: "最近模块改动总结",
                    subtype: nil
                )
            ),
        ]
        try Data(lines.joined(separator: "\n").utf8).write(to: transcriptURL, options: .atomic)

        let storage = TranscriptStorageProvider.provider(supportRootURL: supportRootURL)
        let listedSession = try XCTUnwrap(storage.listSessions().first(where: { $0.key == sessionID }))
        XCTAssertEqual(listedSession.displayName, "最近模块改动总结")
        XCTAssertNil(storage.title(for: sessionID))

        TranscriptStorageProvider.removeProvider(supportRootURL: supportRootURL)
        let reloadedStorage = TranscriptStorageProvider.provider(supportRootURL: supportRootURL)
        let reloadedSession = try XCTUnwrap(reloadedStorage.listSessions().first(where: { $0.key == sessionID }))
        XCTAssertEqual(reloadedSession.displayName, "最近模块改动总结")
        XCTAssertNil(reloadedStorage.title(for: sessionID))
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

    private func transcriptEntries(at supportRootURL: URL, sessionID: String) throws -> [[String: Any]] {
        let transcriptURL = supportRootURL
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("\(sessionID).jsonl", isDirectory: false)
        let transcriptText = try String(contentsOf: transcriptURL, encoding: .utf8)
        return transcriptText
            .split(separator: "\n")
            .compactMap { line -> [String: Any]? in
                guard let data = line.data(using: .utf8) else { return nil }
                return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            }
    }
}

private final class PermissionPolicyStubToolProvider: ToolProvider, @unchecked Sendable {
    private let tool: ToolDefinition
    private let result: ToolResult
    private let lock = NSLock()
    private var storedExecuteCallCount = 0

    init(tool: ToolDefinition, result: ToolResult) {
        self.tool = tool
        self.result = result
    }

    var executeCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedExecuteCallCount
    }

    func enabledTools() async -> [ChatRequestBody.Tool] {
        [tool.chatRequestTool]
    }

    func findTool(for request: ToolRequest) async -> ToolExecutor? {
        request.name == tool.functionName ? tool : nil
    }

    func executeTool(_: ToolExecutor, parameters _: String) async throws -> ToolResult {
        lock.lock()
        storedExecuteCallCount += 1
        lock.unlock()
        return result
    }
}

private final class StreamingStubChatClient: ChatClient, @unchecked Sendable {
    let errorCollector = ErrorCollector.new()
    private let chunks: [ChatResponseChunk]
    private let lock = NSLock()
    private var capturedStreamingBodies: [ChatRequestBody] = []

    init(chunks: [ChatResponseChunk]) {
        self.chunks = chunks
    }

    var firstStreamingBody: ChatRequestBody? {
        lock.lock()
        defer { lock.unlock() }
        return capturedStreamingBodies.first
    }

    func chat(body _: ChatRequestBody) async throws -> ChatResponse {
        ChatResponse(reasoning: "", text: "", images: [], tools: [])
    }

    func streamingChat(body: ChatRequestBody) async throws -> AnyAsyncSequence<ChatResponseChunk> {
        lock.lock()
        capturedStreamingBodies.append(body)
        lock.unlock()
        return AsyncStream<ChatResponseChunk> { continuation in
            for chunk in chunks {
                continuation.yield(chunk)
            }
            continuation.finish()
        }.eraseToAnyAsyncSequence()
    }
}

private final class SequencedStreamingStubChatClient: ChatClient, @unchecked Sendable {
    let errorCollector = ErrorCollector.new()
    private let chunkSequences: [[ChatResponseChunk]]
    private let lock = NSLock()
    private var streamingCallIndex = 0

    init(chunkSequences: [[ChatResponseChunk]]) {
        self.chunkSequences = chunkSequences
    }

    func chat(body _: ChatRequestBody) async throws -> ChatResponse {
        ChatResponse(reasoning: "", text: "", images: [], tools: [])
    }

    func streamingChat(body _: ChatRequestBody) async throws -> AnyAsyncSequence<ChatResponseChunk> {
        lock.lock()
        let sequenceIndex = min(streamingCallIndex, max(chunkSequences.count - 1, 0))
        let chunks = chunkSequences.isEmpty ? [] : chunkSequences[sequenceIndex]
        streamingCallIndex += 1
        lock.unlock()

        return AsyncStream<ChatResponseChunk> { continuation in
            for chunk in chunks {
                continuation.yield(chunk)
            }
            continuation.finish()
        }.eraseToAnyAsyncSequence()
    }
}

private final class StubChatClient: ChatClient, @unchecked Sendable {
    let errorCollector = ErrorCollector.new()
    private let responseText: String

    init(responseText: String) {
        self.responseText = responseText
    }

    func chat(body _: ChatRequestBody) async throws -> ChatResponse {
        ChatResponse(reasoning: "", text: responseText, images: [], tools: [])
    }

    func streamingChat(body _: ChatRequestBody) async throws -> AnyAsyncSequence<ChatResponseChunk> {
        AsyncStream<ChatResponseChunk> { continuation in
            continuation.finish()
        }.eraseToAnyAsyncSequence()
    }
}

private enum TestTranscriptEntry: Encodable {
    case chain(TestChainTranscriptEntry)
    case customTitle(TestCustomTitleTranscriptEntry)
    case lastPrompt(TestLastPromptTranscriptEntry)

    func encode(to encoder: Encoder) throws {
        switch self {
        case let .chain(entry): try entry.encode(to: encoder)
        case let .customTitle(entry): try entry.encode(to: encoder)
        case let .lastPrompt(entry): try entry.encode(to: encoder)
        }
    }

    static func message(
        entryUUID: String,
        parentUUID: String?,
        sessionID: String,
        role: String,
        text: String,
        timestamp: String
    ) -> Self {
        .chain(
            TestChainTranscriptEntry(
                uuid: entryUUID,
                parentUuid: parentUUID,
                sessionId: sessionID,
                type: role,
                subtype: nil,
                timestamp: timestamp,
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
                )
            )
        )
    }

    static func boundary(uuid: String, sessionID: String, timestamp: String) -> Self {
        .chain(
            TestChainTranscriptEntry(
                uuid: uuid,
                parentUuid: nil,
                sessionId: sessionID,
                type: "system",
                subtype: "compact_boundary",
                timestamp: timestamp,
                message: TestTranscriptMessageRecord(
                    uuid: uuid,
                    role: MessageRole.system.rawValue,
                    timestamp: timestamp,
                    content: [
                        TestTranscriptContentBlock(
                            type: "text",
                            text: "Conversation compacted.",
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
                    metadata: ["subtype": "compact_boundary"]
                )
            )
        )
    }

    static func metadata(
        sessionID: String,
        type: String,
        customTitle: String?,
        lastPrompt: String?,
        subtype: String?
    ) -> Self {
        _ = sessionID
        _ = subtype
        switch type {
        case "custom-title":
            return .customTitle(TestCustomTitleTranscriptEntry(customTitle: customTitle ?? ""))
        case "last-prompt":
            return .lastPrompt(TestLastPromptTranscriptEntry(lastPrompt: lastPrompt ?? ""))
        default:
            preconditionFailure("Unsupported metadata type: \(type)")
        }
    }
}

private struct TestChainTranscriptEntry: Encodable {
    let uuid: String
    let parentUuid: String?
    let sessionId: String
    let type: String
    let subtype: String?
    let timestamp: String
    let message: TestTranscriptMessageRecord
}

private struct TestCustomTitleTranscriptEntry: Encodable {
    let type = "custom-title"
    let customTitle: String
}

private struct TestLastPromptTranscriptEntry: Encodable {
    let type = "last-prompt"
    let lastPrompt: String
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
