import ChatClient
import ChatUI
import Foundation
import MemoryKit
import UIKit
import UserNotifications

/// SessionDelegate that builds the full agent system prompt via AgentPromptBuilder.
///
/// Used by ChatViewControllerWrapper so the direct-ChatClient path produces the
/// same rich system prompt (tooling, workspace context, time, runtime, etc.)
/// as the LocalGatewayHost path.
final class AgentSessionDelegate: SessionDelegate, @unchecked Sendable {
    private static var isMacCatalyst: Bool {
        #if targetEnvironment(macCatalyst)
            true
        #else
            false
        #endif
    }

    private let sessionID: String
    private let workspaceRootURL: URL
    private let runtimeRootURL: URL?
    private let baseSystemPrompt: String?
    private let resolvedWorkspaceRootURL: URL
    private let resolvedRuntimeRootURL: URL
    private let coordinatorPool: MemoryCoordinatorPool
    private let stateRepository: MemoryStateRepository
    private let backgroundCoordinator = BackgroundExecutionCoordinator.shared
    private let transcriptStorageProvider: TranscriptStorageProvider
    private let hapticLock = NSLock()
    private var lastHapticAt: TimeInterval = 0
    private let minimumHapticInterval: TimeInterval = 0.2
    private let agentName: String
    private let agentEmoji: String

    init(
        sessionID: String,
        workspaceRootURL: URL?,
        runtimeRootURL: URL?,
        baseSystemPrompt: String?,
        chatClient: (any ChatClient)?,
        agentName: String,
        agentEmoji: String
    ) {
        // Agent pipelines require a concrete runtime root directory.
        guard let runtimeRootURL else {
            preconditionFailure("AgentSessionDelegate requires an explicit agent runtime root URL.")
        }
        guard let workspaceRootURL else {
            preconditionFailure("AgentSessionDelegate requires an explicit agent workspace root URL.")
        }
        self.sessionID = sessionID
        self.workspaceRootURL = workspaceRootURL.standardizedFileURL
        self.runtimeRootURL = runtimeRootURL
        self.baseSystemPrompt = baseSystemPrompt
        self.agentName = agentName
        self.agentEmoji = agentEmoji
        // Session state is persisted at workspace/.runtime/session_memory_states.json.
        resolvedWorkspaceRootURL = workspaceRootURL.standardizedFileURL
        resolvedRuntimeRootURL = runtimeRootURL.standardizedFileURL
        coordinatorPool = MemoryCoordinatorPool(
            workspaceRoot: resolvedWorkspaceRootURL,
            chatClient: chatClient,
            memoryWindow: 20
        )
        stateRepository = MemoryStateRepository(runtimeRoot: resolvedRuntimeRootURL)
        transcriptStorageProvider = TranscriptStorageProvider.provider(runtimeRootURL: resolvedRuntimeRootURL)
    }

    /// Compose the full system prompt at inference time so the tool list
    /// is always current (ToolRegistry may change between sessions).
    func composeSystemPrompt() async -> String? {
        var memoryContext: String?
        if let coordinator = await memoryCoordinator(for: sessionID) {
            let text = await coordinator.memoryContext().trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                memoryContext = text
            }
        }
        return await AgentContextLoader.composeSystemPrompt(
            baseSystemPrompt: baseSystemPrompt,
            memoryContext: memoryContext,
            workspaceRootURL: workspaceRootURL
        )
    }

    func memoryCoordinator(for sessionID: String) async -> MemoryCoordinator? {
        await coordinatorPool.coordinator(for: sessionID)
    }

    func loadSessionMemoryState(for sessionID: String) async -> SessionMemoryState {
        await stateRepository.loadState(for: sessionID)
    }

    func saveSessionMemoryState(_ state: SessionMemoryState, for sessionID: String) async {
        await stateRepository.saveState(state, for: sessionID)
    }

    func beginBackgroundTask(expiration: @escaping @Sendable () -> Void) -> Any? {
        // UIKit background task APIs must run on main thread.
        let token = UIApplication.shared.beginBackgroundTask(withName: "chat.inference") {
            expiration()
        }
        if token == .invalid {
            return nil
        }
        return token.rawValue
    }

    func endBackgroundTask(_ token: Any) {
        guard let rawValue = token as? Int else { return }
        let identifier = UIBackgroundTaskIdentifier(rawValue: rawValue)
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
    }

    func sessionExecutionDidStart(for sessionID: String) {
        transcriptStorageProvider.recordTurnStarted(sessionID: sessionID)
        backgroundCoordinator.markExecutionStarted(sessionID: sessionID)
        guard BackgroundExecutionPreferences.shared.isEnabled else { return }
        if #available(iOS 16.2, *), !Self.isMacCatalyst {
            TaskActivityService.shared.startActivity(
                sessionID: sessionID,
                agentName: agentName,
                agentEmoji: agentEmoji
            )
        }
    }

    func sessionExecutionDidFinish(for sessionID: String, success: Bool, errorDescription: String?) {
        transcriptStorageProvider.recordTurnFinished(
            sessionID: sessionID,
            success: success,
            errorDescription: errorDescription
        )
        backgroundCoordinator.markExecutionFinished(
            sessionID: sessionID,
            success: success,
            errorDescription: errorDescription
        )
        if BackgroundExecutionPreferences.shared.isEnabled {
            if #available(iOS 16.2, *), !Self.isMacCatalyst {
                TaskActivityService.shared.endActivity(sessionID: sessionID, completed: success)
            }
            scheduleCompletionNotificationIfNeeded(for: sessionID, success: success)
        }
        triggerConversationHaptic(success ? .success : .error)
    }

    func sessionExecutionDidInterrupt(for sessionID: String, reason: String) {
        transcriptStorageProvider.recordTurnInterrupted(sessionID: sessionID, reason: reason)
        backgroundCoordinator.markExecutionInterrupted(sessionID: sessionID, reason: reason)
        if BackgroundExecutionPreferences.shared.isEnabled {
            if #available(iOS 16.2, *), !Self.isMacCatalyst {
                TaskActivityService.shared.endActivity(sessionID: sessionID, completed: false)
            }
        }
        triggerConversationHaptic(.warning)
    }

    func sessionDidReportUsage(_ usage: TokenUsage, for _: String) {
        transcriptStorageProvider.recordUsage(usage, sessionID: sessionID)
        Task {
            await LLMUsageTracker.shared.record(usage)
        }
    }

    private func scheduleCompletionNotificationIfNeeded(for sessionID: String, success: Bool) {
        DispatchQueue.main.async {
            guard UIApplication.shared.applicationState != .active else { return }

            let lastAssistantReply = self.transcriptStorageProvider.messages(in: sessionID)
                .filter { $0.role == .assistant }
                .last?
                .textContent ?? ""
            let snippet = String(lastAssistantReply.prefix(100))

            let content = UNMutableNotificationContent()
            content.title = success
                ? "\(self.agentName) \(L10n.tr("notification.taskCompleted"))"
                : "\(self.agentName) \(L10n.tr("notification.taskFailed"))"
            content.body = snippet
            content.sound = .default

            let request = UNNotificationRequest(
                identifier: "task-complete-\(sessionID)",
                content: content,
                trigger: nil
            )
            UNUserNotificationCenter.current().add(request)
        }
    }

    private func triggerConversationHaptic(_ feedbackType: UINotificationFeedbackGenerator.FeedbackType) {
        guard !Self.isMacCatalyst else { return }
        let now = Date().timeIntervalSinceReferenceDate
        hapticLock.lock()
        let shouldTrigger = now - lastHapticAt >= minimumHapticInterval
        if shouldTrigger {
            lastHapticAt = now
        }
        hapticLock.unlock()
        guard shouldTrigger else { return }

        DispatchQueue.main.async {
            // Keep haptics only while app is foreground to avoid noisy background feedback.
            guard UIApplication.shared.applicationState == .active else { return }
            let generator = UINotificationFeedbackGenerator()
            generator.prepare()
            generator.notificationOccurred(feedbackType)
        }
    }
}
