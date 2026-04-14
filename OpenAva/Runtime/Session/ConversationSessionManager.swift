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
    private var executingSessionCounts: [String: Int] = [:]

    private let executingSessionsSubject = CurrentValueSubject<Set<String>, Never>([])
    public var executingSessionsPublisher: AnyPublisher<Set<String>, Never> {
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
        executingSessionCounts.removeValue(forKey: sessionID)
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
            executingSessionCounts.removeValue(forKey: key.sessionID)
        }
        publishExecutingSessions()
    }

    func markSessionExecuting(_ sessionID: String) {
        let nextCount = (executingSessionCounts[sessionID] ?? 0) + 1
        executingSessionCounts[sessionID] = nextCount
        publishExecutingSessions()
    }

    func markSessionCompleted(_ sessionID: String) {
        guard let currentCount = executingSessionCounts[sessionID] else {
            return
        }
        if currentCount <= 1 {
            executingSessionCounts.removeValue(forKey: sessionID)
        } else {
            executingSessionCounts[sessionID] = currentCount - 1
        }
        publishExecutingSessions()
    }

    public func hasExecutingSession() -> Bool {
        !executingSessionCounts.isEmpty
    }

    /// Returns whether any executing session belongs to the given scoped prefix.
    public func hasExecutingSession(withPrefix prefix: String) -> Bool {
        guard !prefix.isEmpty else { return false }
        return executingSessionCounts.keys.contains(where: { $0.hasPrefix(prefix) })
    }

    private func publishExecutingSessions() {
        executingSessionsSubject.send(Set(executingSessionCounts.keys))
    }
}
