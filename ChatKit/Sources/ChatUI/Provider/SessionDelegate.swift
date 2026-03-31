//
//  SessionDelegate.swift
//  LanguageModelChatUI
//
//  Callbacks for app-specific behaviors during conversation execution.
//

import ChatClient
import Foundation
import MemoryKit

/// Delegate for application-level behaviors during conversation execution.
///
/// Provides hooks for background task management, UI presentation, and
/// optional context injection. All methods have default implementations
/// that do nothing, so you only need to implement what you need.
public protocol SessionDelegate: AnyObject, Sendable {
    // MARK: - Background Task Management

    /// Begin a background task. Return a token to end it later.
    func beginBackgroundTask(expiration: @escaping @Sendable () -> Void) -> Any?

    /// End a previously started background task.
    func endBackgroundTask(_ token: Any)

    /// Prevent the screen from locking during inference.
    func preventIdleTimer()

    /// Allow the screen to lock normally after inference completes.
    func allowIdleTimer()

    // MARK: - Execution Lifecycle

    /// Called when one inference turn starts for a conversation.
    func sessionExecutionDidStart(for conversationID: String)

    /// Called when one inference turn finishes successfully or with failure.
    func sessionExecutionDidFinish(
        for conversationID: String,
        success: Bool,
        errorDescription: String?
    )

    /// Called when one inference turn is interrupted (for example, cancellation).
    func sessionExecutionDidInterrupt(for conversationID: String, reason: String)

    // MARK: - Usage Tracking

    /// Called when token usage is reported after an inference step.
    func sessionDidReportUsage(_ usage: TokenUsage, for conversationID: String)

    // MARK: - Optional Context

    /// Provide proactive memory context to inject into system prompt.
    func proactiveMemoryContext() async -> String?

    /// Provide search sensitivity prompt text.
    func searchSensitivityPrompt() -> String?

    // MARK: - Memory (Hybrid mode)

    /// Provide a conversation-scoped memory coordinator.
    func memoryCoordinator(for conversationID: String) async -> MemoryCoordinator?

    /// Load persisted memory state for the conversation.
    func loadSessionMemoryState(for conversationID: String) async -> SessionMemoryState

    /// Persist memory state after successful consolidation.
    func saveSessionMemoryState(_ state: SessionMemoryState, for conversationID: String) async

    /// Compose a fully built system prompt for this inference step.
    ///
    /// When non-nil, this replaces the default base-prompt+date assembly in
    /// `injectSystemPrompt`. Use this to delegate prompt construction to the
    /// host app (e.g. via AgentPromptBuilder) so the full agent identity,
    /// tooling, workspace context, and time section are injected correctly.
    ///
    /// Returning nil falls back to the built-in behavior.
    func composeSystemPrompt() async -> String?
}

// MARK: - Default Implementations

public extension SessionDelegate {
    func beginBackgroundTask(expiration _: @escaping @Sendable () -> Void) -> Any? {
        nil
    }

    func endBackgroundTask(_: Any) {}
    func preventIdleTimer() {}
    func allowIdleTimer() {}
    func sessionExecutionDidStart(for _: String) {}
    func sessionExecutionDidFinish(for _: String, success _: Bool, errorDescription _: String?) {}
    func sessionExecutionDidInterrupt(for _: String, reason _: String) {}
    func sessionDidReportUsage(_: TokenUsage, for _: String) {}
    func proactiveMemoryContext() async -> String? {
        nil
    }

    func searchSensitivityPrompt() -> String? {
        nil
    }

    func memoryCoordinator(for _: String) async -> MemoryCoordinator? {
        nil
    }

    func loadSessionMemoryState(for _: String) async -> SessionMemoryState {
        .init()
    }

    func saveSessionMemoryState(_: SessionMemoryState, for _: String) async {}

    func composeSystemPrompt() async -> String? {
        nil
    }
}
