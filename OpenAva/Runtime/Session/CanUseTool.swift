import ChatClient
import Foundation

enum ToolPermissionBehavior: String {
    case allow
    case deny
    case ask
}

struct ToolPermissionDecision: Equatable {
    let behavior: ToolPermissionBehavior
    let message: String?
    let reason: String?

    var allowsExecution: Bool {
        behavior == .allow
    }

    static let allow = ToolPermissionDecision(behavior: .allow, message: nil, reason: nil)

    static func deny(message: String? = nil, reason: String? = nil) -> ToolPermissionDecision {
        ToolPermissionDecision(behavior: .deny, message: message, reason: reason)
    }

    static func ask(message: String? = nil, reason: String? = nil) -> ToolPermissionDecision {
        ToolPermissionDecision(behavior: .ask, message: message, reason: reason)
    }
}

typealias CanUseTool = @Sendable (_ request: ToolRequest, _ tool: any ToolExecutor, _ context: ToolUseContext) async -> ToolPermissionDecision

@MainActor
func allowAllTools(_: ToolRequest, _: any ToolExecutor, _: ToolUseContext) async -> ToolPermissionDecision {
    .allow
}
