import ChatClient
import ChatUI
import Foundation
import OSLog

private let queryEngineLogger = Logger(subsystem: "com.day1-labs.openava", category: "chat.stop.query-engine")

@MainActor
final class QueryEngine {
    let session: ConversationSession

    init(session: ConversationSession) {
        self.session = session
    }

    func submitPrompt(
        _ prompt: ConversationSession.PromptInput,
        model: ConversationSession.Model
    ) async throws -> QueryResult {
        queryEngineLogger.notice(
            "query engine submit prompt session=\(self.session.id, privacy: .public) cancelled=\(String(Task.isCancelled), privacy: .public)"
        )

        self.sessionDelegate?.preventIdleTimer()
        defer {
            self.session.stopThinkingForAll()
            self.session.notifyMessagesDidChange()
            self.session.persistMessages()
            let persistedMessages = self.session.messages
            let sessionID = self.session.id

            Task { [weak sessionDelegate = self.sessionDelegate] in
                await sessionDelegate?.sessionDidPersistMessages(persistedMessages, for: sessionID)
            }

            self.sessionDelegate?.allowIdleTimer()
            queryEngineLogger.notice(
                "query engine submit prompt exited session=\(self.session.id, privacy: .public) cancelled=\(String(Task.isCancelled), privacy: .public)"
            )
        }

        var requestMessages = await prepareRequestMessages(for: prompt, model: model)
        let tools = await loadTools(for: model.capabilities)
        let toolUseContext = ToolExecutionContext(
            session: session,
            toolProvider: session.toolProvider,
            canUseTool: allowAllTools
        )

        let result = try await query(
            session: self.session,
            model: model,
            requestMessages: &requestMessages,
            tools: tools,
            toolUseContext: toolUseContext,
            maxTurns: 32
        )

        self.session.notifyMessagesDidChange()
        self.session.setLoadingState(nil)
        await self.session.updateTitle()
        return result
    }

    private var sessionDelegate: SessionDelegate? {
        session.sessionDelegate
    }

    private func prepareRequestMessages(
        for prompt: ConversationSession.PromptInput,
        model: ConversationSession.Model
    ) async -> [ChatRequestBody.Message] {
        let userMessage = session.appendNewMessage(role: .user) { message in
            message.textContent = prompt.text
            for attachment in prompt.attachments {
                message.parts.append(attachment)
            }

            for (key, value) in prompt.metadata {
                message.metadata[key] = value
            }
        }
        session.notifyMessagesDidChange(scrolling: true)
        session.recordMessageInTranscript(userMessage)

        let capabilities = model.capabilities
        return await session.buildMessages(capabilities: capabilities)
    }

    private func loadTools(
        for capabilities: Set<ModelCapability>
    ) async -> [ChatRequestBody.Tool]? {
        guard capabilities.contains(.tool), let toolProvider = session.toolProvider else {
            return nil
        }
        let enabledTools = await toolProvider.enabledTools()
        return enabledTools.isEmpty ? nil : enabledTools
    }
}
