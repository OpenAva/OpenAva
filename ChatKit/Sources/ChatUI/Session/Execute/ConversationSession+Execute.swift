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

    internal func requestUpdate(view: MessageListView, scrolling: Bool) async {
        await view.stopLoading()
        notifyMessagesDidChange(scrolling: scrolling)
    }

    private func executeInference(
        model: ConversationSession.Model,
        messageListView: MessageListView,
        input: UserInput
    ) async {
        // Prevent screen lock
        sessionDelegate?.preventIdleTimer()
        let queryEngine = QueryEngine(config: .init(
            session: self,
            model: model,
            messageListView: messageListView
        ))

        do {
            var queryResult: QueryResult?
            for try await event in queryEngine.submitMessage(input) {
                switch event {
                case let .loading(status):
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
