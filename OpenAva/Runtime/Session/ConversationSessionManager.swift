//
//  ConversationSessionManager.swift
//  ChatUI
//
//  Manages active conversation sessions and their execution state.
//

import Combine
import Foundation

/// Manages all active conversation sessions.
@MainActor
public final class ConversationSessionManager: @unchecked Sendable {
    public static let shared = ConversationSessionManager()

    private struct SessionCacheKey: Hashable {
        let sessionID: String
        let storageID: ObjectIdentifier
    }

    private var sessions: [SessionCacheKey: ConversationSession] = [:]
    private var executingSessionCounts: [SessionCacheKey: Int] = [:]

    private let executingSessionsSubject = CurrentValueSubject<Void, Never>(())
    public var executingSessionsPublisher: AnyPublisher<Void, Never> {
        executingSessionsSubject.eraseToAnyPublisher()
    }

    private init() {}

    /// Get or create a session for the given session ID using explicit providers.
    public func session(for sessionID: String, configuration: ConversationSession.Configuration) -> ConversationSession {
        let key = SessionCacheKey(
            sessionID: sessionID,
            storageID: ObjectIdentifier(configuration.storage)
        )
        if let existing = sessions[key] {
            return existing
        }
        let session = ConversationSession(id: sessionID, configuration: configuration)
        sessions[key] = session
        return session
    }

    /// Drop the cached session so a subsequent access rebuilds it from new configuration.
    public func removeSession(for sessionID: String) {
        let keysToRemove = sessions.keys.filter { $0.sessionID == sessionID }
        keysToRemove.forEach { sessions.removeValue(forKey: $0) }
        keysToRemove.forEach { executingSessionCounts.removeValue(forKey: $0) }
        publishExecutingSessions()
    }

    /// Clear all cached sessions. Useful when app-level runtime scope changes.
    public func removeAllSessions() {
        sessions.removeAll()
        executingSessionCounts.removeAll()
        publishExecutingSessions()
    }

    /// Remove cached sessions by scoped conversation id prefix.
    /// Example prefix: "agent:<agent-id>::"
    public func removeSessions(withPrefix prefix: String) {
        guard !prefix.isEmpty else { return }
        let keysToRemove = sessions.keys.filter { $0.sessionID.hasPrefix(prefix) }
        for key in keysToRemove {
            sessions.removeValue(forKey: key)
            executingSessionCounts.removeValue(forKey: key)
        }
        publishExecutingSessions()
    }

    func markSessionExecuting(_ session: ConversationSession) {
        markSessionExecuting(session.id, storage: session.storageProvider)
    }

    func markSessionExecuting(_ sessionID: String, storage: StorageProvider) {
        let key = SessionCacheKey(sessionID: sessionID, storageID: ObjectIdentifier(storage))
        let nextCount = (executingSessionCounts[key] ?? 0) + 1
        executingSessionCounts[key] = nextCount
        publishExecutingSessions()
    }

    func markSessionCompleted(_ session: ConversationSession) {
        markSessionCompleted(session.id, storage: session.storageProvider)
    }

    func markSessionCompleted(_ sessionID: String, storage: StorageProvider) {
        let key = SessionCacheKey(sessionID: sessionID, storageID: ObjectIdentifier(storage))
        guard let currentCount = executingSessionCounts[key] else {
            return
        }
        if currentCount <= 1 {
            executingSessionCounts.removeValue(forKey: key)
        } else {
            executingSessionCounts[key] = currentCount - 1
        }
        publishExecutingSessions()
    }

    public func hasExecutingSession() -> Bool {
        !executingSessionCounts.isEmpty
    }

    /// Returns whether any executing session belongs to the given scoped prefix.
    public func hasExecutingSession(withPrefix prefix: String) -> Bool {
        guard !prefix.isEmpty else { return false }
        return executingSessionCounts.keys.contains(where: { $0.sessionID.hasPrefix(prefix) })
    }

    public func isSessionExecuting(_ session: ConversationSession) -> Bool {
        isSessionExecuting(session.id, storage: session.storageProvider)
    }

    public func isSessionExecuting(_ sessionID: String, storage: StorageProvider) -> Bool {
        guard !sessionID.isEmpty else { return false }
        let key = SessionCacheKey(sessionID: sessionID, storageID: ObjectIdentifier(storage))
        return (executingSessionCounts[key] ?? 0) > 0
    }

    private func publishExecutingSessions() {
        executingSessionsSubject.send(())
    }
}
