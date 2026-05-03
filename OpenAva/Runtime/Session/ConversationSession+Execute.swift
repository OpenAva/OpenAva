import ChatClient
import ChatUI
import Foundation
import OSLog

private let logger = Logger(subsystem: "com.day1-labs.openava", category: "chat.stop.execute")

private struct ExecutionErrorPresentation {
    let title: String
    let message: String
    let details: String
}

private func executionErrorPresentation(for error: Error) -> ExecutionErrorPresentation {
    let rawDescription = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
    let nsError = error as NSError
    let technicalDetails = [
        rawDescription,
        nsError.domain.isEmpty ? nil : "Domain: \(nsError.domain)",
        nsError.code == 0 ? nil : "Code: \(nsError.code)",
    ]
    .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
    .filter { !$0.isEmpty }
    .joined(separator: "\n")

    if case QueryExecutionError.noResponseFromModel = error {
        return .init(
            title: String.localized("Request failed"),
            message: String.localized("The model did not return any displayable content, and no provider error details were received. Check the selected model, API key/quota, network, or provider status, then try again."),
            details: technicalDetails
        )
    }

    let message: String
    if isPromptTooLongError(error) {
        message = String.localized("The conversation is over the model context limit. Compact earlier messages or start a shorter request, then try again.")
    } else if nsError.domain == NSURLErrorDomain {
        message = String.localized("Network connection failed. Check your network or proxy settings, then try again.")
    } else if rawDescription.isEmpty {
        message = String.localized("The model provider returned an error, but did not include a readable message. Copy the details below for debugging.")
    } else {
        message = String(format: String.localized("The model provider returned an error: %@"), rawDescription)
    }

    return .init(
        title: String.localized("Request failed"),
        message: message,
        details: technicalDetails
    )
}

public extension ConversationSession {
    /// Input object representing what the user typed/attached.
    struct PromptInput: Sendable {
        public enum Source: String, Sendable {
            case user
            case heartbeat
            case teamMention = "team_mention"
            case teamTask = "team_task"
            case teamBroadcast = "team_broadcast"
            case teamMessage = "team_message"
            case systemEvent = "system_event"
        }

        public static let sourceMetadataKey = "turnSource"
        public static let teamMessageTypeMetadataKey = "teamMessageType"
        public static let teamSenderMetadataKey = "teamSender"

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

                    let persistedMessages = transcriptPersistableMessages()
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
                    case .user, .teamMention, .teamTask, .teamBroadcast, .teamMessage, .systemEvent:
                        .user
                    }
                    let toolUseContext = ToolExecutionContext(
                        session: self,
                        toolProvider: self.toolProvider,
                        canUseTool: defaultToolPermissionPolicy
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
                    let presentation = executionErrorPresentation(for: error)
                    _ = appendNewMessage(role: .assistant) { msg in
                        msg.textContent = presentation.message
                        msg.finishReason = .error
                        msg.isTransientExecutionError = true
                        msg.executionErrorTitle = presentation.title
                        msg.executionErrorMessage = presentation.message
                        msg.executionErrorDetails = presentation.details
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
    @discardableResult
    func retryInterruptedPromptSubmission() -> Bool {
        guard showsInterruptedRetryAction,
              !isQueryActive,
              let model = models.chat,
              let lastSubmittedPromptInput
        else {
            return false
        }
        showsInterruptedRetryAction = false
        Task { @MainActor [weak self] in
            guard let self else { return }
            let didStart = self.submitPromptWithoutWaiting(
                model: model,
                prompt: lastSubmittedPromptInput
            )
            if !didStart {
                self.showsInterruptedRetryAction = true
            }
        }
        return true
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
