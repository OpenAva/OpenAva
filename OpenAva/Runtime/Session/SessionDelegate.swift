//
//  SessionDelegate.swift
//  ChatUI
//
//  Callbacks for app-specific behaviors during conversation execution.
//

import ChatClient
import ChatUI
import Foundation

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

    /// Prevent the screen from locking during message execution.
    func preventIdleTimer()

    /// Allow the screen to lock normally after message execution completes.
    func allowIdleTimer()

    // MARK: - Execution Lifecycle

    /// Called when one execution turn starts for a session.
    func sessionExecutionDidStart(for sessionID: String)

    /// Called when one execution turn finishes successfully or with failure.
    func sessionExecutionDidFinish(
        for sessionID: String,
        success: Bool,
        errorDescription: String?
    )

    /// Called when one execution turn is interrupted (for example, cancellation).
    func sessionExecutionDidInterrupt(for sessionID: String, reason: String)

    // MARK: - Usage Tracking

    /// Called when token usage is reported after one execution step.
    func sessionDidReportUsage(_ usage: TokenUsage, for sessionID: String)

    /// Called after messages have been persisted for the session.
    func sessionDidPersistMessages(_ messages: [ConversationMessage], for sessionID: String) async

    /// Provide the active support root used for request-scoped dynamic memory recall.
    func activeSupportRootURL() -> URL?
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
    func sessionDidPersistMessages(_: [ConversationMessage], for _: String) async {}

    func activeSupportRootURL() -> URL? {
        nil
    }
}
