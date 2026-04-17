import ChatClient
import ChatUI
import Foundation
import OSLog
import UIKit

private let logger = Logger(subsystem: "com.day1-labs.openava", category: "chat.stop.execute")

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

    internal func requestUpdate(view: MessageListView, scrolling: Bool = true) async {
        await view.stopLoading()
        notifyMessagesDidChange(scrolling: scrolling)
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
        let queryEngine = QueryEngine(config: .init(
            session: self,
            model: model,
            messageListView: messageListView
        ))

        var queryResult: QueryResult?
        do {
            for try await event in queryEngine.submitMessage(input) {
                switch event {
                case let .loading(status):
                    logger.debug(
                        "query loading session=\(self.id, privacy: .public) status=\(status ?? "", privacy: .public) cancelled=\(String(Task.isCancelled), privacy: .public)"
                    )
                    if let status,
                       !status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    {
                        await messageListView.loading(with: status)
                    } else {
                        await messageListView.loading()
                    }
                case let .refresh(scrolling):
                    await requestUpdate(view: messageListView, scrolling: scrolling)
                case let .result(result):
                    logger.notice(
                        "query result session=\(self.id, privacy: .public) finishReason=\(String(describing: result.finishReason), privacy: .public) interruptReason=\(result.interruptReason ?? "nil", privacy: .public)"
                    )
                    queryResult = result
                }
            }

            await requestUpdate(view: messageListView)

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
            await requestUpdate(view: messageListView)
            sessionDelegate?.sessionExecutionDidFinish(
                for: id,
                success: false,
                errorDescription: error.localizedDescription
            )
        }

        stopThinkingForAll()
        await requestUpdate(view: messageListView)
        // Final persist: flush the write queue to guarantee all buffered
        // entries are on disk before we signal completion.
        persistMessages()
        flushTranscript()
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
