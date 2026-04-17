//  Third-party apps implement this protocol to provide data persistence.
//  The framework never touches the database directly.
import ChatClient
import ChatUI
import Foundation

public enum TranscriptEvent: Sendable {
    case syncMessages([ConversationMessage])
    case appendMessage(ConversationMessage)
    case updateMessage(ConversationMessage)
    case deleteMessages([String])
    case setTitle(String)
    case recordAITitle(String)
    case recordLastPrompt(String)
    case turnStarted
    case turnFinished(success: Bool, errorDescription: String?)
    case turnInterrupted(reason: String)
    case usage(TokenUsage)
}

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

    // MARK: - Transcript Recording

    /// Record a transcript-backed session event.
    func recordTranscript(_ event: TranscriptEvent, for sessionID: String)

    /// Record a sidechain transcript event.
    func recordSidechainTranscript(_ event: TranscriptEvent, for sessionID: String)

    /// Flush buffered transcript writes, if any.
    func flushTranscript()

    /// Get the current transcript-derived execution status for a session.
    func sessionStatus(for sessionID: String) -> String
}

public extension StorageProvider {
    func recordTranscript(_ event: TranscriptEvent, for sessionID: String) {
        switch event {
        case let .syncMessages(messages):
            save(messages)
        case let .appendMessage(message), let .updateMessage(message):
            save([message])
        case let .deleteMessages(messageIDs):
            delete(messageIDs)
        case let .setTitle(title), let .recordAITitle(title):
            setTitle(title, for: sessionID)
        case .recordLastPrompt:
            break
        case .turnStarted, .turnFinished, .turnInterrupted, .usage:
            break
        }
    }

    func recordSidechainTranscript(_ event: TranscriptEvent, for sessionID: String) {
        recordTranscript(event, for: sessionID)
    }

    func flushTranscript() {}

    func sessionStatus(for _: String) -> String {
        "idle"
    }
}
