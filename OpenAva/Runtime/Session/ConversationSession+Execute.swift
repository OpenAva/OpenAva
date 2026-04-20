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
        prompt: PromptInput
    ) async -> Bool {
        guard let task = beginPromptSubmission(
            model: model,
            prompt: prompt,
            usingExistingReservation: false
        ) else {
            return false
        }
        await task.value
        return true
    }

    /// Starts prompt execution immediately and returns once the turn has been
    /// accepted (without waiting for model completion).
    @discardableResult
    func submitPromptWithoutWaiting(
        model: ConversationSession.Model,
        prompt: PromptInput,
        usingExistingReservation: Bool = false
    ) -> Bool {
        beginPromptSubmission(
            model: model,
            prompt: prompt,
            usingExistingReservation: usingExistingReservation
        ) != nil
    }

    private func beginPromptSubmission(
        model: ConversationSession.Model,
        prompt: PromptInput,
        usingExistingReservation: Bool
    ) -> Task<Void, Never>? {
        logger.notice(
            "submit prompt requested session=\(self.id, privacy: .public) textLength=\(prompt.text.count) attachments=\(prompt.attachments.count) queryActiveBefore=\(String(self.isQueryActive), privacy: .public)"
        )
        lastSubmittedPromptInput = prompt
        showsInterruptedRetryAction = false
        var taskToAwait: Task<Void, Never>?

        cancelCurrentTask { [self] in
            if !usingExistingReservation {
                guard queryGuard.reserve() else {
                    logger.notice("submit prompt ignored session=\(self.id, privacy: .public) reason=query_already_active")
                    return
                }
            }

            guard let generation = queryGuard.tryStart()
            else {
                if !usingExistingReservation {
                    queryGuard.cancelReservation()
                }
                logger.notice("submit prompt ignored session=\(self.id, privacy: .public) reason=query_already_active")
                return
            }

            let userMessage = appendPromptMessage(prompt)
            notifyMessagesDidChange(scrolling: true)
            recordMessageInTranscript(userMessage)

            let task = Task { @MainActor [generation] in
                logger.notice("task started session=\(self.id, privacy: .public)")
                sessionDelegate?.preventIdleTimer()
                sessionDelegate?.sessionExecutionDidStart(for: id)

                let bgToken = sessionDelegate?.beginBackgroundTask { [weak self] in
                    Task { @MainActor [weak self] in
                        self?.currentTask?.cancel()
                    }
                }

                defer {
                    if let bgToken {
                        sessionDelegate?.endBackgroundTask(bgToken)
                    }

                    stopThinkingForAll()
                    notifyMessagesDidChange()
                    persistMessages()

                    let persistedMessages = messages
                    let sessionID = id
                    Task { [sessionDelegate = self.sessionDelegate] in
                        await sessionDelegate?.sessionDidPersistMessages(persistedMessages, for: sessionID)
                    }

                    sessionDelegate?.allowIdleTimer()
                    logger.notice(
                        "task finished session=\(self.id, privacy: .public) cancelled=\(String(Task.isCancelled), privacy: .public)"
                    )

                    if self.queryGuard.end(generation) {
                        self.currentTask = nil
                    }
                }

                setLoadingState(nil)

                do {
                    var requestMessages = await buildMessages(capabilities: model.capabilities)
                    let tools = await enabledRequestTools(for: model.capabilities)
                    let querySource: QuerySource = switch prompt.source {
                    case .heartbeat:
                        .heartbeat
                    case .user:
                        .user
                    }
                    let toolUseContext = ToolExecutionContext(
                        session: self,
                        toolProvider: self.toolProvider,
                        canUseTool: allowAllTools
                    )

                    let result = try await query(
                        session: self,
                        model: model,
                        requestMessages: &requestMessages,
                        tools: tools,
                        toolUseContext: toolUseContext,
                        maxTurns: 32,
                        querySource: querySource
                    )

                    showsInterruptedRetryAction = false
                    setLoadingState(nil)
                    await updateTitle()
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
                    sessionDelegate?.sessionExecutionDidFinish(
                        for: id,
                        success: false,
                        errorDescription: error.localizedDescription
                    )
                }
            }

            currentTask = task
            taskToAwait = task
        }

        return taskToAwait
    }

    /// Retry the last interrupted turn after user explicitly taps retry.
    func retryInterruptedPromptSubmission() {
        guard showsInterruptedRetryAction,
              !isQueryActive,
              let model = models.chat,
              let lastSubmittedPromptInput
        else {
            return
        }
        showsInterruptedRetryAction = false
        Task { @MainActor [weak self] in
            guard let self else { return }
            _ = self.submitPromptWithoutWaiting(
                model: model,
                prompt: lastSubmittedPromptInput
            )
        }
    }

    private func appendPromptMessage(_ prompt: PromptInput) -> ConversationMessage {
        appendNewMessage(role: .user) { message in
            message.textContent = prompt.text
            for attachment in prompt.attachments {
                message.parts.append(attachment)
            }

            for (key, value) in prompt.metadata {
                message.metadata[key] = value
            }
        }
    }

    func enabledRequestTools(
        for capabilities: Set<ModelCapability>
    ) async -> [ChatRequestBody.Tool]? {
        guard capabilities.contains(.tool), let toolProvider else {
            return nil
        }
        let enabledTools = await toolProvider.enabledTools()
        return enabledTools.isEmpty ? nil : enabledTools
    }
}
