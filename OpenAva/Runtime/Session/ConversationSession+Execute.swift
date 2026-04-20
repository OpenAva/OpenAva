import ChatClient
import ChatUI
import Foundation
import OSLog

private let logger = Logger(subsystem: "com.day1-labs.openava", category: "chat.stop.execute")

public extension ConversationSession {
    /// Input object representing what the user typed/attached.
    struct PromptInput: Sendable {
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

    func submitPrompt(
        model: ConversationSession.Model,
        prompt: PromptInput,
        reservationGeneration: Int? = nil
    ) async -> Bool {
        logger.notice(
            "submit prompt requested session=\(self.id, privacy: .public) textLength=\(prompt.text.count) attachments=\(prompt.attachments.count) queryActiveBefore=\(String(self.isQueryActive), privacy: .public)"
        )
        lastSubmittedPromptInput = prompt
        showsInterruptedRetryAction = false
        var accepted = false
        var effectiveReservationGeneration = reservationGeneration

        cancelCurrentTask { [self] in
            if effectiveReservationGeneration == nil {
                effectiveReservationGeneration = queryGuard.reserve()
            }
            guard let effectiveReservationGeneration,
                  let generation = queryGuard.tryStart(expectedGeneration: effectiveReservationGeneration)
            else {
                logger.notice("submit prompt ignored session=\(self.id, privacy: .public) reason=query_already_active")
                return
            }
            accepted = true
            currentTaskGeneration = generation

            let bgToken = sessionDelegate?.beginBackgroundTask { [weak self] in
                Task { @MainActor [weak self] in
                    self?.currentTask?.cancel()
                }
            }

            currentTask = Task { @MainActor [generation] in
                logger.notice("task started session=\(self.id, privacy: .public)")
                sessionDelegate?.sessionExecutionDidStart(for: id)

                defer {
                    if let bgToken {
                        sessionDelegate?.endBackgroundTask(bgToken)
                    }
                }

                setLoadingState(nil)

                do {
                    let result = try await queryEngine.submitPrompt(prompt, model: model)
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
                        "submit prompt interrupted session=\(self.id, privacy: .public) reason=\(interruptReason, privacy: .public)"
                    )
                    sessionDelegate?.sessionExecutionDidInterrupt(for: id, reason: interruptReason)
                } catch {
                    showsInterruptedRetryAction = false
                    setLoadingState(nil)
                    logger.error(
                        "submit prompt failed session=\(self.id, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
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
                _ = self.queryGuard.end(generation)
                if self.currentTaskGeneration == generation {
                    self.currentTask = nil
                    self.currentTaskGeneration = nil
                }
            }
        }

        guard accepted else { return false }
        let task = currentTask
        await task?.value
        return true
    }

    /// Retry the last interrupted turn after user explicitly taps retry.
    func retryInterruptedPromptSubmission() {
        guard showsInterruptedRetryAction,
              !isQueryActive,
              let model = models.chat,
              let lastSubmittedPromptInput,
              let reservationGeneration = queryGuard.reserve()
        else {
            return
        }
        showsInterruptedRetryAction = false
        Task { @MainActor [weak self] in
            guard let self else { return }
            _ = await self.submitPrompt(
                model: model,
                prompt: lastSubmittedPromptInput,
                reservationGeneration: reservationGeneration
            )
        }
    }
}
