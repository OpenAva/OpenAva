//
//  ConversationSessionManager.swift
//  ChatUI
//
//  Manages active conversation sessions.
//

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

    private init() {}

    /// Get or create a session for the given session ID using explicit providers.
    public func session(for sessionID: String, configuration: ConversationSession.Configuration) -> ConversationSession {
        let key = SessionCacheKey(
            sessionID: sessionID,
            storageID: ObjectIdentifier(configuration.storage)
        )
        if let existing = sessions[key] {
            existing.reconfigure(with: configuration)
            return existing
        }
        let session = ConversationSession(id: sessionID, configuration: configuration)
        sessions[key] = session
        return session
    }

    /// Returns a previously cached session for the given session ID, if present.
    public func cachedSession(for sessionID: String) -> ConversationSession? {
        sessions.first { $0.key.sessionID == sessionID }?.value
    }

    /// Drop the cached session so a subsequent access rebuilds it from new configuration.
    public func removeSession(for sessionID: String) {
        let keysToRemove = sessions.keys.filter { $0.sessionID == sessionID }
        keysToRemove.forEach { sessions.removeValue(forKey: $0) }
    }

    /// Clear all cached sessions. Useful when app-level runtime scope changes.
    public func removeAllSessions() {
        sessions.removeAll()
    }

    /// Remove cached sessions by scoped conversation id prefix.
    /// Example prefix: "agent:<agent-id>::"
    public func removeSessions(withPrefix prefix: String) {
        guard !prefix.isEmpty else { return }
        let keysToRemove = sessions.keys.filter { $0.sessionID.hasPrefix(prefix) }
        for key in keysToRemove {
            sessions.removeValue(forKey: key)
        }
    }

    public func hasActiveQuery() -> Bool {
        sessions.values.contains(where: \.isQueryActive)
    }

    /// Returns whether any active query belongs to the given scoped prefix.
    public func hasActiveQuery(withPrefix prefix: String) -> Bool {
        guard !prefix.isEmpty else { return false }
        return sessions.contains { entry in
            entry.key.sessionID.hasPrefix(prefix) && entry.value.isQueryActive
        }
    }

    public func isQueryActive(_ session: ConversationSession) -> Bool {
        session.isQueryActive
    }

    public func isQueryActive(_ sessionID: String, storage: StorageProvider) -> Bool {
        guard !sessionID.isEmpty else { return false }
        let key = SessionCacheKey(sessionID: sessionID, storageID: ObjectIdentifier(storage))
        return sessions[key]?.isQueryActive ?? false
    }
}
