import ChatClient
import ChatUI
import Foundation
import OSLog

private let logger = Logger(subsystem: "com.day1-labs.openava", category: "chat.stop.execute")

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

    func submitMessage(
        model: ConversationSession.Model,
        input: UserInput,
        completion: @escaping @Sendable () -> Void
    ) {
        logger.notice(
            "submit message requested session=\(self.id, privacy: .public) textLength=\(input.text.count) attachments=\(input.attachments.count) hasTaskBefore=\(String(self.currentTask != nil), privacy: .public)"
        )
        lastSubmittedMessageInput = input
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

                do {
                    let result = try await queryEngine.submitMessage(input, model: model)
                    showsInterruptedRetryAction = false
                    sessionDelegate?.sessionExecutionDidFinish(
                        for: id,
                        success: result.finishReason != .error,
                        errorDescription: result.finishReason == .error ? String.localized("Query execution failed.") : nil
                    )
                } catch is CancellationError {
                    showsInterruptedRetryAction = true
                    setLoadingState(nil)
                    let interruptReason = consumeInterruptReason().rawValue
                    logger.notice(
                        "submit message interrupted session=\(self.id, privacy: .public) reason=\(interruptReason, privacy: .public)"
                    )
                    sessionDelegate?.sessionExecutionDidInterrupt(for: id, reason: interruptReason)
                } catch {
                    showsInterruptedRetryAction = false
                    setLoadingState(nil)
                    logger.error(
                        "submit message failed session=\(self.id, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
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

                logger.notice(
                    "task finished session=\(self.id, privacy: .public) cancelled=\(String(Task.isCancelled), privacy: .public)"
                )
                self.currentTask = nil
                ConversationSessionManager.shared.markSessionCompleted(self)
                completion()
            }
        }
    }

    /// Retry the last interrupted turn after user explicitly taps retry.
    func retryInterruptedMessageSubmission() {
        guard showsInterruptedRetryAction,
              currentTask == nil,
              let model = models.chat,
              let lastSubmittedMessageInput
        else {
            return
        }
        showsInterruptedRetryAction = false
        submitMessage(model: model, input: lastSubmittedMessageInput) {}
    }
}
