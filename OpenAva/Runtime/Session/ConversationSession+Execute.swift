import ChatClient
import ChatUI
import Foundation
import OSLog
import UIKit

private let logger = Logger(subsystem: "com.day1-labs.openava", category: "chat.stop.execute")

private let queryExecutionLogger = Logger(subsystem: "com.day1-labs.openava", category: "chat.stop.query-engine")

private struct PreparedQueryExecution {
    var requestMessages: [ChatRequestBody.Message]
    let tools: [ChatRequestBody.Tool]?
    let toolUseContext: ToolExecutionContext
}

public extension ConversationSession {
    /// Input object representing what the user typed/attached.
    struct UserInput: Sendable {
        public enum Source: String, Sendable {
            case user
            case heartbeat
        }

        public static let sourceMetadataKey = "turnSource"

        public var text: String
        public var attachments: [ContentPart]
        public var source: Source
        public var metadata: [String: String]

        public init(
            text: String = "",
            attachments: [ContentPart] = [],
            source: Source = .user,
            metadata: [String: String] = [:]
        ) {
            self.text = text
            self.attachments = attachments
            self.source = source

            var normalizedMetadata = metadata
            normalizedMetadata[Self.sourceMetadataKey] = source.rawValue
            self.metadata = normalizedMetadata
        }
    }

    /// Execute inference for the given user input.
    func runInference(
        model: ConversationSession.Model,
        input: UserInput,
        completion: @escaping @Sendable () -> Void
    ) {
        logger.notice(
            "runInference requested session=\(self.id, privacy: .public) textLength=\(input.text.count) attachments=\(input.attachments.count) hasTaskBefore=\(String(self.currentTask != nil), privacy: .public)"
        )
        lastSubmittedInput = input
        showsInterruptedRetryAction = false
        cancelCurrentTask { [self] in
            let bgToken = sessionDelegate?.beginBackgroundTask { [weak self] in
                Task { @MainActor [weak self] in
                    self?.currentTask?.cancel()
                }
            }

            currentTask = Task { @MainActor in
                logger.notice("task started session=\(self.id, privacy: .public)")
                ConversationSessionManager.shared.markSessionExecuting(self)
                sessionDelegate?.sessionExecutionDidStart(for: id)

                defer {
                    if let bgToken {
                        sessionDelegate?.endBackgroundTask(bgToken)
                    }
                }

                setLoadingState(nil)

                await executeInference(
                    model: model,
                    input: input
                )

                logger.notice(
                    "task finished session=\(self.id, privacy: .public) cancelled=\(String(Task.isCancelled), privacy: .public)"
                )
                self.currentTask = nil
                ConversationSessionManager.shared.markSessionCompleted(self)
                completion()
            }
        }
    }

    private func executeInference(
        model: ConversationSession.Model,
        input: UserInput
    ) async {
        logger.notice(
            "executeInference entered session=\(self.id, privacy: .public) cancelled=\(String(Task.isCancelled), privacy: .public)"
        )
        // Prevent screen lock
        sessionDelegate?.preventIdleTimer()
        var queryResult: QueryResult?
        do {
            queryExecutionLogger.notice(
                "query execution started session=\(self.id, privacy: .public) cancelled=\(String(Task.isCancelled), privacy: .public)"
            )
            var execution = await prepareQueryExecution(model: model, input: input, in: self)
            let eventSink = makeQueryEventSink(for: self)

            let result = try await query(
                session: self,
                model: model,
                requestMessages: &execution.requestMessages,
                tools: execution.tools,
                toolUseContext: execution.toolUseContext,
                maxTurns: 32,
                eventSink: eventSink
            )
            queryResult = result
            logger.notice(
                "query result session=\(self.id, privacy: .public) finishReason=\(String(describing: result.finishReason), privacy: .public) interruptReason=\(result.interruptReason ?? "nil", privacy: .public)"
            )
            queryExecutionLogger.notice(
                "query execution finished normally session=\(self.id, privacy: .public)"
            )

            notifyMessagesDidChange()
            setLoadingState(nil)

            await updateTitle()
            showsInterruptedRetryAction = false
            sessionDelegate?.sessionExecutionDidFinish(
                for: id,
                success: queryResult?.finishReason != .error,
                errorDescription: queryResult?.finishReason == .error ? String.localized("Query execution failed.") : nil
            )
        } catch is CancellationError {
            // Surface a manual retry affordance instead of auto-resume.
            showsInterruptedRetryAction = true
            setLoadingState(nil)
            let interruptReason = queryResult?.interruptReason ?? consumeInterruptReason().rawValue
            logger.notice(
                "executeInference interrupted session=\(self.id, privacy: .public) reason=\(interruptReason, privacy: .public)"
            )
            sessionDelegate?.sessionExecutionDidInterrupt(for: id, reason: interruptReason)
        } catch {
            showsInterruptedRetryAction = false
            setLoadingState(nil)
            logger.error(
                "executeInference failed session=\(self.id, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
            _ = appendNewMessage(role: .assistant) { msg in
                msg.textContent = "```\n\(error.localizedDescription)\n```"
            }
            notifyMessagesDidChange()
            sessionDelegate?.sessionExecutionDidFinish(
                for: id,
                success: false,
                errorDescription: error.localizedDescription
            )
        }

        stopThinkingForAll()
        notifyMessagesDidChange()
        persistMessages()
        let persistedMessages = messages
        let sessionID = id

        Task { [weak self, persistedMessages, sessionID] in
            await self?.sessionDelegate?.sessionDidPersistMessages(persistedMessages, for: sessionID)
        }

        sessionDelegate?.allowIdleTimer()
        logger.notice(
            "executeInference exited session=\(self.id, privacy: .public) cancelled=\(String(Task.isCancelled), privacy: .public)"
        )
    }

    /// Retry the last interrupted turn after user explicitly taps retry.
    func retryInterruptedInference() {
        guard showsInterruptedRetryAction,
              currentTask == nil,
              let model = models.chat,
              let lastSubmittedInput
        else {
            return
        }
        showsInterruptedRetryAction = false
        runInference(model: model, input: lastSubmittedInput) {}
    }
}

@MainActor
private func prepareQueryExecution(
    model: ConversationSession.Model,
    input: ConversationSession.UserInput,
    in session: ConversationSession
) async -> PreparedQueryExecution {
    let userMessage = session.appendNewMessage(role: .user) { message in
        message.textContent = input.text
        for attachment in input.attachments {
            message.parts.append(attachment)
        }

        for (key, value) in input.metadata {
            message.metadata[key] = value
        }
    }
    session.notifyMessagesDidChange(scrolling: true)
    session.recordMessageInTranscript(userMessage)

    let capabilities = model.capabilities
    let requestMessages = await session.buildExecutionRequestMessages(capabilities: capabilities)
    let tools = await enabledTools(for: capabilities, in: session)
    let toolUseContext = ToolExecutionContext(
        session: session,
        toolProvider: session.toolProvider,
        canUseTool: allowAllTools
    )
    return PreparedQueryExecution(
        requestMessages: requestMessages,
        tools: tools,
        toolUseContext: toolUseContext
    )
}

@MainActor
private func enabledTools(
    for capabilities: Set<ModelCapability>,
    in session: ConversationSession
) async -> [ChatRequestBody.Tool]? {
    guard capabilities.contains(.tool), let toolProvider = session.toolProvider else {
        return nil
    }
    let enabledTools = await toolProvider.enabledTools()
    return enabledTools.isEmpty ? nil : enabledTools
}

@MainActor
private func makeQueryEventSink(for session: ConversationSession) -> QueryEventSink {
    QueryEventSink(
        loading: { status in
            logger.debug(
                "query loading session=\(session.id, privacy: .public) status=\(status ?? "", privacy: .public) cancelled=\(String(Task.isCancelled), privacy: .public)"
            )
            session.setLoadingState(status)
        },
        refresh: { scrolling in
            session.notifyMessagesDidChange(scrolling: scrolling)
        }
    )
}
