import ChatClient
import ChatUI
import Foundation

enum ToolPermissionBehavior: String, Codable {
    case allow
    case deny
    case ask
}

enum ToolPermissionMode: String, Equatable {
    case `default`
    case bypassPermissions
    case auto
}

struct ToolPermissionRule: Codable, Identifiable, Equatable {
    enum Scope: String, Codable {
        case session
        case project
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
    case argumentsEqual(String)
}

struct ToolPermissionDecision: Equatable {
    let behavior: ToolPermissionBehavior
    let message: String?
    let reason: String?
    let approvedReadableRootURL: URL?

    init(
        behavior: ToolPermissionBehavior,
        message: String?,
        reason: String?,
        approvedReadableRootURL: URL? = nil
    ) {
        self.behavior = behavior
        self.message = message
        self.reason = reason
        self.approvedReadableRootURL = approvedReadableRootURL
    }

    var allowsExecution: Bool {
        behavior == .allow
    }

    static let allow = ToolPermissionDecision(behavior: .allow, message: nil, reason: nil, approvedReadableRootURL: nil)

    static func deny(message: String? = nil, reason: String? = nil) -> ToolPermissionDecision {
        ToolPermissionDecision(behavior: .deny, message: message, reason: reason, approvedReadableRootURL: nil)
    }

    static func ask(message: String? = nil, reason: String? = nil, approvedReadableRootURL: URL? = nil) -> ToolPermissionDecision {
        ToolPermissionDecision(behavior: .ask, message: message, reason: reason, approvedReadableRootURL: approvedReadableRootURL)
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

    if let parameterDecision = parameterAwarePermissionDecision(for: request, tool: tool) {
        return parameterDecision
    }

    if let internalStateDecision = internalStateToolPermissionDecision(for: tool) {
        return internalStateDecision
    }

    if let fileReadDecision = fileReadPermissionDecision(for: request, tool: tool, context: context) {
        return fileReadDecision
    }

    if tool.isReadOnly {
        return ToolPermissionDecision(
            behavior: .allow,
            message: nil,
            reason: "read_only_tool"
        )
    }

    if let teamToolDecision = defaultTeamToolPermissionDecision(for: request, tool: tool) {
        return teamToolDecision
    }

    if let bashDecision = bashPermissionDecision(for: request, tool: tool, mode: context.session.toolPermissionMode) {
        return bashDecision
    }

    if context.session.toolPermissionMode == .auto,
       allowsAutoReviewedToolWithoutPrompt(tool: tool)
    {
        return ToolPermissionDecision(
            behavior: .allow,
            message: nil,
            reason: "permission_mode_auto_review"
        )
    }

    if allowsDefaultReviewedToolWithoutPrompt(tool: tool) {
        return ToolPermissionDecision(
            behavior: .allow,
            message: nil,
            reason: "default_allowed_tool_profile"
        )
    }

    if tool.isDestructive {
        return .ask(
            message: String.localized("Tool execution requires approval because this tool can modify or delete data."),
            reason: "destructive_tool_requires_approval"
        )
    }

    return .ask(
        message: String.localized("Tool execution requires approval because this tool can modify local app state or invoke additional instructions."),
        reason: "unclassified_mutating_tool_requires_approval"
    )
}

private func internalStateToolPermissionDecision(for tool: any ToolExecutor) -> ToolPermissionDecision? {
    guard tool.permissionProfile == .internalStateMutation else {
        return nil
    }

    return ToolPermissionDecision(
        behavior: .allow,
        message: nil,
        reason: "internal_state_update"
    )
}

private func defaultTeamToolPermissionDecision(for request: ToolRequest, tool: any ToolExecutor) -> ToolPermissionDecision? {
    switch tool.permissionProfile {
    case .teamMessage:
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

    case .teamPlanApproval:
        return ToolPermissionDecision(
            behavior: .allow,
            message: nil,
            reason: "team_plan_approval"
        )

    case .teamTaskStateUpdate:
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
    case let .argumentsEqual(arguments):
        return normalizedPermissionArguments(request.arguments) == normalizedPermissionArguments(arguments)
    }
}

private func normalizedPermissionArguments(_ arguments: String) -> String {
    guard let data = arguments.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data),
          JSONSerialization.isValidJSONObject(object),
          let normalizedData = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
          let normalizedText = String(data: normalizedData, encoding: .utf8)
    else {
        return arguments.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return normalizedText
}

private func fileReadPermissionDecision(for request: ToolRequest, tool: any ToolExecutor, context: ToolExecutionContext) -> ToolPermissionDecision? {
    guard tool.permissionProfile == .fileRead else {
        return nil
    }

    let path = permissionArgumentString(for: ["path", "file_path", "filePath"], in: request.arguments) ?? "."
    let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmedPath.hasPrefix("/") else {
        return ToolPermissionDecision(
            behavior: .allow,
            message: nil,
            reason: "read_only_tool"
        )
    }

    guard let scopeProvider = context.toolProvider as? ToolPermissionScopeProviding else {
        return .ask(
            message: String.localized("Tool execution requires approval because it reads an absolute path outside the known workspace scope."),
            reason: "absolute_read_path_requires_approval"
        )
    }

    let resolvedPath = normalizedPermissionPath(trimmedPath)
    let readableRoots = scopeProvider.toolPermissionReadableRootURLs.map { $0.standardizedFileURL.path }
    if readableRoots.contains(where: { isPermissionPath(resolvedPath, withinRoot: $0) }) {
        return ToolPermissionDecision(
            behavior: .allow,
            message: nil,
            reason: "read_only_tool"
        )
    }

    return .ask(
        message: String.localized("Tool execution requires approval because it reads an absolute path outside the allowed working directories."),
        reason: "absolute_read_path_requires_approval",
        approvedReadableRootURL: URL(fileURLWithPath: resolvedPath)
    )
}

private func isPermissionPath(_ path: String, withinRoot root: String) -> Bool {
    let normalizedPath = normalizedPermissionPath(path)
    let normalizedRoot = normalizedPermissionPath(root)
    if normalizedPath == normalizedRoot {
        return true
    }
    let rootWithSeparator = normalizedRoot.hasSuffix("/") ? normalizedRoot : normalizedRoot + "/"
    return normalizedPath.hasPrefix(rootWithSeparator)
}

private func parameterAwarePermissionDecision(for request: ToolRequest, tool: any ToolExecutor) -> ToolPermissionDecision? {
    if permissionPathArguments(in: request.arguments).contains(where: isSensitivePermissionPath) {
        return .ask(
            message: String.localized("Tool execution requires approval because it touches a sensitive path."),
            reason: "sensitive_path_requires_approval"
        )
    }

    if tool.permissionProfile == .fileDelete, deletesWorkspaceRoot(request.arguments) {
        return .ask(
            message: String.localized("Deleting the workspace root requires approval."),
            reason: "workspace_root_delete_requires_approval"
        )
    }

    return nil
}

private func bashPermissionDecision(for request: ToolRequest, tool: any ToolExecutor, mode: ToolPermissionMode) -> ToolPermissionDecision? {
    guard tool.permissionProfile == .bashCommand else {
        return nil
    }
    guard let classification = BashPermissionClassifier.default.classify(arguments: request.arguments) else {
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
    case .writeLocal:
        if mode == .auto {
            return ToolPermissionDecision(
                behavior: .allow,
                message: nil,
                reason: "permission_mode_auto_review"
            )
        }
        return .ask(
            message: String.localized("Bash command requires approval because it may modify local state, access the network, or has unknown risk."),
            reason: classification.reason
        )
    case .privilegeEscalation, .destructive, .sensitivePath:
        return .ask(
            message: String.localized("Bash command requires approval because it is potentially destructive, privileged, or touches a sensitive path."),
            reason: classification.reason
        )
    case .network, .unknown:
        return .ask(
            message: String.localized("Bash command requires approval because it may modify local state, access the network, or has unknown risk."),
            reason: classification.reason
        )
    }
}

private func allowsDefaultReviewedToolWithoutPrompt(tool: any ToolExecutor) -> Bool {
    switch tool.permissionProfile {
    case .autoReviewAllowedMutation,
         .autoReviewAllowedInstructionOrchestration,
         .cron:
        return true
    case .standard,
         .fileRead,
         .fileMutation,
         .fileDelete,
         .bashCommand,
         .internalStateMutation,
         .teamMessage,
         .teamPlanApproval,
         .teamTaskStateUpdate:
        return false
    }
}

private func allowsAutoReviewedToolWithoutPrompt(tool: any ToolExecutor) -> Bool {
    guard !tool.isReadOnly else { return true }

    switch tool.permissionProfile {
    case .fileMutation:
        return tool.isDestructive
    case .autoReviewAllowedMutation, .autoReviewAllowedInstructionOrchestration, .cron:
        return true
    case .standard,
         .fileRead,
         .fileDelete,
         .bashCommand,
         .internalStateMutation,
         .teamMessage,
         .teamPlanApproval,
         .teamTaskStateUpdate:
        return false
    }
}

private func deletesWorkspaceRoot(_ arguments: String) -> Bool {
    guard let path = permissionArgumentString(for: ["path"], in: arguments) else { return false }
    let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed == "." || trimmed == "./" || trimmed == "/"
}

private let permissionPathArgumentKeys = [
    "path",
    "file_path",
    "filePath",
    "input_path",
    "inputPath",
    "output_path",
    "outputPath",
    "script_path",
    "scriptPath",
]

private let sensitivePermissionPathFragments = [
    "/.ssh", "/.gnupg", "/.aws", "/.config", "/library/keychains",
    ".env", ".pem", ".key", "id_rsa", "id_ed25519",
]

private func isSensitivePermissionPath(_ path: String) -> Bool {
    let normalized = normalizedPermissionPath(path).lowercased()
    return sensitivePermissionPathFragments.contains { normalized.contains($0) }
}

private func containsSensitivePermissionPath(_ text: String) -> Bool {
    let lowered = text.lowercased()
    return sensitivePermissionPathFragments.contains { lowered.contains($0) }
}

private func permissionPathArguments(in arguments: String) -> [String] {
    permissionArgumentStrings(for: permissionPathArgumentKeys, in: arguments)
}

private func normalizedPermissionPath(_ path: String) -> String {
    NSString(string: path.trimmingCharacters(in: .whitespacesAndNewlines)).standardizingPath
}

private func permissionArgumentString(for keys: [String], in arguments: String) -> String? {
    permissionArgumentStrings(for: keys, in: arguments).first
}

private func permissionArgumentStrings(for keys: [String], in arguments: String) -> [String] {
    guard let data = arguments.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data),
          let dictionary = object as? [String: Any]
    else {
        return []
    }

    return keys.compactMap { key in
        dictionary[key] as? String
    }
}
