//
//  ConversationSession+Execute.swift
//  LanguageModelChatUI
//
//  Core inference orchestration. Adapted from FlowDown with model-scoped clients.
//

import ChatClient
import Foundation
import UIKit

public extension ConversationSession {
    /// Input object representing what the user typed/attached.
    struct UserInput: Sendable {
        public var text: String
        public var attachments: [ContentPart]

        public init(text: String = "", attachments: [ContentPart] = []) {
            self.text = text
            self.attachments = attachments
        }
    }

    /// Execute inference for the given user input.
    func runInference(
        model: ConversationSession.Model,
        messageListView: MessageListView,
        input: UserInput,
        completion: @escaping @Sendable () -> Void
    ) {
        lastSubmittedInput = input
        showsInterruptedRetryAction = false
        cancelCurrentTask { [self] in
            let bgToken = sessionDelegate?.beginBackgroundTask { [weak self] in
                Task { @MainActor in
                    self?.currentTask?.cancel()
                }
            }

            currentTask = Task { @MainActor in
                ConversationSessionManager.shared.markSessionExecuting(id)
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

                self.currentTask = nil
                ConversationSessionManager.shared.markSessionCompleted(id)
                completion()
            }
        }
    }

    internal func requestUpdate(view: MessageListView) async {
        await view.stopLoading()
        notifyMessagesDidChange()
    }

    private func executeInference(
        model: ConversationSession.Model,
        messageListView: MessageListView,
        input: UserInput
    ) async {
        let modelCapabilities = model.capabilities
        let modelContextLength = model.contextLength

        // Prevent screen lock
        sessionDelegate?.preventIdleTimer()
        persistMessages()

        // Build request messages from conversation history
        var requestMessages = buildRequestMessages(capabilities: modelCapabilities)

        // Add user message
        _ = appendNewMessage(role: .user) { msg in
            msg.textContent = input.text
            for attachment in input.attachments {
                msg.parts.append(attachment)
            }
        }
        await requestUpdate(view: messageListView)
        persistMessages()

        // Add user content to request using the same builder as history reconstruction.
        let latestUserMessage = buildUserRequestMessage(
            text: input.text,
            attachments: input.attachments,
            capabilities: modelCapabilities
        )
        requestMessages.append(latestUserMessage)

        // Inject system command
        await injectSystemPrompt(&requestMessages, capabilities: modelCapabilities)

        // Build tools list
        var tools: [ChatRequestBody.Tool]? = nil
        if modelCapabilities.contains(.tool), let toolProvider {
            await toolProvider.prepareForConversation()
            let toolDefs = await toolProvider.enabledTools()
            if !toolDefs.isEmpty {
                tools = toolDefs
            }
        }

        // Compact context if auto-compact is enabled and threshold is exceeded
        if model.autoCompactEnabled {
            await compactIfNeeded(
                requestMessages: &requestMessages,
                tools: tools,
                model: model,
                capabilities: modelCapabilities
            )
        }

        // Trim context
        await messageListView.loading(with: String.localized("Calculating context window..."))
        await trimToContextLength(
            &requestMessages,
            tools: tools,
            maxTokens: modelContextLength
        )

        await messageListView.stopLoading()

        // Execute inference loop
        do {
            var shouldContinue = false
            repeat {
                try checkCancellation()
                shouldContinue = try await executeInferenceStep(
                    messageListView: messageListView,
                    model: model,
                    requestMessages: &requestMessages,
                    tools: tools
                )
                persistMessages()
            } while shouldContinue

            await requestUpdate(view: messageListView)

            await updateTitle()
            showsInterruptedRetryAction = false
            sessionDelegate?.sessionExecutionDidFinish(for: id, success: true, errorDescription: nil)
        } catch is CancellationError {
            // Surface a manual retry affordance instead of auto-resume.
            showsInterruptedRetryAction = true
            sessionDelegate?.sessionExecutionDidInterrupt(for: id, reason: "cancelled")
        } catch {
            showsInterruptedRetryAction = false
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
        persistMessages()

        // Fire memory consolidation in the background so allowIdleTimer() is not delayed
        // by coordinator setup or disk I/O. The consolidation Task is tracked on self.
        Task { [weak self] in
            await self?.scheduleMemoryConsolidationIfNeeded()
        }

        sessionDelegate?.allowIdleTimer()
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
