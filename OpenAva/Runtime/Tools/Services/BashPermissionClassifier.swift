import Foundation

enum BashCommandRisk: String, Codable, Equatable {
    case readOnly
    case writeLocal
    case network
    case destructive
    case privilegeEscalation
    case sensitivePath
    case unknown
}

struct BashPermissionClassification: Equatable {
    let command: String
    let risk: BashCommandRisk
    let reason: String
}

struct BashPermissionClassifier {
    static let `default` = BashPermissionClassifier()

    func classify(arguments: String) -> BashPermissionClassification? {
        guard let command = permissionArgumentString(for: ["command"], in: arguments)?.trimmingCharacters(in: .whitespacesAndNewlines), !command.isEmpty else {
            return nil
        }
        return classify(command: command)
    }

    func classify(command: String) -> BashPermissionClassification {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased()

        if matchesAnyBashPattern(lowered, patterns: Self.privilegeEscalationBashPatterns) {
            return BashPermissionClassification(command: trimmed, risk: .privilegeEscalation, reason: "bash_privilege_escalation_requires_approval")
        }
        if matchesAnyBashPattern(lowered, patterns: Self.destructiveBashPatterns) {
            return BashPermissionClassification(command: trimmed, risk: .destructive, reason: "bash_destructive_command_requires_approval")
        }
        if containsSensitivePermissionPath(trimmed) {
            return BashPermissionClassification(command: trimmed, risk: .sensitivePath, reason: "bash_sensitive_path_requires_approval")
        }
        if isReadOnlyBashCommand(lowered) {
            return BashPermissionClassification(command: trimmed, risk: .readOnly, reason: "bash_read_only_command")
        }
        if matchesAnyBashPattern(lowered, patterns: Self.networkBashPatterns) {
            return BashPermissionClassification(command: trimmed, risk: .network, reason: "bash_network_command_requires_approval")
        }
        if matchesAnyBashPattern(lowered, patterns: Self.writeLocalBashPatterns) {
            return BashPermissionClassification(command: trimmed, risk: .writeLocal, reason: "bash_write_command_requires_approval")
        }

        return BashPermissionClassification(command: trimmed, risk: .unknown, reason: "bash_unknown_command_requires_approval")
    }

    private static let privilegeEscalationBashPatterns = [
        #"(^|[;&|]{1,2})\s*(sudo|su|doas)\b"#,
    ]

    private static let destructiveBashPatterns = [
        #"(^|[;&|]{1,2})\s*rm\b"#,
        #"(^|[;&|]{1,2})\s*(dd|mkfs|diskutil)\b"#,
        #"chmod\s+-r\s+777\b"#,
        #"(^|[;&|]{1,2})\s*find\b.*\s-delete\b"#,
        #"(curl|wget)\b.*\|\s*(sh|bash)\b"#,
        #"(^|[;&|]{1,2})\s*git\s+(reset\s+--hard|clean\s+-)"#,
    ]

    private static let networkBashPatterns = [
        #"(^|[;&|]{1,2})\s*(curl|wget|scp|sftp|ssh|ftp|telnet)\b"#,
    ]

    private static let writeLocalBashPatterns = [
        #"(^|[;&|]{1,2})\s*(npm|pnpm|yarn|bun)\s+(install|add|remove|update)\b"#,
        #"(^|[;&|]{1,2})\s*go\s+(mod\s+tidy|build|test|generate|fmt|vet)\b"#,
        #"(^|[;&|]{1,2})\s*cargo\s+(build|test|check|fmt|clippy)\b"#,
        #"(^|[;&|]{1,2})\s*swift\s+(build|test|package)\b"#,
        #"(^|[;&|]{1,2})\s*xcodebuild\b"#,
        #"(^|[;&|]{1,2})\s*(gofmt\s+-w|prettier\s+.*--write|eslint\s+.*--fix|ruff\s+format|black|swiftformat)\b"#,
        #"(^|[;&|]{1,2})\s*(mkdir|touch|mv|cp|chmod|chown|ln)\b"#,
        #"(^|[;&|]{1,2})\s*git\s+(checkout|switch|restore|stash|commit|add|pull|fetch|merge|rebase)\b"#,
    ]

    private static let readOnlyBashCommandPrefixes: [String] = [
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

    private static let sensitivePermissionPathFragments = [
        "/.ssh", "/.gnupg", "/.aws", "/.config", "/library/keychains",
        ".env", ".pem", ".key", "id_rsa", "id_ed25519",
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
            return Self.readOnlyBashCommandPrefixes.contains { prefix in
                normalized == prefix || normalized.hasPrefix(prefix + " ")
            }
        }
    }

    private func matchesAnyBashPattern(_ command: String, patterns: [String]) -> Bool {
        patterns.contains { command.range(of: $0, options: .regularExpression) != nil }
    }

    private func containsSensitivePermissionPath(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return Self.sensitivePermissionPathFragments.contains { lowered.contains($0) }
    }

    private func permissionArgumentString(for keys: [String], in arguments: String) -> String? {
        guard let data = arguments.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any]
        else {
            return nil
        }

        return keys.compactMap { key in
            dictionary[key] as? String
        }.first
    }
}
