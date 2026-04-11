import ChatUI
import Foundation

@MainActor
struct QueryEngineConfig {
    let session: ConversationSession
    let model: ConversationSession.Model
    let messageListView: MessageListView
    let maxTurns: Int
    let canUseTool: CanUseTool

    init(
        session: ConversationSession,
        model: ConversationSession.Model,
        messageListView: MessageListView,
        maxTurns: Int = 16,
        canUseTool: @escaping CanUseTool = allowAllTools
    ) {
        self.session = session
        self.model = model
        self.messageListView = messageListView
        self.maxTurns = max(1, maxTurns)
        self.canUseTool = canUseTool
    }
}
