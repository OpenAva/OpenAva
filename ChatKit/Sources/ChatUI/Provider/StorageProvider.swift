//
//  StorageProvider.swift
//  LanguageModelChatUI
//
//  Third-party apps implement this protocol to provide data persistence.
//  The framework never touches the database directly.
//

import Foundation

/// Abstraction for message and session persistence.
///
/// Third-party apps implement this protocol using their own database
/// (CoreData, SwiftData, WCDB, SQLite, or even in-memory storage).
public protocol StorageProvider: AnyObject, Sendable {
    // MARK: - Messages

    /// Create a new message in the specified session.
    func createMessage(in sessionID: String, role: MessageRole) -> ConversationMessage

    /// Persist message changes to storage.
    func save(_ messages: [ConversationMessage])

    /// List all messages in a session, ordered by creation date.
    func messages(in sessionID: String) -> [ConversationMessage]

    /// Delete messages by ID.
    func delete(_ messageIDs: [String])

    // MARK: - Conversation Metadata

    /// Get the title of a session.
    func title(for id: String) -> String?

    /// Set the title of a session.
    func setTitle(_ title: String, for id: String)
}
