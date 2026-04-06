import ChatClient
import Foundation

@MainActor
struct ToolUseContext {
    let session: ConversationSession
    let toolProvider: (any ToolProvider)?
    let messageListView: MessageListView
    let canUseTool: CanUseTool
    let toolResponseLimit: Int

    init(
        session: ConversationSession,
        toolProvider: (any ToolProvider)?,
        messageListView: MessageListView,
        canUseTool: @escaping CanUseTool,
        toolResponseLimit: Int = 64 * 1024
    ) {
        self.session = session
        self.toolProvider = toolProvider
        self.messageListView = messageListView
        self.canUseTool = canUseTool
        self.toolResponseLimit = toolResponseLimit
    }

    func responseLimit(for tool: any ToolExecutor) -> Int {
        max(1, tool.maxResultSizeChars ?? toolResponseLimit)
    }
}
