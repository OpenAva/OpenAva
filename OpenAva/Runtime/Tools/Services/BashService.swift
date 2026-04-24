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
    private static let noOutputExpectedCommands: Set<String> = [
        "mkdir", "touch", "git add", "git checkout", "git switch", "git branch", "git commit",
        "git reset", "git restore", "git stash", "chmod", "chown", "ln", "mv", "cp", "rm",
        "npm install", "yarn install", "pnpm install", "bun install", "cargo build", "go build",
        "swift build", "xcodebuild",
    ]

    private let workspaceRootURL: URL?
    private let runtimeRootURL: URL?
    private let notificationCenter: any NotificationCentering

    init(
        workspaceRootURL: URL? = nil,
        runtimeRootURL: URL? = nil,
        notificationCenter: any NotificationCentering = LiveNotificationCenter()
    ) {
        self.workspaceRootURL = workspaceRootURL?.standardizedFileURL
        self.runtimeRootURL = runtimeRootURL?.standardizedFileURL
        self.notificationCenter = notificationCenter
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
        guard standardizedDirectory.path.hasPrefix(workspaceRootURL.path + "/") || standardizedDirectory.path == workspaceRootURL.path else {
            throw BashServiceError.invalidRequest("'cd' must remain within the active workspace")
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: standardizedDirectory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw BashServiceError.invalidRequest("directory for 'cd' does not exist within the active workspace")
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

    private func noOutputExpected(command: String) -> Bool {
        let normalized = command.trimmingCharacters(in: .whitespacesAndNewlines)
        return Self.noOutputExpectedCommands.contains { prefix in
            normalized == prefix || normalized.hasPrefix(prefix + " ")
        }
    }

    private func makeEnvironment(workingDirectoryURL: URL) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
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

    private func runtimeDirectoryURL(named directoryName: String) -> URL {
        let baseURL = runtimeRootURL ?? workspaceRootURL ?? FileManager.default.temporaryDirectory
        return baseURL
            .appendingPathComponent(directoryName, isDirectory: true)
            .standardizedFileURL
    }

    private func outputPreviewText(from text: String) -> String {
        guard text.count > Self.inlineOutputLimit else { return text }
        return String(text.prefix(Self.inlineOutputLimit)) + "\n...\nOutput truncated."
    }

    private func makeShellCommand(for request: NormalizedRequest) -> String {
        "cd -- \(shellSingleQuoted(request.workingDirectoryURL.path)) && \(request.command)"
    }

    private func shellSingleQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
    }

    private func spawnBashProcess(
        command: String,
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
        var processIdentifier: pid_t = 0
        let spawnStatus = try Self.withCStringArray(["/bin/bash", "-lc", command]) { argumentsPointer in
            try Self.withCStringArray(environmentEntries) { environmentPointer in
                posix_spawn(&processIdentifier, "/bin/bash", &fileActions, nil, argumentsPointer, environmentPointer)
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
        let directoryURL = runtimeDirectoryURL(named: Self.foregroundDirectoryName)
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
                processIdentifier = try spawnBashProcess(
                    command: makeShellCommand(for: request),
                    environment: makeEnvironment(workingDirectoryURL: request.workingDirectoryURL),
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
            let taskDirectoryURL = runtimeDirectoryURL(named: Self.backgroundDirectoryName)
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
                processIdentifier = try spawnBashProcess(
                    command: makeShellCommand(for: request),
                    environment: makeEnvironment(workingDirectoryURL: request.workingDirectoryURL),
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
