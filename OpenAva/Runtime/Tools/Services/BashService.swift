import Darwin
import Foundation
import UserNotifications

actor BashService {
    struct Request: Decodable {
        let command: String
        let timeout: Int?
        let description: String?
        let runInBackground: Bool?
        let dangerouslyDisableSandbox: Bool?

        enum CodingKeys: String, CodingKey {
            case command
            case timeout
            case description
            case runInBackground = "run_in_background"
            case dangerouslyDisableSandbox
        }
    }

    struct ExecutionPayload: Codable {
        let stdout: String
        let stderr: String
        let exitCode: Int32
        let interrupted: Bool
        let timedOut: Bool
        let durationMs: Int
        let backgroundTaskId: String?
        let outputPath: String?
        let persistedOutputPath: String?
        let truncated: Bool
        let noOutputExpected: Bool
        let cwd: String
    }

    private struct NormalizedRequest {
        let command: String
        let description: String?
        let timeoutMs: Int
        let runInBackground: Bool
        let workingDirectoryURL: URL
        let noOutputExpected: Bool
    }

    private struct ShellSnapshot {
        let shellPath: String
        let fileURL: URL?
    }

    private struct ShellInvocation {
        let shellPath: String
        let arguments: [String]
    }

    private struct BackgroundTaskRecord: Codable {
        enum Status: String, Codable {
            case running
            case completed
            case failed
            case interrupted
        }

        let id: String
        let command: String
        let description: String?
        let cwd: String
        let outputPath: String
        let startedAt: Date
        var finishedAt: Date?
        var exitCode: Int32?
        var status: Status
    }

    private struct PermissionResult {
        let workingDirectoryURL: URL
        let command: String
    }

    private final class LockedDataAccumulator: @unchecked Sendable {
        private let lock = NSLock()
        private let maxBytes: Int
        private var storage = Data()
        private(set) var totalBytes = 0

        init(maxBytes: Int) {
            self.maxBytes = maxBytes
        }

        func append(_ data: Data) {
            guard !data.isEmpty else { return }
            lock.lock()
            defer { lock.unlock() }

            totalBytes += data.count
            let remaining = max(0, maxBytes - storage.count)
            if remaining > 0 {
                storage.append(data.prefix(remaining))
            }
        }

        func snapshot() -> (data: Data, totalBytes: Int, truncated: Bool) {
            lock.lock()
            defer { lock.unlock() }
            return (storage, totalBytes, totalBytes > storage.count)
        }
    }

    private final class LockedFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false

        func set() {
            lock.lock()
            value = true
            lock.unlock()
        }

        func get() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    enum BashServiceError: LocalizedError {
        case unsupportedPlatform
        case workspaceUnavailable
        case invalidRequest(String)
        case executionFailed(String)

        var errorDescription: String? {
            switch self {
            case .unsupportedPlatform:
                return "Bash tool is only available on macOS-compatible OpenAva builds."
            case .workspaceUnavailable:
                return "Bash tool requires an active workspace."
            case let .invalidRequest(message):
                return message
            case let .executionFailed(message):
                return message
            }
        }
    }

    private static let inlineOutputLimit = 30000
    private static let maxCapturedOutputBytes = 1_000_000
    private static let defaultTimeoutMs = 120_000
    private static let maxTimeoutMs = 600_000
    private static let backgroundDirectoryName = "bash-tasks"
    private static let foregroundDirectoryName = "bash-results"
    private static let unsupportedShellPatterns = [
        #"\$\("#,
        #"`"#,
        #"<<(?:-|<)?"#,
        #"<\("#,
        #">\("#,
    ]
    private static let unsupportedCommandPatterns = [
        #"(^|[;&|]{1,2})\s*(eval|source|exec)\b"#,
        #"(^|[;&|]{1,2})\s*\.\s+"#,
        #"(^|[;&|]{1,2})\s*(sudo|su|ssh|sftp|scp|ftp|telnet|passwd)\b"#,
        #"(^|[;&|]{1,2})\s*(vim|vi|nano|emacs|less|more|man|top|htop|watch)\b"#,
        #"\bread\s+-"#,
    ]
    private static let maxCommandSegments = 50
    private static let dangerousEnvironmentVariables: Set<String> = [
        "BASH_ENV",
        "CDPATH",
        "DYLD_FRAMEWORK_PATH",
        "DYLD_INSERT_LIBRARIES",
        "DYLD_LIBRARY_PATH",
        "ENV",
        "GIT_CONFIG_COUNT",
        "GIT_CONFIG_GLOBAL",
        "GIT_CONFIG_SYSTEM",
        "IFS",
        "LD_AUDIT",
        "LD_LIBRARY_PATH",
        "LD_PRELOAD",
        "NODE_OPTIONS",
        "NODE_PATH",
        "PATH",
        "PERL5OPT",
        "PYTHONHOME",
        "PYTHONPATH",
        "RUBYOPT",
    ]
    private static let dangerousEnvironmentVariablePrefixes: [String] = ["DYLD_", "LD_"]
    private static let noOutputExpectedCommands: Set<String> = [
        "mkdir", "touch", "git add", "git checkout", "git switch", "git branch", "git commit",
        "git reset", "git restore", "git stash", "chmod", "chown", "ln", "mv", "cp", "rm",
        "npm install", "yarn install", "pnpm install", "bun install", "cargo build", "go build",
        "swift build", "xcodebuild",
    ]

    private let workspaceRootURL: URL?
    private let supportRootURL: URL?
    private let notificationCenter: any NotificationCentering
    private let environmentProvider: @Sendable () -> [String: String]
    private let homeDirectoryURL: URL
    private var cachedSearchPath: String?
    private var cachedShellSnapshot: ShellSnapshot?

    init(
        workspaceRootURL: URL? = nil,
        supportRootURL: URL? = nil,
        notificationCenter: any NotificationCentering = LiveNotificationCenter(),
        environmentProvider: @escaping @Sendable () -> [String: String] = { ProcessInfo.processInfo.environment },
        homeDirectoryURL: URL = {
            #if os(macOS)
                return FileManager.default.homeDirectoryForCurrentUser
            #else
                return URL(fileURLWithPath: NSHomeDirectory())
            #endif
        }()
    ) {
        self.workspaceRootURL = workspaceRootURL?.standardizedFileURL
        self.supportRootURL = supportRootURL?.standardizedFileURL
        self.notificationCenter = notificationCenter
        self.environmentProvider = environmentProvider
        self.homeDirectoryURL = homeDirectoryURL.standardizedFileURL
    }

    func execute(request: Request) async throws -> ExecutionPayload {
        let normalized = try normalize(request: request)
        if normalized.runInBackground {
            return try await executeInBackground(normalized)
        }
        return try await executeForeground(normalized)
    }

    private func normalize(request: Request) throws -> NormalizedRequest {
        let trimmedCommand = request.command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCommand.isEmpty else {
            throw BashServiceError.invalidRequest("command is required")
        }
        guard !trimmedCommand.contains("\0") else {
            throw BashServiceError.invalidRequest("command contains NUL bytes")
        }
        guard !trimmedCommand.contains("\n") else {
            throw BashServiceError.invalidRequest("command must be a single line; use ';' or '&&' instead of newlines")
        }

        let workspaceRootURL = try requireWorkspaceRootURL()
        let permissionResult = try bashToolHasPermission(command: trimmedCommand, workspaceRootURL: workspaceRootURL)
        let timeoutMs = normalizeTimeout(request.timeout)
        let trimmedDescription = request.description?.trimmingCharacters(in: .whitespacesAndNewlines)

        return NormalizedRequest(
            command: permissionResult.command,
            description: trimmedDescription?.isEmpty == false ? trimmedDescription : nil,
            timeoutMs: timeoutMs,
            runInBackground: request.runInBackground == true,
            workingDirectoryURL: permissionResult.workingDirectoryURL,
            noOutputExpected: noOutputExpected(command: permissionResult.command)
        )
    }

    private func requireWorkspaceRootURL() throws -> URL {
        guard let workspaceRootURL else {
            throw BashServiceError.workspaceUnavailable
        }
        return workspaceRootURL
    }

    private func normalizeTimeout(_ timeout: Int?) -> Int {
        let requested = timeout ?? Self.defaultTimeoutMs
        return min(max(requested, 1), Self.maxTimeoutMs)
    }

    private func bashToolHasPermission(command: String, workspaceRootURL: URL) throws -> PermissionResult {
        for pattern in Self.unsupportedShellPatterns where command.range(of: pattern, options: .regularExpression) != nil {
            throw BashServiceError.invalidRequest(
                "unsupported shell feature detected in command; command substitution, heredocs, and process substitution are disabled"
            )
        }
        for pattern in Self.unsupportedCommandPatterns where command.range(of: pattern, options: .regularExpression) != nil {
            throw BashServiceError.invalidRequest(
                "interactive or unsafe shell behavior is not allowed by the Bash tool permission policy"
            )
        }
        try validateCommandComplexity(command)
        try validateLeadingEnvironmentAssignments(command)
        try validateSedCommandSafety(command)

        if let cdResult = try normalizeLeadingChangeDirectory(command: command, workspaceRootURL: workspaceRootURL) {
            return cdResult
        }

        if command.range(of: #"(^|[;&|]{1,2})\s*cd\s+"#, options: .regularExpression) != nil {
            throw BashServiceError.invalidRequest(
                "only a single leading 'cd <path> && …' is supported, and it must stay within the active workspace"
            )
        }

        return PermissionResult(workingDirectoryURL: workspaceRootURL, command: command)
    }

    private func normalizeLeadingChangeDirectory(command: String, workspaceRootURL: URL) throws -> PermissionResult? {
        guard command.hasPrefix("cd ") else { return nil }
        guard let match = command.wholeMatch(of: /^cd\s+([^&;|]+)\s*&&\s*(.+)$/) else {
            throw BashServiceError.invalidRequest(
                "commands that start with 'cd' must use the form 'cd <workspace-relative-path> && <command>'"
            )
        }

        let rawPath = String(match.1).trimmingCharacters(in: .whitespacesAndNewlines)
        let innerCommand = String(match.2).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !innerCommand.isEmpty else {
            throw BashServiceError.invalidRequest("command after 'cd' is required")
        }

        let cleanedPath = unquote(rawPath)
        guard !cleanedPath.isEmpty else {
            throw BashServiceError.invalidRequest("directory path after 'cd' is required")
        }

        let candidateDirectory: URL
        if cleanedPath.hasPrefix("/") {
            candidateDirectory = URL(fileURLWithPath: cleanedPath, isDirectory: true)
        } else {
            candidateDirectory = workspaceRootURL.appendingPathComponent(cleanedPath, isDirectory: true)
        }

        let standardizedDirectory = candidateDirectory.standardizedFileURL
        guard isPathWithinRoot(standardizedDirectory, root: workspaceRootURL.standardizedFileURL) else {
            throw BashServiceError.invalidRequest("'cd' must remain within the active workspace")
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: standardizedDirectory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw BashServiceError.invalidRequest("directory for 'cd' does not exist within the active workspace")
        }

        let resolvedWorkspace = workspaceRootURL.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
        let resolvedDirectory = standardizedDirectory.resolvingSymlinksInPath().standardizedFileURL
        guard isPathWithinRoot(resolvedDirectory, root: resolvedWorkspace) else {
            throw BashServiceError.invalidRequest("'cd' must remain within the active workspace")
        }

        return PermissionResult(workingDirectoryURL: standardizedDirectory, command: innerCommand)
    }

    private func unquote(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return trimmed }
        if (trimmed.hasPrefix("\"") && trimmed.hasSuffix("\"")) || (trimmed.hasPrefix("'") && trimmed.hasSuffix("'")) {
            return String(trimmed.dropFirst().dropLast())
        }
        return trimmed
    }

    private func validateCommandComplexity(_ command: String) throws {
        let segments = topLevelCommandSegments(command)
        guard segments.count <= Self.maxCommandSegments else {
            throw BashServiceError.invalidRequest(
                "command is too complex for safe execution (\(segments.count) segments, max \(Self.maxCommandSegments))"
            )
        }
    }

    private func validateLeadingEnvironmentAssignments(_ command: String) throws {
        for segment in topLevelCommandSegments(command) {
            for variableName in leadingEnvironmentVariableNames(in: segment) {
                guard !isDangerousEnvironmentVariable(variableName) else {
                    throw BashServiceError.invalidRequest(
                        "dangerous environment variable assignment is not allowed by the Bash tool permission policy"
                    )
                }
            }
        }
    }

    private func validateSedCommandSafety(_ command: String) throws {
        for segment in topLevelCommandSegments(command) {
            let words = shellWords(in: segment)
            guard !words.isEmpty else { continue }

            var index = 0
            while index < words.count, leadingEnvironmentVariableName(in: words[index]) != nil {
                index += 1
            }
            guard index < words.count else { continue }

            let commandName = URL(fileURLWithPath: words[index]).lastPathComponent
            guard commandName == "sed" else { continue }

            let arguments = Array(words[(index + 1)...])
            try validateSedArguments(arguments)
        }
    }

    private func validateSedArguments(_ arguments: [String]) throws {
        guard !arguments.isEmpty else { return }

        var shouldValidateNextExpression = false
        for argument in arguments {
            if shouldValidateNextExpression {
                if containsDangerousSedExpression(argument) {
                    throw BashServiceError.invalidRequest(
                        "sed command uses a restricted expression (flags 'e' and 'w' are not allowed)"
                    )
                }
                shouldValidateNextExpression = false
                continue
            }

            if argument == "-e" || argument == "--expression" {
                shouldValidateNextExpression = true
                continue
            }

            if argument.hasPrefix("-e"), argument.count > 2 {
                let expression = String(argument.dropFirst(2))
                if containsDangerousSedExpression(expression) {
                    throw BashServiceError.invalidRequest(
                        "sed command uses a restricted expression (flags 'e' and 'w' are not allowed)"
                    )
                }
                continue
            }

            if argument == "-i" || argument.hasPrefix("-i") || argument == "--in-place" || argument.hasPrefix("--in-place=") {
                throw BashServiceError.invalidRequest(
                    "sed in-place editing is disabled by the Bash tool permission policy"
                )
            }

            if argument == "-f" || argument.hasPrefix("-f") || argument == "--file" || argument.hasPrefix("--file=") {
                throw BashServiceError.invalidRequest(
                    "sed script files are disabled by the Bash tool permission policy"
                )
            }

            if argument.hasPrefix("-") {
                continue
            }
            if containsDangerousSedExpression(argument) {
                throw BashServiceError.invalidRequest(
                    "sed command uses a restricted expression (flags 'e' and 'w' are not allowed)"
                )
            }
        }
    }

    private func containsDangerousSedExpression(_ rawExpression: String) -> Bool {
        let expression = unquote(rawExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !expression.isEmpty else { return false }

        if expression.range(of: #"(^|[;[:space:]])[wW]\s+\S"#, options: .regularExpression) != nil {
            return true
        }

        guard let flags = sedSubstitutionFlags(in: expression) else { return false }
        return flags.contains(where: { $0 == "e" || $0 == "w" || $0 == "W" })
    }

    private func sedSubstitutionFlags(in expression: String) -> String? {
        let trimmed = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let sIndex = trimmed.firstIndex(of: "s") else { return nil }
        let delimiterIndex = trimmed.index(after: sIndex)
        guard delimiterIndex < trimmed.endIndex else { return nil }
        let delimiter = trimmed[delimiterIndex]
        guard !delimiter.isLetter, !delimiter.isNumber, !delimiter.isWhitespace else { return nil }

        var index = trimmed.index(after: delimiterIndex)
        var escaped = false
        var delimitersSeen = 0
        while index < trimmed.endIndex {
            let character = trimmed[index]
            if escaped {
                escaped = false
                index = trimmed.index(after: index)
                continue
            }
            if character == "\\" {
                escaped = true
                index = trimmed.index(after: index)
                continue
            }
            if character == delimiter {
                delimitersSeen += 1
                if delimitersSeen == 2 {
                    let flagsStart = trimmed.index(after: index)
                    return String(trimmed[flagsStart...])
                }
            }
            index = trimmed.index(after: index)
        }
        return nil
    }

    private func leadingEnvironmentVariableNames(in segment: String) -> [String] {
        var variables: [String] = []
        for word in shellWords(in: segment) {
            guard let variableName = leadingEnvironmentVariableName(in: word) else {
                break
            }
            variables.append(variableName)
        }
        return variables
    }

    private func leadingEnvironmentVariableName(in word: String) -> String? {
        guard let equalsIndex = word.firstIndex(of: "=") else { return nil }
        guard equalsIndex != word.startIndex else { return nil }
        let name = String(word[..<equalsIndex])
        guard let firstCharacter = name.first,
              firstCharacter == "_" || firstCharacter.isLetter
        else {
            return nil
        }
        guard name.dropFirst().allSatisfy({ $0 == "_" || $0.isLetter || $0.isNumber }) else {
            return nil
        }
        return name
    }

    private func isDangerousEnvironmentVariable(_ variableName: String) -> Bool {
        let uppercased = variableName.uppercased()
        if Self.dangerousEnvironmentVariables.contains(uppercased) {
            return true
        }
        return Self.dangerousEnvironmentVariablePrefixes.contains { uppercased.hasPrefix($0) }
    }

    private func shellWords(in value: String) -> [String] {
        var words: [String] = []
        var current = ""
        var quote: Character?
        var escaping = false

        for character in value {
            if escaping {
                current.append(character)
                escaping = false
                continue
            }
            if character == "\\" {
                escaping = true
                continue
            }

            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                } else {
                    current.append(character)
                }
                continue
            }

            if character == "\"" || character == "'" {
                quote = character
                continue
            }

            if character.isWhitespace {
                if !current.isEmpty {
                    words.append(current)
                    current.removeAll(keepingCapacity: true)
                }
                continue
            }

            current.append(character)
        }

        if !current.isEmpty {
            words.append(current)
        }
        return words
    }

    private func topLevelCommandSegments(_ command: String) -> [String] {
        var segments: [String] = []
        var current = ""
        var quote: Character?
        var escaping = false
        var index = command.startIndex

        func flushCurrent() {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                segments.append(trimmed)
            }
            current.removeAll(keepingCapacity: true)
        }

        while index < command.endIndex {
            let character = command[index]

            if escaping {
                current.append(character)
                escaping = false
                index = command.index(after: index)
                continue
            }

            if character == "\\" {
                current.append(character)
                escaping = true
                index = command.index(after: index)
                continue
            }

            if let activeQuote = quote {
                current.append(character)
                if character == activeQuote {
                    quote = nil
                }
                index = command.index(after: index)
                continue
            }

            if character == "\"" || character == "'" {
                quote = character
                current.append(character)
                index = command.index(after: index)
                continue
            }

            if character == ";" {
                flushCurrent()
                index = command.index(after: index)
                continue
            }

            if character == "&" {
                let next = command.index(after: index)
                if next < command.endIndex, command[next] == "&" {
                    flushCurrent()
                    index = command.index(after: next)
                    continue
                }
            }

            if character == "|" {
                let next = command.index(after: index)
                flushCurrent()
                if next < command.endIndex, command[next] == "|" {
                    index = command.index(after: next)
                } else {
                    index = next
                }
                continue
            }

            current.append(character)
            index = command.index(after: index)
        }

        flushCurrent()
        return segments
    }

    private func isPathWithinRoot(_ candidate: URL, root: URL) -> Bool {
        let candidateComponents = candidate.standardizedFileURL.pathComponents
        let rootComponents = root.standardizedFileURL.pathComponents
        guard candidateComponents.count >= rootComponents.count else {
            return false
        }
        return zip(candidateComponents, rootComponents).allSatisfy { $0 == $1 }
    }

    private func noOutputExpected(command: String) -> Bool {
        let normalized = command.trimmingCharacters(in: .whitespacesAndNewlines)
        return Self.noOutputExpectedCommands.contains { prefix in
            normalized == prefix || normalized.hasPrefix(prefix + " ")
        }
    }

    private func makeEnvironment(workingDirectoryURL: URL) -> [String: String] {
        var environment = environmentProvider()
        environment["PATH"] = resolvedSearchPath(from: environment)
        environment["PWD"] = workingDirectoryURL.path
        environment["TERM"] = "dumb"
        environment["CLICOLOR"] = "0"
        environment["NO_COLOR"] = "1"
        environment["PAGER"] = "cat"
        environment["MANPAGER"] = "cat"
        environment["GIT_PAGER"] = "cat"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["CI"] = "1"
        return environment
    }

    private func resolvedSearchPath(from environment: [String: String]) -> String {
        if let cachedSearchPath {
            return cachedSearchPath
        }

        let searchPath = Self.mergeSearchPaths([
            captureUserShellSearchPath(baseEnvironment: environment),
            environment["PATH"],
            wellKnownSearchPath(),
        ])
        cachedSearchPath = searchPath
        return searchPath
    }

    private func wellKnownSearchPath() -> String {
        var paths = [
            homeDirectoryURL.appendingPathComponent(".local/bin", isDirectory: true).path,
            homeDirectoryURL.appendingPathComponent("go/bin", isDirectory: true).path,
            homeDirectoryURL.appendingPathComponent(".bun/bin", isDirectory: true).path,
            homeDirectoryURL.appendingPathComponent(".cargo/bin", isDirectory: true).path,
            homeDirectoryURL.appendingPathComponent(".npm-global/bin", isDirectory: true).path,
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ]
        paths.append(contentsOf: nvmNodeBinDirectories())
        return paths.joined(separator: ":")
    }

    private func nvmNodeBinDirectories() -> [String] {
        let versionsURL = homeDirectoryURL
            .appendingPathComponent(".nvm", isDirectory: true)
            .appendingPathComponent("versions", isDirectory: true)
            .appendingPathComponent("node", isDirectory: true)
        guard let versionNames = try? FileManager.default.contentsOfDirectory(atPath: versionsURL.path) else {
            return []
        }
        return versionNames
            .sorted(by: >)
            .map { versionsURL.appendingPathComponent($0, isDirectory: true).appendingPathComponent("bin", isDirectory: true).path }
    }

    private func captureUserShellSearchPath(baseEnvironment: [String: String]) -> String? {
        guard let shellPath = preferredShellPath(from: baseEnvironment) else {
            return nil
        }

        let configPath = shellConfigPath(for: shellPath)
        let script = [
            "if [ -f \(shellSingleQuoted(configPath)) ]; then . \(shellSingleQuoted(configPath)) >/dev/null 2>&1 || true; fi",
            "printf '%s' \"$PATH\"",
        ].joined(separator: "; ")

        var environment = baseEnvironment
        environment["HOME"] = homeDirectoryURL.path
        environment["SHELL"] = shellPath
        environment["GIT_EDITOR"] = "true"

        guard let output = runShellForOutput(shellPath: shellPath, arguments: ["-lc", script], environment: environment, timeoutMs: 5000) else {
            return nil
        }
        let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    private func preferredShellPath(from environment: [String: String]) -> String? {
        let candidates = [
            environment["SHELL"],
            "/bin/zsh",
            "/bin/bash",
            "/usr/bin/zsh",
            "/usr/bin/bash",
            "/opt/homebrew/bin/zsh",
            "/usr/local/bin/bash",
        ].compactMap { $0 }

        return candidates.first { path in
            (path.contains("zsh") || path.contains("bash")) && FileManager.default.isExecutableFile(atPath: path)
        }
    }

    private func shellConfigPath(for shellPath: String) -> String {
        if shellPath.contains("zsh") {
            return homeDirectoryURL.appendingPathComponent(".zshrc", isDirectory: false).path
        }
        if shellPath.contains("bash") {
            return homeDirectoryURL.appendingPathComponent(".bashrc", isDirectory: false).path
        }
        return homeDirectoryURL.appendingPathComponent(".profile", isDirectory: false).path
    }

    private static func mergeSearchPaths(_ pathValues: [String?]) -> String {
        var seen = Set<String>()
        var merged: [String] = []
        for pathValue in pathValues.compactMap({ $0 }) {
            for path in pathValue.split(separator: ":", omittingEmptySubsequences: true).map(String.init) {
                guard !seen.contains(path) else { continue }
                seen.insert(path)
                merged.append(path)
            }
        }
        return merged.joined(separator: ":")
    }

    private func runShellForOutput(
        shellPath: String,
        arguments: [String],
        environment: [String: String],
        timeoutMs: Int
    ) -> String? {
        var stdoutPipeFDs: [Int32] = [0, 0]
        guard pipe(&stdoutPipeFDs) == 0 else { return nil }

        let devNullFD = open("/dev/null", O_RDWR)
        guard devNullFD >= 0 else {
            close(stdoutPipeFDs[0])
            close(stdoutPipeFDs[1])
            return nil
        }

        var fileActions: posix_spawn_file_actions_t? = nil
        guard posix_spawn_file_actions_init(&fileActions) == 0 else {
            close(stdoutPipeFDs[0])
            close(stdoutPipeFDs[1])
            close(devNullFD)
            return nil
        }
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        guard posix_spawn_file_actions_adddup2(&fileActions, devNullFD, STDIN_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&fileActions, stdoutPipeFDs[1], STDOUT_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&fileActions, devNullFD, STDERR_FILENO) == 0
        else {
            close(stdoutPipeFDs[0])
            close(stdoutPipeFDs[1])
            close(devNullFD)
            return nil
        }

        let argv = [shellPath] + arguments
        let environmentEntries = environment.map { "\($0.key)=\($0.value)" }
        var processIdentifier: pid_t = 0
        let spawnStatus = Self.withCStringArray(argv) { argumentsPointer in
            Self.withCStringArray(environmentEntries) { environmentPointer in
                posix_spawn(&processIdentifier, shellPath, &fileActions, nil, argumentsPointer, environmentPointer)
            }
        }

        close(stdoutPipeFDs[1])
        close(devNullFD)

        guard spawnStatus == 0 else {
            close(stdoutPipeFDs[0])
            return nil
        }

        let exitCode = Self.blockingWaitForPID(processIdentifier, timeoutMs: timeoutMs)
        let accumulator = LockedDataAccumulator(maxBytes: 64 * 1024)
        Self.readAllFromDescriptor(stdoutPipeFDs[0], accumulator: accumulator)
        guard exitCode == 0 else {
            return nil
        }
        return String(decoding: accumulator.snapshot().data, as: UTF8.self)
    }

    private nonisolated static func blockingWaitForPID(_ processIdentifier: pid_t, timeoutMs: Int) -> Int32 {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
        var status: Int32 = 0
        while true {
            let result = waitpid(processIdentifier, &status, WNOHANG)
            if result == processIdentifier {
                if didExit(status) {
                    return exitStatus(status)
                }
                if wasSignaled(status) {
                    return terminatingSignal(status)
                }
                return status
            }
            if result == -1, errno != EINTR {
                return 1
            }
            if Date() >= deadline {
                _ = kill(processIdentifier, SIGTERM)
                usleep(100_000)
                if isProcessRunning(processIdentifier) {
                    _ = kill(processIdentifier, SIGKILL)
                }
                _ = waitpid(processIdentifier, &status, 0)
                return Int32(SIGTERM)
            }
            usleep(20000)
        }
    }

    private func storageDirectoryURL(named directoryName: String) -> URL {
        let baseURL = supportRootURL ?? workspaceRootURL ?? FileManager.default.temporaryDirectory
        return baseURL
            .appendingPathComponent(directoryName, isDirectory: true)
            .standardizedFileURL
    }

    private func outputPreviewText(from text: String) -> String {
        guard text.count > Self.inlineOutputLimit else { return text }
        return String(text.prefix(Self.inlineOutputLimit)) + "\n...\nOutput truncated."
    }

    private func makeShellInvocation(for request: NormalizedRequest, environment: [String: String]) -> ShellInvocation {
        let snapshot = shellSnapshot(baseEnvironment: environment)
        let command = makeShellCommand(for: request, snapshotURL: snapshot.fileURL)
        if snapshot.fileURL != nil {
            return ShellInvocation(shellPath: snapshot.shellPath, arguments: ["-c", command])
        }
        return ShellInvocation(shellPath: snapshot.shellPath, arguments: ["-lc", command])
    }

    private func makeShellCommand(for request: NormalizedRequest, snapshotURL: URL?) -> String {
        var commands: [String] = []
        if let snapshotURL {
            commands.append(". \(shellSingleQuoted(snapshotURL.path))")
        }
        commands.append("cd -- \(shellSingleQuoted(request.workingDirectoryURL.path))")
        commands.append("eval \(shellSingleQuoted(request.command))")
        return commands.joined(separator: " && ")
    }

    private func shellSnapshot(baseEnvironment: [String: String]) -> ShellSnapshot {
        if let cachedShellSnapshot {
            if let fileURL = cachedShellSnapshot.fileURL,
               !FileManager.default.fileExists(atPath: fileURL.path)
            {
                self.cachedShellSnapshot = nil
            } else {
                return cachedShellSnapshot
            }
        }

        let shellPath = preferredShellPath(from: baseEnvironment) ?? "/bin/bash"
        let snapshotURL = createShellSnapshot(shellPath: shellPath, baseEnvironment: baseEnvironment)
        let snapshot = ShellSnapshot(shellPath: shellPath, fileURL: snapshotURL)
        cachedShellSnapshot = snapshot
        return snapshot
    }

    private func createShellSnapshot(shellPath: String, baseEnvironment: [String: String]) -> URL? {
        let snapshotsDirectoryURL = storageDirectoryURL(named: "shell-snapshots")
        do {
            try FileManager.default.createDirectory(at: snapshotsDirectoryURL, withIntermediateDirectories: true)
        } catch {
            return nil
        }

        let snapshotURL = snapshotsDirectoryURL
            .appendingPathComponent("snapshot-\(UUID().uuidString)", isDirectory: false)
            .appendingPathExtension("sh")
        let configPath = shellConfigPath(for: shellPath)
        let script = makeShellSnapshotCreationScript(snapshotPath: snapshotURL.path, configPath: configPath)

        var environment = baseEnvironment
        environment["HOME"] = homeDirectoryURL.path
        environment["SHELL"] = shellPath
        environment["GIT_EDITOR"] = "true"
        environment["OPENAVA_SHELL_SNAPSHOT"] = "1"

        guard runShellForOutput(shellPath: shellPath, arguments: ["-lc", script], environment: environment, timeoutMs: 5000) != nil,
              FileManager.default.fileExists(atPath: snapshotURL.path),
              ((try? FileManager.default.attributesOfItem(atPath: snapshotURL.path)[.size] as? NSNumber)?.intValue ?? 0) > 0
        else {
            try? FileManager.default.removeItem(at: snapshotURL)
            return nil
        }
        return snapshotURL
    }

    private func makeShellSnapshotCreationScript(snapshotPath: String, configPath: String) -> String {
        let quotedSnapshotPath = shellSingleQuoted(snapshotPath)
        let quotedConfigPath = shellSingleQuoted(configPath)
        return """
        SNAPSHOT_FILE=\(quotedSnapshotPath)
        CONFIG_FILE=\(quotedConfigPath)
        if [ -f "$CONFIG_FILE" ]; then . "$CONFIG_FILE" </dev/null >/dev/null 2>&1 || true; fi
        {
          printf '%s\\n' '# Snapshot file'
          printf '%s\\n' 'unalias -a 2>/dev/null || true'
          printf '%s\\n' 'shopt -s expand_aliases 2>/dev/null || true'
          printf '%s\\n' 'setopt aliases 2>/dev/null || true'
          printf '%s\\n' ''
          printf '%s\\n' '# Functions'
          if [ -n "${BASH_VERSION:-}" ]; then
            declare -f 2>/dev/null || true
          elif [ -n "${ZSH_VERSION:-}" ]; then
            typeset -f 2>/dev/null || true
          else
            typeset -f 2>/dev/null || declare -f 2>/dev/null || true
          fi
          printf '%s\\n' ''
          printf '%s\\n' '# Aliases'
          if [ -n "${ZSH_VERSION:-}" ]; then
            alias -L 2>/dev/null || true
          else
            alias 2>/dev/null || true
          fi
          printf '%s\\n' ''
          escaped_path=$(printf '%s' "$PATH" | sed "s/'/'\\\\''/g")
          printf "export PATH='%s'\\n" "$escaped_path"
        } >| "$SNAPSHOT_FILE"
        test -s "$SNAPSHOT_FILE"
        """
    }

    private func shellSingleQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
    }

    private func spawnShellProcess(
        shellPath: String,
        arguments: [String],
        environment: [String: String],
        stdinFD: Int32,
        stdoutFD: Int32,
        stderrFD: Int32
    ) throws -> pid_t {
        var fileActions: posix_spawn_file_actions_t? = nil
        let initStatus = posix_spawn_file_actions_init(&fileActions)
        guard initStatus == 0 else {
            throw BashServiceError.executionFailed(String(cString: strerror(initStatus)))
        }
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        for (sourceFD, targetFD) in [(stdinFD, STDIN_FILENO), (stdoutFD, STDOUT_FILENO), (stderrFD, STDERR_FILENO)] {
            let status = posix_spawn_file_actions_adddup2(&fileActions, sourceFD, targetFD)
            guard status == 0 else {
                throw BashServiceError.executionFailed(String(cString: strerror(status)))
            }
        }

        for fileDescriptor in Set([stdinFD, stdoutFD, stderrFD]) where fileDescriptor > STDERR_FILENO {
            let status = posix_spawn_file_actions_addclose(&fileActions, fileDescriptor)
            guard status == 0 else {
                throw BashServiceError.executionFailed(String(cString: strerror(status)))
            }
        }

        let environmentEntries = environment.map { "\($0.key)=\($0.value)" }
        let argv = [shellPath] + arguments
        var processIdentifier: pid_t = 0
        let spawnStatus = try Self.withCStringArray(argv) { argumentsPointer in
            try Self.withCStringArray(environmentEntries) { environmentPointer in
                posix_spawn(&processIdentifier, shellPath, &fileActions, nil, argumentsPointer, environmentPointer)
            }
        }

        guard spawnStatus == 0 else {
            throw BashServiceError.executionFailed(String(cString: strerror(spawnStatus)))
        }
        return processIdentifier
    }

    private nonisolated static func withCStringArray<Result>(
        _ strings: [String],
        _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) throws -> Result
    ) rethrows -> Result {
        var cStrings = strings.map { strdup($0) }
        defer { cStrings.forEach { free($0) } }
        cStrings.append(nil)
        return try cStrings.withUnsafeMutableBufferPointer { buffer in
            try body(buffer.baseAddress!)
        }
    }

    private nonisolated static func readAllFromDescriptor(_ fileDescriptor: Int32, accumulator: LockedDataAccumulator) {
        defer { close(fileDescriptor) }

        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        while true {
            let bytesRead = read(fileDescriptor, buffer, bufferSize)
            if bytesRead > 0 {
                accumulator.append(Data(bytes: buffer, count: bytesRead))
                continue
            }

            if bytesRead == -1, errno == EINTR {
                continue
            }
            break
        }
    }

    private nonisolated static func blockingWaitForPID(_ processIdentifier: pid_t) -> Int32 {
        var status: Int32 = 0
        while true {
            let result = waitpid(processIdentifier, &status, 0)
            if result == processIdentifier {
                if didExit(status) {
                    return exitStatus(status)
                }
                if wasSignaled(status) {
                    return terminatingSignal(status)
                }
                return status
            }
            if result == -1, errno == EINTR {
                continue
            }
            return 1
        }
    }

    private nonisolated static func isProcessRunning(_ processIdentifier: pid_t) -> Bool {
        guard processIdentifier > 0 else { return false }
        if kill(processIdentifier, 0) == 0 {
            return true
        }
        return errno == EPERM
    }

    private nonisolated static func didExit(_ status: Int32) -> Bool {
        (status & 0x7F) == 0
    }

    private nonisolated static func exitStatus(_ status: Int32) -> Int32 {
        (status >> 8) & 0xFF
    }

    private nonisolated static func wasSignaled(_ status: Int32) -> Bool {
        let signal = status & 0x7F
        return signal != 0 && signal != 0x7F
    }

    private nonisolated static func terminatingSignal(_ status: Int32) -> Int32 {
        status & 0x7F
    }

    private func writePersistedOutput(command: String, cwd: String, stdout: String, stderr: String) throws -> URL {
        let directoryURL = storageDirectoryURL(named: Self.foregroundDirectoryName)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let fileURL = directoryURL.appendingPathComponent(UUID().uuidString).appendingPathExtension("txt")
        let content = [
            "$ \(command)",
            "cwd: \(cwd)",
            "",
            "--- stdout ---",
            stdout,
            "",
            "--- stderr ---",
            stderr,
        ].joined(separator: "\n")
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }

    #if os(macOS) || targetEnvironment(macCatalyst)
        private func executeForeground(_ request: NormalizedRequest) async throws -> ExecutionPayload {
            var stdoutPipeFDs: [Int32] = [0, 0]
            guard pipe(&stdoutPipeFDs) == 0 else {
                throw BashServiceError.executionFailed(String(cString: strerror(errno)))
            }

            var stderrPipeFDs: [Int32] = [0, 0]
            guard pipe(&stderrPipeFDs) == 0 else {
                close(stdoutPipeFDs[0])
                close(stdoutPipeFDs[1])
                throw BashServiceError.executionFailed(String(cString: strerror(errno)))
            }

            let devNullFD = open("/dev/null", O_RDONLY)
            guard devNullFD >= 0 else {
                close(stdoutPipeFDs[0])
                close(stdoutPipeFDs[1])
                close(stderrPipeFDs[0])
                close(stderrPipeFDs[1])
                throw BashServiceError.executionFailed(String(cString: strerror(errno)))
            }

            let stdoutAccumulator = LockedDataAccumulator(maxBytes: Self.maxCapturedOutputBytes)
            let stderrAccumulator = LockedDataAccumulator(maxBytes: Self.maxCapturedOutputBytes)
            let timedOut = LockedFlag()

            let processIdentifier: pid_t
            do {
                let environment = makeEnvironment(workingDirectoryURL: request.workingDirectoryURL)
                let invocation = makeShellInvocation(for: request, environment: environment)
                processIdentifier = try spawnShellProcess(
                    shellPath: invocation.shellPath,
                    arguments: invocation.arguments,
                    environment: environment,
                    stdinFD: devNullFD,
                    stdoutFD: stdoutPipeFDs[1],
                    stderrFD: stderrPipeFDs[1]
                )
            } catch {
                close(devNullFD)
                close(stdoutPipeFDs[0])
                close(stdoutPipeFDs[1])
                close(stderrPipeFDs[0])
                close(stderrPipeFDs[1])
                throw error
            }

            close(devNullFD)
            close(stdoutPipeFDs[1])
            close(stderrPipeFDs[1])

            let stdoutTask = Task.detached(priority: .utility) {
                Self.readAllFromDescriptor(stdoutPipeFDs[0], accumulator: stdoutAccumulator)
            }
            let stderrTask = Task.detached(priority: .utility) {
                Self.readAllFromDescriptor(stderrPipeFDs[0], accumulator: stderrAccumulator)
            }

            let startedAt = Date()
            let exitCode = await waitForProcessExit(
                processIdentifier,
                timeoutMs: request.timeoutMs,
                timedOut: timedOut
            )

            _ = await stdoutTask.value
            _ = await stderrTask.value

            let stdoutSnapshot = stdoutAccumulator.snapshot()
            let stderrSnapshot = stderrAccumulator.snapshot()
            let stdout = String(decoding: stdoutSnapshot.data, as: UTF8.self)
            let stderr = String(decoding: stderrSnapshot.data, as: UTF8.self)

            let truncated = stdoutSnapshot.truncated || stderrSnapshot.truncated || (stdout.count + stderr.count > Self.inlineOutputLimit)
            let persistedOutputPath: String?
            if truncated {
                persistedOutputPath = try? writePersistedOutput(
                    command: request.command,
                    cwd: request.workingDirectoryURL.path,
                    stdout: stdout,
                    stderr: stderr
                ).path
            } else {
                persistedOutputPath = nil
            }

            return ExecutionPayload(
                stdout: truncated ? outputPreviewText(from: stdout) : stdout,
                stderr: truncated ? outputPreviewText(from: stderr) : stderr,
                exitCode: exitCode,
                interrupted: timedOut.get(),
                timedOut: timedOut.get(),
                durationMs: Int(Date().timeIntervalSince(startedAt) * 1000),
                backgroundTaskId: nil,
                outputPath: nil,
                persistedOutputPath: persistedOutputPath,
                truncated: truncated,
                noOutputExpected: request.noOutputExpected,
                cwd: request.workingDirectoryURL.path
            )
        }

        private func executeInBackground(_ request: NormalizedRequest) async throws -> ExecutionPayload {
            let taskID = UUID().uuidString
            let taskDirectoryURL = storageDirectoryURL(named: Self.backgroundDirectoryName)
            try FileManager.default.createDirectory(at: taskDirectoryURL, withIntermediateDirectories: true)

            let outputURL = taskDirectoryURL.appendingPathComponent(taskID).appendingPathExtension("log")
            let metadataURL = taskDirectoryURL.appendingPathComponent(taskID).appendingPathExtension("json")
            FileManager.default.createFile(atPath: outputURL.path, contents: nil)
            let outputFD = open(outputURL.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
            guard outputFD >= 0 else {
                throw BashServiceError.executionFailed(String(cString: strerror(errno)))
            }

            let devNullFD = open("/dev/null", O_RDONLY)
            guard devNullFD >= 0 else {
                close(outputFD)
                throw BashServiceError.executionFailed(String(cString: strerror(errno)))
            }

            let initialRecord = BackgroundTaskRecord(
                id: taskID,
                command: request.command,
                description: request.description,
                cwd: request.workingDirectoryURL.path,
                outputPath: outputURL.path,
                startedAt: Date(),
                finishedAt: nil,
                exitCode: nil,
                status: .running
            )
            try writeBackgroundTaskRecord(initialRecord, to: metadataURL)

            let processIdentifier: pid_t
            do {
                let environment = makeEnvironment(workingDirectoryURL: request.workingDirectoryURL)
                let invocation = makeShellInvocation(for: request, environment: environment)
                processIdentifier = try spawnShellProcess(
                    shellPath: invocation.shellPath,
                    arguments: invocation.arguments,
                    environment: environment,
                    stdinFD: devNullFD,
                    stdoutFD: outputFD,
                    stderrFD: outputFD
                )
            } catch {
                close(devNullFD)
                close(outputFD)
                throw error
            }

            close(devNullFD)
            close(outputFD)

            Task.detached(priority: .utility) { [weak self] in
                let exitCode = Self.blockingWaitForPID(processIdentifier)
                guard let self else { return }
                await self.finishBackgroundTask(
                    record: initialRecord,
                    metadataURL: metadataURL,
                    exitCode: exitCode
                )
            }

            return ExecutionPayload(
                stdout: "",
                stderr: "",
                exitCode: 0,
                interrupted: false,
                timedOut: false,
                durationMs: 0,
                backgroundTaskId: taskID,
                outputPath: outputURL.path,
                persistedOutputPath: metadataURL.path,
                truncated: false,
                noOutputExpected: request.noOutputExpected,
                cwd: request.workingDirectoryURL.path
            )
        }

        private func waitForProcessExit(
            _ processIdentifier: pid_t,
            timeoutMs: Int,
            timedOut: LockedFlag
        ) async -> Int32 {
            let timeoutNanoseconds = UInt64(timeoutMs) * 1_000_000
            let exitTask = Task.detached(priority: .utility) {
                Self.blockingWaitForPID(processIdentifier)
            }

            let timeoutTask = Task.detached(priority: .utility) {
                do {
                    try await Task.sleep(nanoseconds: timeoutNanoseconds)
                } catch {
                    return
                }
                guard Self.isProcessRunning(processIdentifier) else { return }
                timedOut.set()
                _ = kill(processIdentifier, SIGTERM)
                try? await Task.sleep(nanoseconds: 500_000_000)
                if Self.isProcessRunning(processIdentifier) {
                    _ = kill(processIdentifier, SIGKILL)
                }
            }

            let status = await exitTask.value
            timeoutTask.cancel()
            return status
        }

        private func writeBackgroundTaskRecord(_ record: BackgroundTaskRecord, to url: URL) throws {
            let data = try JSONEncoder().encode(record)
            try data.write(to: url, options: [.atomic])
        }

        private func finishBackgroundTask(record: BackgroundTaskRecord, metadataURL: URL, exitCode: Int32) async {
            var updated = record
            updated.finishedAt = Date()
            updated.exitCode = exitCode
            updated.status = switch exitCode {
            case 0: .completed
            case Int32(SIGTERM), Int32(SIGKILL): .interrupted
            default: .failed
            }

            try? writeBackgroundTaskRecord(updated, to: metadataURL)
            try? await postBackgroundCompletionNotification(record: updated)
        }

        private func postBackgroundCompletionNotification(record: BackgroundTaskRecord) async throws {
            let status = await notificationCenter.authorizationStatus()
            switch status {
            case .authorized, .provisional, .ephemeral:
                break
            default:
                return
            }

            let content = UNMutableNotificationContent()
            content.title = record.status == .completed ? "Bash task completed" : "Bash task finished"
            content.body = record.description ?? record.command
            content.sound = .default

            let request = UNNotificationRequest(
                identifier: "bash-task.\(record.id)",
                content: content,
                trigger: nil
            )
            try await notificationCenter.add(request)
        }
    #else
        private func executeForeground(_ request: NormalizedRequest) async throws -> ExecutionPayload {
            _ = request
            throw BashServiceError.unsupportedPlatform
        }

        private func executeInBackground(_ request: NormalizedRequest) async throws -> ExecutionPayload {
            _ = request
            throw BashServiceError.unsupportedPlatform
        }
    #endif
}
