import ChatClient
import ChatUI
import Foundation
import OSLog
import UIKit
import UserNotifications

@MainActor
struct HeartbeatRuntimeConfiguration {
    let agentID: String?
    let mainSessionID: String
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

    private enum RunAttempt {
        case skipped
        case completed(Bool)
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

        Task { @MainActor [weak self] in
            await self?.processPendingCronTriggers()
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
        let attempt = await performHeartbeatIfNeeded(
            configuration,
            parsedDocument: parsedDocument,
            force: true
        )
        switch attempt {
        case let .completed(success):
            return success
        case .skipped:
            return false
        }
    }

    func processPendingCronTriggers() async {
        guard let configuration = currentConfiguration,
              let agentID = AppConfig.nonEmpty(configuration.agentID),
              let heartbeatMarkdown = loadHeartbeatMarkdown(from: configuration.workspaceRootURL)
        else {
            return
        }

        let triggers = await HeartbeatTriggerStore.shared.pendingTriggers(for: agentID)
        guard let nextTrigger = triggers.first else {
            return
        }

        let parsedDocument = HeartbeatSupport.parseDocument(heartbeatMarkdown)
        let attempt = await performHeartbeatIfNeeded(
            configuration,
            parsedDocument: parsedDocument,
            force: true
        )
        switch attempt {
        case .skipped:
            return
        case .completed:
            await HeartbeatTriggerStore.shared.markHandled(deliveryID: nextTrigger.deliveryID)
        }
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
    ) async -> RunAttempt {
        if isRunning {
            Self.logger.debug("skip heartbeat because another heartbeat run is active")
            return .skipped
        }

        if !force {
            if let activeDelay = parsedDocument.configuration.delayUntilActive(from: Date()), activeDelay > 0 {
                return .skipped
            }

            if ConversationSessionManager.shared.hasExecutingSession() {
                Self.logger.debug("skip heartbeat because another session is executing")
                return .skipped
            }

            if let state = loadState(for: configuration.runtimeRootURL) {
                let elapsed = Date().timeIntervalSince1970 - state.lastCheckAt
                if elapsed < parsedDocument.configuration.interval {
                    return .skipped
                }
            }
        } else if ConversationSessionManager.shared.hasExecutingSession() {
            Self.logger.debug("skip manual heartbeat because another session is executing")
            return .skipped
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
                return .completed(true)
            }
            try await postNotification(agentName: configuration.agentName, agentEmoji: configuration.agentEmoji, body: notificationBody)
            return .completed(true)
        } catch {
            persistState(.init(lastCheckAt: runStartedAt), for: configuration.runtimeRootURL)
            Self.logger.error("heartbeat failed: \(error.localizedDescription, privacy: .public)")
            return .completed(false)
        }
    }

    private func executeHeartbeat(
        _ configuration: HeartbeatRuntimeConfiguration,
        heartbeatMarkdown: String,
        notificationMode: HeartbeatSupport.Configuration.NotificationMode
    ) async throws -> RunResult {
        let mainSessionID = HeartbeatSupport.mainSessionID(configuration.mainSessionID)
        let toolInvocationSessionID = "\(AppConfig.nonEmpty(configuration.agentID) ?? "global")::\(mainSessionID)"
        let storageProvider = TranscriptStorageProvider.provider(runtimeRootURL: configuration.runtimeRootURL)
        let baselineMessages = HeartbeatSupport.trimToRecent(
            storageProvider.messages(in: mainSessionID),
            limit: HeartbeatSupport.retainMessageLimit
        )
        let baselineTitle = storageProvider.title(for: mainSessionID)

        let agentDelegate = AgentSessionDelegate(
            sessionID: mainSessionID,
            workspaceRootURL: configuration.workspaceRootURL,
            runtimeRootURL: configuration.runtimeRootURL,
            baseSystemPrompt: configuration.baseSystemPrompt,
            chatClient: configuration.chatClient,
            agentName: configuration.agentName,
            agentEmoji: configuration.agentEmoji
        )
        let sessionConfiguration = ConversationSession.Configuration(
            storage: storageProvider,
            tools: RegistryToolProvider(
                toolInvokeService: configuration.toolInvokeService,
                invocationSessionID: toolInvocationSessionID
            ),
            delegate: agentDelegate,
            systemPrompt: configuration.baseSystemPrompt ?? "You are a helpful assistant.",
            collapseReasoningWhenComplete: true
        )
        let session = ConversationSessionManager.shared.session(for: mainSessionID, configuration: sessionConfiguration)

        let models = ConversationSession.Models(
            chat: ConversationSession.Model(
                client: configuration.chatClient,
                capabilities: [.visual, .tool],
                contextLength: configuration.modelConfig.contextTokens,
                autoCompactEnabled: configuration.autoCompactEnabled
            )
        )

        let controller = ChatViewController(
            sessionID: mainSessionID,
            models: models,
            sessionConfiguration: sessionConfiguration,
            configuration: .default()
        )
        controller.loadViewIfNeeded()

        let prompt = HeartbeatSupport.buildPrompt(heartbeatMarkdown: heartbeatMarkdown)
        let input = ChatInputContent(text: prompt)

        await withCheckedContinuation { continuation in
            controller.chatInputDidSubmit(controller.chatInputView, object: input) { _ in
                continuation.resume()
            }
        }

        let latestMessages = HeartbeatSupport.trimToRecent(
            storageProvider.messages(in: mainSessionID),
            limit: HeartbeatSupport.retainMessageLimit
        )
        let latestAssistantText = latestMessages.reversed().first(where: { $0.role == .assistant })?
            .textContent
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if HeartbeatSupport.shouldSuppressAssistantMessage(latestAssistantText) {
            restoreBaseline(
                session: session,
                baselineMessages: baselineMessages,
                baselineTitle: baselineTitle,
                storageProvider: storageProvider
            )
            return RunResult(notificationBody: nil, shouldNotify: false)
        }

        guard !latestAssistantText.isEmpty else {
            return RunResult(notificationBody: nil, shouldNotify: false)
        }

        return RunResult(
            notificationBody: String(latestAssistantText.prefix(240)),
            shouldNotify: notificationMode == .always
        )
    }

    private func restoreBaseline(
        session: ConversationSession,
        baselineMessages: [ConversationMessage],
        baselineTitle: String?,
        storageProvider: TranscriptStorageProvider
    ) {
        if let lastBaselineID = baselineMessages.last?.id {
            session.delete(after: lastBaselineID)
        } else {
            session.clear()
        }
        storageProvider.setTitle(baselineTitle ?? "", for: session.id)
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
