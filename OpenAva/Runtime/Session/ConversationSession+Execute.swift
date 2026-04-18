import ChatClient
import ChatUI
import Foundation
import OSLog
import UIKit

private let logger = Logger(subsystem: "com.day1-labs.openava", category: "chat.stop.execute")

private let queryExecutionLogger = Logger(subsystem: "com.day1-labs.openava", category: "chat.stop.query-engine")

public extension ConversationSession {
    /// Input object representing what the user typed/attached.
    struct UserInput: Sendable {
        public enum Source: String, Sendable {
            case user
            case heartbeat
        }

        public static let sourceMetadataKey = "turnSource"
        public static let requestTextMetadataKey = "turnRequestText"

        public var text: String
        public var displayText: String?
        public var attachments: [ContentPart]
        public var source: Source
        public var metadata: [String: String]

        public init(
            text: String = "",
            displayText: String? = nil,
            attachments: [ContentPart] = [],
            source: Source = .user,
            metadata: [String: String] = [:]
        ) {
            self.text = text
            self.displayText = AppConfig.nonEmpty(displayText)
            self.attachments = attachments
            self.source = source

            var normalizedMetadata = metadata
            normalizedMetadata[Self.sourceMetadataKey] = source.rawValue
            self.metadata = normalizedMetadata
        }

        var transcriptText: String {
            displayText ?? text
        }

        var transcriptMetadata: [String: String] {
            var result = metadata
            if transcriptText != text {
                result[Self.requestTextMetadataKey] = text
            }
            return result
        }
    }

    /// Execute inference for the given user input.
    func runInference(
        model: ConversationSession.Model,
        messageListView: MessageListView,
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
                Task { @MainActor in
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

                await messageListView.loading()

                await executeInference(
                    model: model,
                    messageListView: messageListView,
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
        messageListView: MessageListView,
        input: UserInput
    ) async {
        logger.notice(
            "executeInference entered session=\(self.id, privacy: .public) cancelled=\(String(Task.isCancelled), privacy: .public)"
        )
        // Prevent screen lock
        sessionDelegate?.preventIdleTimer()
        var queryResult: QueryResult?
        do {
            for try await event in submitQuery(input, model: model, maxTurns: 32, canUseTool: allowAllTools) {
                switch event {
                case let .loading(status):
                    logger.debug(
                        "query loading session=\(self.id, privacy: .public) status=\(status ?? "", privacy: .public) cancelled=\(String(Task.isCancelled), privacy: .public)"
                    )
                    await updateLoadingState(in: messageListView, status: status)
                case let .refresh(scrolling):
                    await renderMessages(in: messageListView, scrolling: scrolling)
                case let .result(result):
                    logger.notice(
                        "query result session=\(self.id, privacy: .public) finishReason=\(String(describing: result.finishReason), privacy: .public) interruptReason=\(result.interruptReason ?? "nil", privacy: .public)"
                    )
                    queryResult = result
                }
            }

            await renderMessages(in: messageListView)

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
            let interruptReason = queryResult?.interruptReason ?? consumeInterruptReason().rawValue
            logger.notice(
                "executeInference interrupted session=\(self.id, privacy: .public) reason=\(interruptReason, privacy: .public)"
            )
            sessionDelegate?.sessionExecutionDidInterrupt(for: id, reason: interruptReason)
        } catch {
            showsInterruptedRetryAction = false
            logger.error(
                "executeInference failed session=\(self.id, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
            _ = appendNewMessage(role: .assistant) { msg in
                msg.textContent = "```\n\(error.localizedDescription)\n```"
            }
            await renderMessages(in: messageListView)
            sessionDelegate?.sessionExecutionDidFinish(
                for: id,
                success: false,
                errorDescription: error.localizedDescription
            )
        }

        stopThinkingForAll()
        await renderMessages(in: messageListView)
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

    private func updateLoadingState(in messageListView: MessageListView, status: String?) async {
        if let status,
           !status.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty
        {
            await messageListView.loading(with: status)
        } else {
            await messageListView.loading()
        }
    }

    private func renderMessages(in messageListView: MessageListView, scrolling: Bool = true) async {
        await messageListView.renderAndStopLoading(messages: messages, scrolling: scrolling)
        notifyMessagesDidChange(scrolling: scrolling)
    }

    private func submitQuery(
        _ input: UserInput,
        model: ConversationSession.Model,
        maxTurns: Int,
        canUseTool: @escaping CanUseTool
    ) -> AsyncThrowingStream<QueryEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                do {
                    queryExecutionLogger.notice(
                        "stream producer started session=\(self.id, privacy: .public) cancelled=\(String(Task.isCancelled), privacy: .public)"
                    )
                    let capabilities = model.capabilities

                    var requestMessages = self.buildRequestMessages(capabilities: capabilities)

                    let userMessage = self.appendNewMessage(role: .user) { message in
                        message.textContent = input.transcriptText
                        for attachment in input.attachments {
                            message.parts.append(attachment)
                        }

                        for (key, value) in input.transcriptMetadata {
                            message.metadata[key] = value
                        }
                    }
                    continuation.yield(.refresh(scrolling: true))
                    self.recordMessageInTranscript(userMessage)

                    requestMessages.append(
                        self.buildUserRequestMessage(
                            text: input.text,
                            attachments: input.attachments,
                            capabilities: capabilities
                        )
                    )

                    await self.injectSystemPrompt(&requestMessages, capabilities: capabilities)

                    var tools: [ChatRequestBody.Tool]?
                    if capabilities.contains(.tool), let toolProvider = self.toolProvider {
                        let enabledTools = await toolProvider.enabledTools()
                        if !enabledTools.isEmpty {
                            tools = enabledTools
                        }
                    }

                    let toolUseContext = ToolExecutionContext(
                        session: self,
                        toolProvider: self.toolProvider,
                        canUseTool: canUseTool
                    )

                    let result = try await query(
                        session: self,
                        model: model,
                        requestMessages: &requestMessages,
                        tools: tools,
                        toolUseContext: toolUseContext,
                        maxTurns: max(1, maxTurns),
                        continuation: continuation
                    )
                    continuation.yield(.result(result))
                    queryExecutionLogger.notice(
                        "stream producer finishing normally session=\(self.id, privacy: .public)"
                    )
                    continuation.finish()
                } catch is CancellationError {
                    queryExecutionLogger.notice(
                        "stream producer cancelled session=\(self.id, privacy: .public)"
                    )
                    continuation.finish(throwing: CancellationError())
                } catch {
                    queryExecutionLogger.error(
                        "stream producer failed session=\(self.id, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                    )
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { @Sendable termination in
                queryExecutionLogger.notice(
                    "stream termination session=\(self.id, privacy: .public) reason=\(String(describing: termination), privacy: .public)"
                )
                task.cancel()
            }
        }
    }

    /// Retry the last interrupted turn after user explicitly taps retry.
    func retryInterruptedInference(messageListView: MessageListView) {
        guard showsInterruptedRetryAction,
              currentTask == nil,
              let model = models.chat,
              let lastSubmittedInput
        else {
            return
        }
        showsInterruptedRetryAction = false
        runInference(model: model, messageListView: messageListView, input: lastSubmittedInput) {}
    }
}
