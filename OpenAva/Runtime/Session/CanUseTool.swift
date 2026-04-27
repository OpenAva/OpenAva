import ChatClient
import ChatUI
import Foundation

enum ToolPermissionBehavior: String, Codable {
    case allow
    case deny
    case ask
}

enum ToolPermissionMode: String, Codable, Equatable {
    case `default`
    case acceptEdits
    case bypassPermissions
    case auto
}

struct ToolPermissionRule: Codable, Identifiable, Equatable {
    enum Scope: String, Codable {
        case session
        case project
        case user
        case system
    }

    let id: String
    let behavior: ToolPermissionBehavior
    let scope: Scope
    let toolName: String
    let matcher: ToolPermissionMatcher
    let createdAt: Date

    init(
        id: String = UUID().uuidString,
        behavior: ToolPermissionBehavior,
        scope: Scope = .session,
        toolName: String,
        matcher: ToolPermissionMatcher = .tool,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.behavior = behavior
        self.scope = scope
        self.toolName = toolName
        self.matcher = matcher
        self.createdAt = createdAt
    }
}

enum ToolPermissionMatcher: Codable, Equatable {
    case tool
    case pathPrefix(String)
    case commandPrefix(String)
    case argumentContains(String)
}

enum BashCommandRisk: String, Codable, Equatable {
    case readOnly
    case writeLocal
    case network
    case destructive
    case privilegeEscalation
    case unknown
}

struct BashPermissionClassification: Equatable {
    let command: String
    let risk: BashCommandRisk
    let reason: String
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

typealias CanUseTool = @Sendable (_ request: ToolRequest, _ tool: any ToolExecutor, _ context: ToolExecutionContext) async -> ToolPermissionDecision

@MainActor
func allowAllTools(_: ToolRequest, _: any ToolExecutor, _: ToolExecutionContext) async -> ToolPermissionDecision {
    .allow
}

@MainActor
func defaultToolPermissionPolicy(_ request: ToolRequest, _ tool: any ToolExecutor, _ context: ToolExecutionContext) async -> ToolPermissionDecision {
    if context.session.toolPermissionMode == .bypassPermissions {
        return ToolPermissionDecision(
            behavior: .allow,
            message: nil,
            reason: "permission_mode_bypass"
        )
    }

    if let ruleDecision = sessionRulePermissionDecision(for: request, in: context.session) {
        return ruleDecision
    }

    if let parameterDecision = parameterAwarePermissionDecision(for: request) {
        return parameterDecision
    }

    if tool.isReadOnly {
        return ToolPermissionDecision(
            behavior: .allow,
            message: nil,
            reason: "read_only_tool"
        )
    }

    if let teamToolDecision = defaultTeamToolPermissionDecision(for: request) {
        return teamToolDecision
    }

    if let bashDecision = bashPermissionDecision(for: request) {
        return bashDecision
    }

    if acceptsEditWithoutPrompt(request: request, tool: tool, mode: context.session.toolPermissionMode) {
        return ToolPermissionDecision(
            behavior: .allow,
            message: nil,
            reason: "permission_mode_accept_edits"
        )
    }

    if tool.isDestructive {
        return .ask(
            message: String.localized("Tool execution requires approval because this tool can modify or delete data."),
            reason: "destructive_tool_requires_approval"
        )
    }

    return .deny(
        message: String.localized("Tool execution was denied because this tool is not approved by the default policy."),
        reason: "unclassified_mutating_tool_denied"
    )
}

private func defaultTeamToolPermissionDecision(for request: ToolRequest) -> ToolPermissionDecision? {
    switch request.name {
    case "team_message_send":
        if teamMessageSendRequestsShutdown(request.arguments) {
            return .ask(
                message: String.localized("Stopping a teammate requires approval."),
                reason: "team_shutdown_requires_approval"
            )
        }
        return ToolPermissionDecision(
            behavior: .allow,
            message: nil,
            reason: "internal_team_message"
        )

    case "team_plan_approve":
        return ToolPermissionDecision(
            behavior: .allow,
            message: nil,
            reason: "team_plan_approval"
        )

    case "team_task_create", "team_task_update":
        return ToolPermissionDecision(
            behavior: .allow,
            message: nil,
            reason: "team_task_state_update"
        )

    default:
        return nil
    }
}

private func teamMessageSendRequestsShutdown(_ arguments: String) -> Bool {
    guard let data = arguments.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data),
          let dictionary = object as? [String: Any]
    else {
        return arguments.contains("\"message_type\"") && arguments.contains("shutdown_request")
    }

    return (dictionary["message_type"] as? String) == "shutdown_request"
}

@MainActor
private func sessionRulePermissionDecision(for request: ToolRequest, in session: ConversationSession) -> ToolPermissionDecision? {
    guard let rule = session.sessionToolPermissionRules.first(where: { toolPermissionRule($0, matches: request) }) else {
        return nil
    }

    switch rule.behavior {
    case .allow:
        return ToolPermissionDecision(
            behavior: .allow,
            message: nil,
            reason: "permission_rule_allow_\(rule.scope.rawValue)"
        )
    case .deny:
        return .deny(
            message: String.localized("Tool execution was denied by a remembered permission rule."),
            reason: "permission_rule_deny_\(rule.scope.rawValue)"
        )
    case .ask:
        return .ask(
            message: String.localized("Tool execution requires approval because a permission rule asks before running this tool."),
            reason: "permission_rule_ask_\(rule.scope.rawValue)"
        )
    }
}

private func toolPermissionRule(_ rule: ToolPermissionRule, matches request: ToolRequest) -> Bool {
    guard rule.toolName == request.name || rule.toolName == "*" else {
        return false
    }

    switch rule.matcher {
    case .tool:
        return true
    case let .pathPrefix(prefix):
        guard let path = permissionArgumentString(for: ["path", "file_path", "filePath"], in: request.arguments) else {
            return false
        }
        return normalizedPermissionPath(path).hasPrefix(normalizedPermissionPath(prefix))
    case let .commandPrefix(prefix):
        guard let command = permissionArgumentString(for: ["command"], in: request.arguments) else {
            return false
        }
        return command.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(prefix)
    case let .argumentContains(value):
        return request.arguments.localizedCaseInsensitiveContains(value)
    }
}

private func parameterAwarePermissionDecision(for request: ToolRequest) -> ToolPermissionDecision? {
    if let path = permissionArgumentString(for: ["path", "file_path", "filePath"], in: request.arguments), isSensitivePermissionPath(path) {
        return .ask(
            message: String.localized("Tool execution requires approval because it touches a sensitive path."),
            reason: "sensitive_path_requires_approval"
        )
    }

    if request.name == "fs_delete", deletesWorkspaceRoot(request.arguments) {
        return .ask(
            message: String.localized("Deleting the workspace root requires approval."),
            reason: "workspace_root_delete_requires_approval"
        )
    }

    return nil
}

private func bashPermissionDecision(for request: ToolRequest) -> ToolPermissionDecision? {
    guard request.name == "bash" || request.name == "bash.execute" else {
        return nil
    }
    guard let classification = classifyBashCommand(arguments: request.arguments) else {
        return .ask(
            message: String.localized("Bash command requires approval because it could not be classified."),
            reason: "bash_command_unclassified"
        )
    }

    switch classification.risk {
    case .readOnly:
        return ToolPermissionDecision(
            behavior: .allow,
            message: nil,
            reason: classification.reason
        )
    case .privilegeEscalation, .destructive:
        return .ask(
            message: String.localized("Bash command requires approval because it is potentially destructive or privileged."),
            reason: classification.reason
        )
    case .writeLocal, .network, .unknown:
        return .ask(
            message: String.localized("Bash command requires approval because it may modify local state, access the network, or has unknown risk."),
            reason: classification.reason
        )
    }
}

func classifyBashCommand(arguments: String) -> BashPermissionClassification? {
    guard let command = permissionArgumentString(for: ["command"], in: arguments)?.trimmingCharacters(in: .whitespacesAndNewlines), !command.isEmpty else {
        return nil
    }
    return classifyBashCommand(command)
}

func classifyBashCommand(_ command: String) -> BashPermissionClassification {
    let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
    let lowered = trimmed.lowercased()

    if matchesAnyBashPattern(lowered, patterns: privilegeEscalationBashPatterns) {
        return BashPermissionClassification(command: trimmed, risk: .privilegeEscalation, reason: "bash_privilege_escalation_requires_approval")
    }
    if matchesAnyBashPattern(lowered, patterns: destructiveBashPatterns) {
        return BashPermissionClassification(command: trimmed, risk: .destructive, reason: "bash_destructive_command_requires_approval")
    }
    if isReadOnlyBashCommand(lowered) {
        return BashPermissionClassification(command: trimmed, risk: .readOnly, reason: "bash_read_only_command")
    }
    if matchesAnyBashPattern(lowered, patterns: networkBashPatterns) {
        return BashPermissionClassification(command: trimmed, risk: .network, reason: "bash_network_command_requires_approval")
    }
    if matchesAnyBashPattern(lowered, patterns: writeLocalBashPatterns) {
        return BashPermissionClassification(command: trimmed, risk: .writeLocal, reason: "bash_write_command_requires_approval")
    }

    return BashPermissionClassification(command: trimmed, risk: .unknown, reason: "bash_unknown_command_requires_approval")
}

private let privilegeEscalationBashPatterns = [
    #"(^|[;&|]{1,2})\s*(sudo|su|doas)\b"#,
]

private let destructiveBashPatterns = [
    #"(^|[;&|]{1,2})\s*rm\b"#,
    #"(^|[;&|]{1,2})\s*(dd|mkfs|diskutil)\b"#,
    #"chmod\s+-r\s+777\b"#,
    #"(^|[;&|]{1,2})\s*find\b.*\s-delete\b"#,
    #"(curl|wget)\b.*\|\s*(sh|bash)\b"#,
    #"(^|[;&|]{1,2})\s*git\s+(reset\s+--hard|clean\s+-)"#,
]

private let networkBashPatterns = [
    #"(^|[;&|]{1,2})\s*(curl|wget|scp|sftp|ssh|ftp|telnet)\b"#,
]

private let writeLocalBashPatterns = [
    #"(^|[;&|]{1,2})\s*(npm|pnpm|yarn|bun)\s+(install|add|remove|update)\b"#,
    #"(^|[;&|]{1,2})\s*(go\s+mod\s+tidy|cargo\s+build|swift\s+(build|test)|xcodebuild)\b"#,
    #"(^|[;&|]{1,2})\s*(mkdir|touch|mv|cp|chmod|chown|ln|git\s+(checkout|switch|restore|stash|commit|add))\b"#,
]

private func isReadOnlyBashCommand(_ loweredCommand: String) -> Bool {
    guard loweredCommand.range(of: #"[|<>]"#, options: .regularExpression) == nil else {
        return false
    }

    let segments = loweredCommand
        .replacingOccurrences(of: "&&", with: ";")
        .split(separator: ";")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }

    guard !segments.isEmpty else { return false }
    return segments.allSatisfy { segment in
        let normalized = segment.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return readOnlyBashCommandPrefixes.contains { prefix in
            normalized == prefix || normalized.hasPrefix(prefix + " ")
        }
    }
}

private let readOnlyBashCommandPrefixes: [String] = [
    "pwd",
    "ls",
    "find",
    "grep",
    "git status",
    "git diff",
    "git log",
    "git branch",
    "git rev-parse",
    "swift --version",
    "node --version",
    "npm --version",
    "python --version",
    "python3 --version",
]

private func matchesAnyBashPattern(_ command: String, patterns: [String]) -> Bool {
    patterns.contains { command.range(of: $0, options: .regularExpression) != nil }
}

private func acceptsEditWithoutPrompt(request: ToolRequest, tool: any ToolExecutor, mode: ToolPermissionMode) -> Bool {
    guard mode == .acceptEdits || mode == .auto else { return false }
    guard isFileMutationTool(request.name), !request.name.contains("delete") else { return false }
    if let path = permissionArgumentString(for: ["path", "file_path", "filePath"], in: request.arguments), isSensitivePermissionPath(path) {
        return false
    }
    return tool.isDestructive
}

private func isFileMutationTool(_ name: String) -> Bool {
    ["fs_write", "fs_replace", "fs_append", "fs_mkdir"].contains(name)
}

private func deletesWorkspaceRoot(_ arguments: String) -> Bool {
    guard let path = permissionArgumentString(for: ["path"], in: arguments) else { return false }
    let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed == "." || trimmed == "./" || trimmed == "/"
}

private func isSensitivePermissionPath(_ path: String) -> Bool {
    let normalized = normalizedPermissionPath(path).lowercased()
    let sensitiveFragments = [
        "/.ssh", "/.gnupg", "/.aws", "/.config", "/library/keychains",
        ".env", ".pem", ".key", "id_rsa", "id_ed25519",
    ]
    return sensitiveFragments.contains { normalized.contains($0) }
}

private func normalizedPermissionPath(_ path: String) -> String {
    NSString(string: path.trimmingCharacters(in: .whitespacesAndNewlines)).standardizingPath
}

private func permissionArgumentString(for keys: [String], in arguments: String) -> String? {
    guard let data = arguments.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data),
          let dictionary = object as? [String: Any]
    else {
        return nil
    }

    for key in keys {
        if let value = dictionary[key] as? String {
            return value
        }
    }
    return nil
}
