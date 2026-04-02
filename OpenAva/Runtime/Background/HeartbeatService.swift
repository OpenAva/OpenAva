import ChatClient
import ChatUI
import Foundation
import MemoryKit
import OSLog
import UIKit
import UserNotifications

@MainActor
struct HeartbeatRuntimeConfiguration {
    let agentID: String?
    let agentName: String
    let agentEmoji: String
    let workspaceRootURL: URL
    let runtimeRootURL: URL
    let baseSystemPrompt: String?
    let chatClient: any ChatClient
    let modelConfig: AppConfig.LLMModel
    let toolInvokeService: LocalToolInvokeService
    let autoCompactEnabled: Bool
}

@MainActor
final class HeartbeatService {
    static let shared = HeartbeatService()

    private struct State: Codable {
        var lastCheckAt: TimeInterval
    }

    fileprivate enum ExecutionOutcome {
        case success
        case failure(String?)
        case interrupted(String)
    }

    private struct RunResult {
        let notificationBody: String?
        let shouldNotify: Bool
    }

    private static let logger = Logger(subsystem: "com.day1-labs.openava", category: "runtime.heartbeat")

    private var loopTask: Task<Void, Never>?
    private var currentConfiguration: HeartbeatRuntimeConfiguration?
    private var isRunning = false

    private init() {}

    func reconfigure(_ configuration: HeartbeatRuntimeConfiguration?) {
        stop()
        currentConfiguration = configuration
        guard let configuration else { return }

        loopTask = Task { [weak self] in
            await self?.runLoop(configuration)
        }
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
        currentConfiguration = nil
        isRunning = false
    }

    @discardableResult
    func requestRunNow() async -> Bool {
        guard let configuration = currentConfiguration,
              let heartbeatMarkdown = loadHeartbeatMarkdown(from: configuration.workspaceRootURL)
        else {
            return false
        }

        let parsedDocument = HeartbeatSupport.parseDocument(heartbeatMarkdown)
        return await performHeartbeatIfNeeded(
            configuration,
            parsedDocument: parsedDocument,
            force: true
        )
    }

    private func runLoop(_ configuration: HeartbeatRuntimeConfiguration) async {
        while !Task.isCancelled {
            let delay = nextDelay(for: configuration)
            if delay > 0 {
                do {
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                } catch {
                    return
                }
            }

            guard !Task.isCancelled else { return }
            guard let heartbeatMarkdown = loadHeartbeatMarkdown(from: configuration.workspaceRootURL) else {
                continue
            }
            let parsedDocument = HeartbeatSupport.parseDocument(heartbeatMarkdown)
            _ = await performHeartbeatIfNeeded(
                configuration,
                parsedDocument: parsedDocument,
                force: false
            )
        }
    }

    private func nextDelay(for configuration: HeartbeatRuntimeConfiguration) -> TimeInterval {
        guard let heartbeatMarkdown = loadHeartbeatMarkdown(from: configuration.workspaceRootURL) else {
            return 60
        }

        let parsedDocument = HeartbeatSupport.parseDocument(heartbeatMarkdown)
        let now = Date().timeIntervalSince1970
        guard let state = loadState(for: configuration.runtimeRootURL) else {
            if let activeDelay = parsedDocument.configuration.delayUntilActive(from: Date()), activeDelay > 0 {
                return activeDelay
            }
            return 0
        }

        let elapsed = now - state.lastCheckAt
        let dueDelay = max(0, parsedDocument.configuration.interval - elapsed)
        if dueDelay > 0 {
            return dueDelay
        }

        if let activeDelay = parsedDocument.configuration.delayUntilActive(from: Date()), activeDelay > 0 {
            return activeDelay
        }

        return 0
    }

    private func performHeartbeatIfNeeded(
        _ configuration: HeartbeatRuntimeConfiguration,
        parsedDocument: HeartbeatSupport.ParsedDocument,
        force: Bool
    ) async -> Bool {
        if isRunning {
            Self.logger.debug("skip heartbeat because another heartbeat run is active")
            return false
        }

        if !force {
            if let activeDelay = parsedDocument.configuration.delayUntilActive(from: Date()), activeDelay > 0 {
                return false
            }

            if ConversationSessionManager.shared.hasExecutingSession() {
                Self.logger.debug("skip heartbeat because another session is executing")
                return false
            }

            if let state = loadState(for: configuration.runtimeRootURL) {
                let elapsed = Date().timeIntervalSince1970 - state.lastCheckAt
                if elapsed < parsedDocument.configuration.interval {
                    return false
                }
            }
        } else if ConversationSessionManager.shared.hasExecutingSession() {
            Self.logger.debug("skip manual heartbeat because another session is executing")
            return false
        }

        isRunning = true
        defer { isRunning = false }
        let runStartedAt = Date().timeIntervalSince1970

        do {
            let result = try await executeHeartbeat(
                configuration,
                heartbeatMarkdown: parsedDocument.instructions,
                notificationMode: parsedDocument.configuration.notify
            )
            persistState(.init(lastCheckAt: runStartedAt), for: configuration.runtimeRootURL)
            guard result.shouldNotify,
                  let notificationBody = result.notificationBody
            else {
                return true
            }
            try await postNotification(agentName: configuration.agentName, agentEmoji: configuration.agentEmoji, body: notificationBody)
            return true
        } catch {
            persistState(.init(lastCheckAt: runStartedAt), for: configuration.runtimeRootURL)
            Self.logger.error("heartbeat failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func executeHeartbeat(
        _ configuration: HeartbeatRuntimeConfiguration,
        heartbeatMarkdown: String,
        notificationMode: HeartbeatSupport.Configuration.NotificationMode
    ) async throws -> RunResult {
        let conversationID = HeartbeatSupport.conversationID(for: configuration.agentID)
        let storageProvider = TranscriptStorageProvider.provider(runtimeRootURL: configuration.runtimeRootURL)
        let baselineMessages = HeartbeatSupport.trimToRecent(
            storageProvider.messages(in: conversationID),
            limit: HeartbeatSupport.retainMessageLimit
        )

        ConversationSessionManager.shared.removeSession(for: conversationID)
        storageProvider.setTitle("Heartbeat", for: conversationID)

        let agentDelegate = AgentSessionDelegate(
            conversationID: conversationID,
            workspaceRootURL: configuration.workspaceRootURL,
            runtimeRootURL: configuration.runtimeRootURL,
            baseSystemPrompt: configuration.baseSystemPrompt,
            chatClient: configuration.chatClient,
            agentName: configuration.agentName,
            agentEmoji: configuration.agentEmoji
        )
        let heartbeatDelegate = HeartbeatSessionDelegate(base: agentDelegate)
        let sessionConfiguration = ConversationSession.Configuration(
            storage: storageProvider,
            tools: RegistryToolProvider(
                toolInvokeService: configuration.toolInvokeService,
                invocationSessionID: "heartbeat::\(configuration.agentID ?? "default")"
            ),
            delegate: heartbeatDelegate,
            systemPrompt: configuration.baseSystemPrompt ?? "You are a helpful assistant.",
            collapseReasoningWhenComplete: true
        )

        let models = ConversationSession.Models(
            chat: ConversationSession.Model(
                client: configuration.chatClient,
                capabilities: [.visual, .tool],
                contextLength: configuration.modelConfig.contextTokens,
                autoCompactEnabled: configuration.autoCompactEnabled
            )
        )

        let controller = ChatViewController(
            conversationID: conversationID,
            models: models,
            sessionConfiguration: sessionConfiguration
        )
        controller.loadViewIfNeeded()

        let prompt = HeartbeatSupport.buildPrompt(heartbeatMarkdown: heartbeatMarkdown)
        let input = ChatInputContent(text: prompt)

        await withCheckedContinuation { continuation in
            controller.chatInputDidSubmit(controller.chatInputView, object: input) { _ in
                continuation.resume()
            }
        }

        let outcome = heartbeatDelegate.executionOutcome
        let latestMessages = HeartbeatSupport.trimToRecent(
            storageProvider.messages(in: conversationID),
            limit: HeartbeatSupport.retainMessageLimit
        )
        let latestAssistantText = latestMessages.reversed().first(where: { $0.role == .assistant })?
            .textContent
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        switch outcome {
        case let .failure(errorDescription):
            Self.logger.error("heartbeat session failed: \(errorDescription ?? "unknown", privacy: .public)")
            persistMessages(latestMessages, for: conversationID, storageProvider: storageProvider)
            ConversationSessionManager.shared.removeSession(for: conversationID)
            return RunResult(notificationBody: nil, shouldNotify: false)

        case let .interrupted(reason):
            Self.logger.debug("heartbeat session interrupted: \(reason, privacy: .public)")
            persistMessages(latestMessages, for: conversationID, storageProvider: storageProvider)
            ConversationSessionManager.shared.removeSession(for: conversationID)
            return RunResult(notificationBody: nil, shouldNotify: false)

        case .success, .none:
            break
        }

        if HeartbeatSupport.shouldSuppressAssistantMessage(latestAssistantText) {
            replaceConversation(conversationID: conversationID, with: baselineMessages, storageProvider: storageProvider)
            ConversationSessionManager.shared.removeSession(for: conversationID)
            return RunResult(notificationBody: nil, shouldNotify: false)
        }

        persistMessages(latestMessages, for: conversationID, storageProvider: storageProvider)
        ConversationSessionManager.shared.removeSession(for: conversationID)

        guard !latestAssistantText.isEmpty else {
            return RunResult(notificationBody: nil, shouldNotify: false)
        }

        return RunResult(
            notificationBody: String(latestAssistantText.prefix(240)),
            shouldNotify: notificationMode == .always
        )
    }

    private func replaceConversation(
        conversationID: String,
        with messages: [ConversationMessage],
        storageProvider: TranscriptStorageProvider
    ) {
        let existingIDs = storageProvider.messages(in: conversationID).map(\.id)
        if !existingIDs.isEmpty {
            storageProvider.delete(existingIDs)
        }
        let trimmedMessages = HeartbeatSupport.trimToRecent(messages, limit: HeartbeatSupport.retainMessageLimit)
        if !trimmedMessages.isEmpty {
            storageProvider.save(trimmedMessages)
        }
        storageProvider.setTitle("Heartbeat", for: conversationID)
    }

    private func persistMessages(
        _ messages: [ConversationMessage],
        for conversationID: String,
        storageProvider: TranscriptStorageProvider
    ) {
        replaceConversation(
            conversationID: conversationID,
            with: HeartbeatSupport.trimToRecent(messages, limit: HeartbeatSupport.retainMessageLimit),
            storageProvider: storageProvider
        )
    }

    private func loadHeartbeatMarkdown(from workspaceRootURL: URL) -> String? {
        let fileURL = workspaceRootURL.appendingPathComponent(HeartbeatSupport.heartbeatFileName, isDirectory: false)
        guard let data = try? Data(contentsOf: fileURL),
              let content = String(data: data, encoding: .utf8)
        else {
            return nil
        }

        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func stateURL(for runtimeRootURL: URL) -> URL {
        runtimeRootURL
            .appendingPathComponent("heartbeat", isDirectory: true)
            .appendingPathComponent("state.json", isDirectory: false)
    }

    private func loadState(for runtimeRootURL: URL) -> State? {
        let fileURL = stateURL(for: runtimeRootURL)
        guard let data = try? Data(contentsOf: fileURL) else {
            return nil
        }
        return try? JSONDecoder().decode(State.self, from: data)
    }

    private func persistState(_ state: State, for runtimeRootURL: URL) {
        let fileURL = stateURL(for: runtimeRootURL)
        let directoryURL = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(state) else {
            return
        }
        try? data.write(to: fileURL, options: [.atomic])
    }

    private func postNotification(agentName: String, agentEmoji: String, body: String) async throws {
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBody.isEmpty else { return }

        let center = LiveNotificationCenter()
        let status = await center.authorizationStatus()
        guard status != .denied, status != .notDetermined else {
            return
        }

        let content = UNMutableNotificationContent()
        let prefix = agentEmoji.isEmpty ? agentName : "\(agentEmoji) \(agentName)"
        content.title = "\(prefix) heartbeat"
        content.body = trimmedBody
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "heartbeat.\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        try await center.add(request)
    }
}

@MainActor
private final class HeartbeatSessionDelegate: SessionDelegate {
    private let base: AgentSessionDelegate

    fileprivate private(set) var executionOutcome: HeartbeatService.ExecutionOutcome?

    init(base: AgentSessionDelegate) {
        self.base = base
    }

    func composeSystemPrompt() async -> String? {
        await base.composeSystemPrompt()
    }

    func memoryCoordinator(for conversationID: String) async -> MemoryCoordinator? {
        await base.memoryCoordinator(for: conversationID)
    }

    func loadSessionMemoryState(for conversationID: String) async -> SessionMemoryState {
        await base.loadSessionMemoryState(for: conversationID)
    }

    func saveSessionMemoryState(_ state: SessionMemoryState, for conversationID: String) async {
        await base.saveSessionMemoryState(state, for: conversationID)
    }

    func sessionDidReportUsage(_ usage: TokenUsage, for conversationID: String) {
        base.sessionDidReportUsage(usage, for: conversationID)
    }

    func sessionExecutionDidFinish(for _: String, success: Bool, errorDescription: String?) {
        executionOutcome = success ? .success : .failure(errorDescription)
    }

    func sessionExecutionDidInterrupt(for _: String, reason: String) {
        executionOutcome = .interrupted(reason)
    }
}
