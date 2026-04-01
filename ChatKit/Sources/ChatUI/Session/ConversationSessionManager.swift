//
//  ConversationSessionManager.swift
//  LanguageModelChatUI
//
//  Manages active conversation sessions and their execution state.
//

import Combine
import Foundation

/// Manages all active conversation sessions.
@MainActor
public final class ConversationSessionManager: @unchecked Sendable {
    public static let shared = ConversationSessionManager()

    private var sessions: [String: ConversationSession] = [:]
    private var executingSessions = Set<String>()

    private let executingSessionsSubject = CurrentValueSubject<Set<String>, Never>([])
    public var executingSessionsPublisher: AnyPublisher<Set<String>, Never> {
        executingSessionsSubject.eraseToAnyPublisher()
    }

    private init() {}

    /// Get or create a session for the given conversation ID using explicit providers.
    public func session(for conversationID: String, configuration: ConversationSession.Configuration) -> ConversationSession {
        if let existing = sessions[conversationID] {
            return existing
        }
        let session = ConversationSession(id: conversationID, configuration: configuration)
        sessions[conversationID] = session
        return session
    }

    /// Drop the cached session so a subsequent access rebuilds it from new configuration.
    public func removeSession(for conversationID: String) {
        sessions.removeValue(forKey: conversationID)
        executingSessions.remove(conversationID)
        executingSessionsSubject.send(executingSessions)
    }

    /// Clear all cached sessions. Useful when app-level runtime scope changes.
    public func removeAllSessions() {
        sessions.removeAll()
        executingSessions.removeAll()
        executingSessionsSubject.send(executingSessions)
    }

    /// Remove cached sessions by scoped conversation id prefix.
    /// Example prefix: "agent:<agent-id>::"
    public func removeSessions(withPrefix prefix: String) {
        guard !prefix.isEmpty else { return }
        let sessionIDs = sessions.keys.filter { $0.hasPrefix(prefix) }
        for sessionID in sessionIDs {
            sessions.removeValue(forKey: sessionID)
            executingSessions.remove(sessionID)
        }
        executingSessionsSubject.send(executingSessions)
    }

    func markSessionExecuting(_ conversationID: String) {
        executingSessions.insert(conversationID)
        executingSessionsSubject.send(executingSessions)
    }

    func markSessionCompleted(_ conversationID: String) {
        executingSessions.remove(conversationID)
        executingSessionsSubject.send(executingSessions)
    }

    public func hasExecutingSession() -> Bool {
        !executingSessions.isEmpty
    }

    /// Returns whether any executing session belongs to the given scoped prefix.
    public func hasExecutingSession(withPrefix prefix: String) -> Bool {
        guard !prefix.isEmpty else { return false }
        return executingSessions.contains(where: { $0.hasPrefix(prefix) })
    }
}
