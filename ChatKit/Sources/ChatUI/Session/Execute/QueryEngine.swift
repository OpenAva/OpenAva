import ChatClient
import Foundation

@MainActor
final class QueryEngine {
    let config: QueryEngineConfig

    init(config: QueryEngineConfig) {
        self.config = config
    }

    func submitMessage(_ input: ConversationSession.UserInput) -> AsyncThrowingStream<QueryEvent, Error> {
        AsyncThrowingStream { continuation in
            Task { @MainActor in
                do {
                    let result = try await submitMessage(input, continuation: continuation)
                    continuation.yield(.result(result))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func submitMessage(
        _ input: ConversationSession.UserInput,
        continuation: AsyncThrowingStream<QueryEvent, Error>.Continuation
    ) async throws -> QueryResult {
        let session = config.session
        let model = config.model
        let messageListView = config.messageListView
        let modelCapabilities = model.capabilities

        session.persistMessages()

        var requestMessages = session.buildRequestMessages(capabilities: modelCapabilities)

        _ = session.appendNewMessage(role: .user) { message in
            message.textContent = input.text
            for attachment in input.attachments {
                message.parts.append(attachment)
            }
        }
        continuation.yield(.refresh(scrolling: true))
        session.persistMessages()

        let latestUserMessage = session.buildUserRequestMessage(
            text: input.text,
            attachments: input.attachments,
            capabilities: modelCapabilities
        )
        requestMessages.append(latestUserMessage)

        await session.injectSystemPrompt(&requestMessages, capabilities: modelCapabilities)

        var tools: [ChatRequestBody.Tool]? = nil
        if modelCapabilities.contains(.tool), let toolProvider = session.toolProvider {
            await toolProvider.prepareForConversation()
            let toolDefinitions = await toolProvider.enabledTools()
            if !toolDefinitions.isEmpty {
                tools = toolDefinitions
            }
        }

        let toolUseContext = ToolUseContext(
            session: session,
            toolProvider: session.toolProvider,
            messageListView: messageListView,
            canUseTool: config.canUseTool
        )

        return try await query(
            session: session,
            model: model,
            requestMessages: &requestMessages,
            tools: tools,
            toolUseContext: toolUseContext,
            maxTurns: config.maxTurns,
            continuation: continuation
        )
    }
}
