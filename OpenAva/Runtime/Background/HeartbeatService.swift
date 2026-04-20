import ChatUI
import Foundation
import OSLog
import UserNotifications

@MainActor
struct HeartbeatRuntimeConfiguration: Equatable {
    let agent: AgentProfile
    let agentID: String
    let mainSessionID: String
    let agentName: String
    let agentEmoji: String
    let workspaceRootURL: URL
    let runtimeRootURL: URL
    let modelConfig: AppConfig.LLMModel
}

@MainActor
protocol HeartbeatRuntimeControlling: AnyObject {
    func apply(configuration: HeartbeatRuntimeConfiguration, schedulingEnabled: Bool)
    func stop()
    func requestRunNow() async -> Bool
    func processPendingCronTriggers() async
}

@MainActor
final class HeartbeatRuntimeRegistry {
    typealias RuntimeFactory = @MainActor (_ agentID: String) -> any HeartbeatRuntimeControlling

    static let shared = HeartbeatRuntimeRegistry()

    private var runtimes: [String: any HeartbeatRuntimeControlling] = [:]
    private let runtimeFactory: RuntimeFactory

    init(runtimeFactory: @escaping RuntimeFactory = { HeartbeatRuntime(agentID: $0) }) {
        self.runtimeFactory = runtimeFactory
    }

    func sync(configurations: [HeartbeatRuntimeConfiguration], schedulingEnabled: Bool) {
        let configurationsByAgentID = Dictionary(uniqueKeysWithValues: configurations.map { ($0.agentID, $0) })

        for agentID in runtimes.keys where configurationsByAgentID[agentID] == nil {
            runtimes.removeValue(forKey: agentID)?.stop()
        }

        for (agentID, configuration) in configurationsByAgentID {
            let runtime: any HeartbeatRuntimeControlling
            if let existingRuntime = runtimes[agentID] {
                runtime = existingRuntime
            } else {
                let createdRuntime = runtimeFactory(agentID)
                runtimes[agentID] = createdRuntime
                runtime = createdRuntime
            }

            runtime.apply(configuration: configuration, schedulingEnabled: schedulingEnabled)
        }
    }

    func unregister(agentID: String) {
        runtimes.removeValue(forKey: agentID)?.stop()
    }

    func stopAll() {
        for runtime in runtimes.values {
            runtime.stop()
        }
        runtimes.removeAll()
    }

    @discardableResult
    func requestRunNow(for agentID: String) async -> Bool {
        guard let runtime = runtimes[agentID] else {
            return false
        }
        return await runtime.requestRunNow()
    }

    @discardableResult
    func processPendingCronTriggers(for agentID: String) async -> Bool {
        guard let runtime = runtimes[agentID] else {
            return false
        }
        await runtime.processPendingCronTriggers()
        return true
    }

    var registeredAgentIDs: [String] {
        runtimes.keys.sorted()
    }
}

@MainActor
final class HeartbeatRuntime: HeartbeatRuntimeControlling {
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

    private let agentID: String
    private var configuration: HeartbeatRuntimeConfiguration?
    private var loopTask: Task<Void, Never>?
    private var isRunning = false
    private var schedulingEnabled = false

    init(agentID: String) {
        self.agentID = agentID
    }

    func apply(configuration: HeartbeatRuntimeConfiguration, schedulingEnabled: Bool) {
        self.configuration = configuration
        self.schedulingEnabled = schedulingEnabled
        restartLoopIfNeeded()

        Task { @MainActor [weak self] in
            await self?.processPendingCronTriggers()
        }
    }

    func stop() {
        stopLoop()
        configuration = nil
        schedulingEnabled = false
        isRunning = false
    }

    @discardableResult
    func requestRunNow() async -> Bool {
        guard let configuration,
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
        guard let configuration,
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

    private func restartLoopIfNeeded() {
        stopLoop()
        guard schedulingEnabled, configuration != nil else {
            return
        }

        loopTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    private func stopLoop() {
        loopTask?.cancel()
        loopTask = nil
    }

    private func runLoop() async {
        while !Task.isCancelled {
            guard let configuration else {
                return
            }

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

            if isCurrentMainSessionQueryActive(configuration) {
                Self.logger.debug("skip heartbeat because current main session has an active query")
                return .skipped
            }

            if let state = loadState(for: configuration.runtimeRootURL) {
                let elapsed = Date().timeIntervalSince1970 - state.lastCheckAt
                if elapsed < parsedDocument.configuration.interval {
                    return .skipped
                }
            }
        } else if isCurrentMainSessionQueryActive(configuration) {
            Self.logger.debug("skip manual heartbeat because current main session has an active query")
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
        let toolInvocationSessionID = "\(configuration.agentID)::\(mainSessionID)"
        let agentCount = max(AgentStore.load(workspaceRootURL: configuration.agent.workspaceURL.deletingLastPathComponent()).agents.count, 1)
        return try await AgentMainSessionRegistry.shared.submitToMainSession(
            for: configuration.agent,
            modelConfig: configuration.modelConfig,
            invocationSessionID: toolInvocationSessionID,
            shouldExtractDurableMemory: false,
            agentCount: agentCount
        ) { resources in
            let session = resources.session
            let storageProvider = resources.storageProvider

            guard let model = session.models.chat else {
                throw NSError(
                    domain: "HeartbeatRuntime",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Heartbeat model is not configured."]
                )
            }

            session.refreshContentsFromDatabase(scrolling: false)
            await session.submitPrompt(
                model: model,
                prompt: HeartbeatSupport.makePromptInput(heartbeatMarkdown: heartbeatMarkdown)
            )

            self.annotateLatestHeartbeatMessages(in: session)
            if let assistantMessage = session.messages.reversed().first(where: { $0.role == .assistant }) {
                session.recordMessageInTranscript(assistantMessage)
            }

            let latestMessages = HeartbeatSupport.trimToRecent(
                storageProvider.messages(in: mainSessionID),
                limit: HeartbeatSupport.retainMessageLimit
            )
            let latestAssistantText = latestMessages.reversed().first(where: { $0.role == .assistant })?
                .textContent ?? ""
            switch HeartbeatSupport.classifyAssistantMessage(latestAssistantText) {
            case .empty:
                return RunResult(notificationBody: nil, shouldNotify: false)
            case .ackOnly:
                return RunResult(notificationBody: nil, shouldNotify: false)
            case let .actionRequired(text):
                return RunResult(
                    notificationBody: String(text.prefix(240)),
                    shouldNotify: notificationMode == .always
                )
            }
        }
    }

    private func annotateLatestHeartbeatMessages(in session: ConversationSession) {
        guard let assistantMessage = session.messages.reversed().first(where: { $0.role == .assistant }) else {
            return
        }
        assistantMessage.metadata[HeartbeatSupport.metadataSourceKey] = HeartbeatSupport.metadataSourceValue
        assistantMessage.metadata[HeartbeatSupport.metadataModeKey] = HeartbeatSupport.metadataModeScheduledValue

        switch HeartbeatSupport.classifyAssistantMessage(assistantMessage.textContent) {
        case .ackOnly:
            assistantMessage.metadata[HeartbeatSupport.metadataAckStateKey] = HeartbeatSupport.metadataAckOnlyValue
        case .actionRequired:
            assistantMessage.metadata[HeartbeatSupport.metadataAckStateKey] = HeartbeatSupport.metadataActionRequiredValue
        case .empty:
            assistantMessage.metadata.removeValue(forKey: HeartbeatSupport.metadataAckStateKey)
        }
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

    private func isCurrentMainSessionQueryActive(_ configuration: HeartbeatRuntimeConfiguration) -> Bool {
        let mainSessionID = HeartbeatSupport.mainSessionID(configuration.mainSessionID)
        let storageProvider = TranscriptStorageProvider.provider(runtimeRootURL: configuration.runtimeRootURL)
        return ConversationSessionManager.shared.isQueryActive(mainSessionID, storage: storageProvider)
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
