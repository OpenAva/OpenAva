import ChatClient
import ChatUI
import Foundation

@MainActor
struct ToolUseContext {
    let session: ConversationSession
    let toolProvider: (any ToolProvider)?
    let messageListView: MessageListView
    let canUseTool: CanUseTool
    let toolResponseLimit: Int
    let interruptFallbackText: String

    init(
        session: ConversationSession,
        toolProvider: (any ToolProvider)?,
        messageListView: MessageListView,
        canUseTool: @escaping CanUseTool,
        toolResponseLimit: Int = 64 * 1024,
        interruptFallbackText: String = String.localized("Interrupted by user")
    ) {
        self.session = session
        self.toolProvider = toolProvider
        self.messageListView = messageListView
        self.canUseTool = canUseTool
        self.toolResponseLimit = toolResponseLimit
        self.interruptFallbackText = interruptFallbackText
    }

    func responseLimit(for tool: any ToolExecutor) -> Int {
        max(1, tool.maxResultSizeChars ?? toolResponseLimit)
    }

    func interruptionText() -> String {
        let reason = session.currentInterruptReason
        switch reason {
        case .userStop, .backgroundExpired, .cancelled, .none:
            return interruptFallbackText
        case .messageDeleted:
            return String.localized("Interrupted because messages changed.")
        case .conversationCleared:
            return String.localized("Interrupted because the conversation was cleared.")
        case .taskReplaced:
            return String.localized("Interrupted by a newer request.")
        }
    }
}
