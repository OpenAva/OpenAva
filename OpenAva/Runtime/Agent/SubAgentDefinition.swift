import Foundation

struct SubAgentDefinition: Equatable, Sendable {
    enum ToolPolicy: Equatable, Sendable {
        case all
        case readOnly
        case custom(Set<String>)
    }

    static let recursiveToolFunctionNames: Set<String> = [
        "subagent_run",
        "subagent_status",
        "subagent_cancel",
    ]

    static let readOnlyFunctionNames: Set<String> = [
        "current_time",
        "device_info",
        "device_status",
        "fs_read",
        "fs_list",
        "fs_find",
        "fs_grep",
        "skill_load",
        "memory_history_search",
        "web_fetch",
        "web_search",
        "image_search",
        "youtube_transcript",
        "web_view",
        "web_view_snapshot",
        "web_view_read",
        "weather_get",
        "yahoo_finance",
        "a_share_market",
    ]

    let agentType: String
    let description: String
    let systemPrompt: String
    let toolPolicy: ToolPolicy
    let disallowedFunctionNames: Set<String>
    let maxTurns: Int
    let supportsBackground: Bool

    func allowsTool(functionName: String) -> Bool {
        guard !disallowedFunctionNames.contains(functionName) else {
            return false
        }

        switch toolPolicy {
        case .all:
            return true
        case .readOnly:
            return Self.readOnlyFunctionNames.contains(functionName)
        case let .custom(allowed):
            return allowed.contains(functionName)
        }
    }
}
