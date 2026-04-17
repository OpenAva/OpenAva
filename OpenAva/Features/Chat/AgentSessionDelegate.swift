import ChatClient
import ChatUI
import Foundation
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
    private let runtimeRootURL: URL
    private let baseSystemPrompt: String?
    private let backgroundCoordinator = BackgroundExecutionCoordinator.shared
    private let sessionLogStorage: any StorageProvider
    private let durableMemoryExtractor: AgentDurableMemoryExtractor
    private let shouldExtractDurableMemory: Bool
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
        agentEmoji: String,
        shouldExtractDurableMemory: Bool = true
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
        self.baseSystemPrompt = baseSystemPrompt
        self.agentName = agentName
        self.agentEmoji = agentEmoji
        self.shouldExtractDurableMemory = shouldExtractDurableMemory
        let resolvedRuntimeRootURL = runtimeRootURL.standardizedFileURL
        self.runtimeRootURL = resolvedRuntimeRootURL
        sessionLogStorage = TranscriptStorageProvider.provider(runtimeRootURL: resolvedRuntimeRootURL)
        durableMemoryExtractor = AgentDurableMemoryExtractor(
            runtimeRootURL: resolvedRuntimeRootURL,
            chatClient: chatClient
        )
    }

    /// Compose the full system prompt at inference time so the tool list
    /// is always current (ToolRegistry may change between sessions).
    func composeSystemPrompt() async -> String? {
        AgentContextLoader.composeSystemPrompt(
            baseSystemPrompt: baseSystemPrompt,
            workspaceRootURL: workspaceRootURL
        )
    }

    func activeRuntimeRootURL() -> URL? {
        runtimeRootURL
    }

    func sessionDidPersistMessages(_ messages: [ConversationMessage], for sessionID: String) async {
        guard shouldExtractDurableMemory else { return }
        await durableMemoryExtractor.extractIfNeeded(for: sessionID, messages: messages)
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
        sessionLogStorage.recordTranscript(.turnStarted, for: sessionID)
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
        sessionLogStorage.recordTranscript(
            .turnFinished(success: success, errorDescription: errorDescription),
            for: sessionID
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
        sessionLogStorage.recordTranscript(.turnInterrupted(reason: reason), for: sessionID)
        backgroundCoordinator.markExecutionInterrupted(sessionID: sessionID, reason: reason)
        if BackgroundExecutionPreferences.shared.isEnabled {
            if #available(iOS 16.2, *), !Self.isMacCatalyst {
                TaskActivityService.shared.endActivity(sessionID: sessionID, completed: false)
            }
        }
        triggerConversationHaptic(.warning)
    }

    func sessionDidReportUsage(_ usage: TokenUsage, for _: String) {
        sessionLogStorage.recordTranscript(.usage(usage), for: sessionID)
        Task {
            await LLMUsageTracker.shared.record(usage)
        }
    }

    private func scheduleCompletionNotificationIfNeeded(for sessionID: String, success: Bool) {
        DispatchQueue.main.async {
            guard UIApplication.shared.applicationState != .active else { return }

            if self.isLatestTurnHeartbeat(in: sessionID) {
                return
            }

            let lastAssistantReply = self.sessionLogStorage.messages(in: sessionID)
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

    private func isLatestTurnHeartbeat(in sessionID: String) -> Bool {
        let messages = sessionLogStorage.messages(in: sessionID)
        let latestRelevantMessage = messages.reversed().first {
            $0.role == .assistant || $0.role == .user
        }
        return latestRelevantMessage?.metadata[HeartbeatSupport.metadataSourceKey] == HeartbeatSupport.metadataSourceValue
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
