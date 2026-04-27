import ChatClient
import ChatUI
import Combine
import Foundation
import OSLog

private let logger = Logger(subsystem: "com.day1-labs.openava", category: "chat.stop.session")

enum QuerySource: String {
    case user
    case heartbeat
    case compact
    case sessionMemory = "session_memory"
}

/// Coordinates the message state and turn execution for a conversation.
@MainActor
public final class ConversationSession: Identifiable, Sendable {
    public typealias SystemPromptProvider = @Sendable () -> String

    public enum InterruptReason: String, Sendable {
        case userStop = "user_stop"
        case taskReplaced = "task_replaced"
        case messageDeleted = "message_deleted"
        case conversationCleared = "conversation_cleared"
        case backgroundExpired = "background_expired"
        case cancelled
    }

    public struct Model: Sendable {
        public var client: any ChatClient
        public var capabilities: Set<ModelCapability>
        public var contextLength: Int
        public var maxOutputTokens: Int
        public var autoCompactEnabled: Bool

        public init(
            client: any ChatClient,
            capabilities: Set<ModelCapability> = [],
            contextLength: Int = 0,
            maxOutputTokens: Int = 20000,
            autoCompactEnabled: Bool = true
        ) {
            self.client = client
            self.capabilities = capabilities
            self.contextLength = contextLength
            self.maxOutputTokens = maxOutputTokens
            self.autoCompactEnabled = autoCompactEnabled
        }
    }

    public struct Models: Sendable {
        public var chat: Model?
        public var titleGeneration: Model?

        public init(chat: Model? = nil, titleGeneration: Model? = nil) {
            self.chat = chat
            self.titleGeneration = titleGeneration
        }
    }

    public struct Configuration: Sendable {
        public let storage: StorageProvider
        public let tools: ToolProvider?
        public let delegate: SessionDelegate?
        public let systemPromptProvider: SystemPromptProvider
        public let collapseReasoningWhenComplete: Bool

        public init(
            storage: StorageProvider,
            tools: ToolProvider? = nil,
            delegate: SessionDelegate? = nil,
            systemPromptProvider: @escaping SystemPromptProvider = { "You are a helpful assistant." },
            collapseReasoningWhenComplete: Bool = true
        ) {
            self.storage = storage
            self.tools = tools
            self.delegate = delegate
            self.systemPromptProvider = systemPromptProvider
            self.collapseReasoningWhenComplete = collapseReasoningWhenComplete
        }
    }

    public let id: String

    var messages: [ConversationMessage] = []
    var currentTask: Task<Void, Never>?
    let queryGuard = QueryGuard()

    // MARK: - Providers

    var storageProvider: StorageProvider
    var toolProvider: ToolProvider?
    var sessionDelegate: SessionDelegate?
    var systemPromptProvider: SystemPromptProvider
    var collapseReasoningWhenComplete: Bool

    // MARK: - Reactive

    private lazy var messagesSubject: CurrentValueSubject<
        ([ConversationMessage], Bool), Never
    > = .init((messages, false))

    public var messagesDidChange: AnyPublisher<([ConversationMessage], Bool), Never> {
        messagesSubject.eraseToAnyPublisher()
    }

    // MARK: - Usage Tracking

    /// Token usage from the last execution turn.
    public private(set) var lastUsage: TokenUsage?
    var autoCompactTrackingState = AutoCompactTrackingState()

    private lazy var usageSubject = PassthroughSubject<TokenUsage, Never>()

    private lazy var loadingStateSubject = CurrentValueSubject<String?, Never>(nil)

    /// Publisher emitting token usage after each execution step.
    public var usageDidChange: AnyPublisher<TokenUsage, Never> {
        usageSubject.eraseToAnyPublisher()
    }

    public var loadingStateDidChange: AnyPublisher<String?, Never> {
        loadingStateSubject.eraseToAnyPublisher()
    }

    public var queryActivityDidChange: AnyPublisher<Bool, Never> {
        queryGuard.activityDidChange
    }

    var isQueryActive: Bool {
        queryGuard.isActive
    }

    func setLoadingState(_ status: String?) {
        let trimmed = status?.trimmingCharacters(in: .whitespacesAndNewlines)
        loadingStateSubject.send(trimmed?.isEmpty == false ? trimmed : nil)
    }

    func reportUsage(_ usage: TokenUsage) {
        lastUsage = usage
        usageSubject.send(usage)
        sessionDelegate?.sessionDidReportUsage(usage, for: id)
    }

    // MARK: - Tool Permissions

    var toolPermissionMode: ToolPermissionMode = .default
    private(set) var sessionToolPermissionRules: [ToolPermissionRule] = []

    func setToolPermissionMode(_ mode: ToolPermissionMode) {
        toolPermissionMode = mode
    }

    func addSessionToolPermissionRule(_ rule: ToolPermissionRule) {
        let sessionRule = ToolPermissionRule(
            id: rule.id,
            behavior: rule.behavior,
            scope: .session,
            toolName: rule.toolName,
            matcher: rule.matcher,
            createdAt: rule.createdAt
        )
        sessionToolPermissionRules.removeAll { existing in
            existing.scope == sessionRule.scope
                && existing.toolName == sessionRule.toolName
                && existing.matcher == sessionRule.matcher
        }
        sessionToolPermissionRules.append(sessionRule)
    }

    func clearSessionToolPermissionRules() {
        sessionToolPermissionRules.removeAll()
    }

    // MARK: - Tool Permission Approvals

    struct PendingToolPermissionRequest: Identifiable, Equatable {
        let id: String
        let toolName: String
        let apiName: String
        let arguments: String
        let message: String?
        let reason: String?
        let createdAt: Date
    }

    private(set) var pendingToolPermissionRequests: [PendingToolPermissionRequest] = []
    private var pendingToolPermissionContinuations: [String: CheckedContinuation<ToolPermissionDecision, Never>] = [:]
    private lazy var pendingToolPermissionSubject = CurrentValueSubject<[PendingToolPermissionRequest], Never>([])

    var pendingToolPermissionsDidChange: AnyPublisher<[PendingToolPermissionRequest], Never> {
        pendingToolPermissionSubject.eraseToAnyPublisher()
    }

    func requestToolPermissionApproval(
        for request: ToolRequest,
        tool: any ToolExecutor,
        decision: ToolPermissionDecision
    ) async -> ToolPermissionDecision {
        let permissionRequest = PendingToolPermissionRequest(
            id: request.id,
            toolName: tool.displayName,
            apiName: request.name,
            arguments: request.arguments,
            message: trimmedPermissionMessage(decision),
            reason: decision.reason,
            createdAt: Date()
        )

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                pendingToolPermissionContinuations[permissionRequest.id] = continuation
                if let existingIndex = pendingToolPermissionRequests.firstIndex(where: { $0.id == permissionRequest.id }) {
                    pendingToolPermissionRequests[existingIndex] = permissionRequest
                } else {
                    pendingToolPermissionRequests.append(permissionRequest)
                }
                pendingToolPermissionSubject.send(pendingToolPermissionRequests)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.resolveToolPermissionRequest(
                    id: permissionRequest.id,
                    decision: .deny(
                        message: String.localized("Tool approval was cancelled."),
                        reason: "tool_permission_cancelled"
                    )
                )
            }
        }
    }

    func approveToolPermissionRequest(id requestID: String) {
        resolveToolPermissionRequest(
            id: requestID,
            decision: ToolPermissionDecision(
                behavior: .allow,
                message: nil,
                reason: "tool_permission_approved"
            )
        )
    }

    func rejectToolPermissionRequest(id requestID: String, message: String? = nil) {
        resolveToolPermissionRequest(
            id: requestID,
            decision: .deny(
                message: message ?? String.localized("Tool execution was rejected."),
                reason: "tool_permission_rejected"
            )
        )
    }

    private func resolveToolPermissionRequest(id requestID: String, decision: ToolPermissionDecision) {
        guard let continuation = pendingToolPermissionContinuations.removeValue(forKey: requestID) else {
            return
        }
        pendingToolPermissionRequests.removeAll { $0.id == requestID }
        pendingToolPermissionSubject.send(pendingToolPermissionRequests)
        continuation.resume(returning: decision)
    }

    private func trimmedPermissionMessage(_ decision: ToolPermissionDecision) -> String? {
        let trimmed = decision.message?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty == false) ? trimmed : nil
    }

    // MARK: - Model Selection

    public var models: Models

    // MARK: - Thinking Timer

    private var thinkingDurationTimer: [String: Timer] = [:]

    // MARK: - Interrupted Retry

    /// Last submitted prompt input used for manual retry after interruption.
    var lastSubmittedPromptInput: PromptInput?
    /// Whether UI should show the trailing "retry" action row.
    var showsInterruptedRetryAction = false
    private(set) var currentInterruptReason: InterruptReason?

    // MARK: - Lifecycle

    public init(id: String, configuration: Configuration) {
        self.id = id
        storageProvider = configuration.storage
        toolProvider = configuration.tools
        sessionDelegate = configuration.delegate
        systemPromptProvider = configuration.systemPromptProvider
        collapseReasoningWhenComplete = configuration.collapseReasoningWhenComplete
        models = .init()
        refreshContentsFromDatabase()
        showsInterruptedRetryAction = storageProvider.sessionExecutionState(for: id) == .interrupted
    }

    func reconfigure(with configuration: Configuration) {
        storageProvider = configuration.storage
        toolProvider = configuration.tools
        sessionDelegate = configuration.delegate
        systemPromptProvider = configuration.systemPromptProvider
        collapseReasoningWhenComplete = configuration.collapseReasoningWhenComplete
        showsInterruptedRetryAction = storageProvider.sessionExecutionState(for: id) == .interrupted
    }

    // MARK: - Message Management

    @discardableResult
    func appendNewMessage(role: MessageRole, configure: ((ConversationMessage) -> Void)? = nil) -> ConversationMessage {
        let message = storageProvider.createMessage(in: id, role: role)
        configure?(message)
        messages.append(message)
        return message
    }

    func notifyMessagesDidChange(scrolling: Bool = true) {
        messagesSubject.send((messages, scrolling))
    }

    func refreshContentsFromDatabase(scrolling: Bool = true) {
        messages.removeAll()
        messages = storageProvider.messages(in: id)
        notifyMessagesDidChange(scrolling: scrolling)
    }

    func persistMessages() {
        storageProvider.save(messages)
    }

    /// Persist a single message snapshot immediately.
    func recordMessageInTranscript(_ message: ConversationMessage) {
        storageProvider.save(message: message)
    }

    func toggleReasoningCollapse(for messageID: String) {
        guard let conversationMessage = messages.first(where: { $0.id == messageID }) else { return }
        for (index, part) in conversationMessage.parts.enumerated() {
            if case var .reasoning(reasoningPart) = part {
                reasoningPart.isCollapsed.toggle()
                conversationMessage.parts[index] = .reasoning(reasoningPart)
                recordMessageInTranscript(conversationMessage)
                notifyMessagesDidChange(scrolling: false)
                return
            }
        }
    }

    func toggleToolResultCollapse(for messageID: String, toolCallID: String) {
        let conversationMessage = messages.first { message in
            guard message.id == messageID, message.role == .tool else { return false }
            return message.parts.contains { part in
                guard case let .toolResult(toolResult) = part else { return false }
                return toolResult.toolCallID == toolCallID
            }
        } ?? messages.first { message in
            guard message.role == .tool else { return false }
            return message.parts.contains { part in
                guard case let .toolResult(toolResult) = part else { return false }
                return toolResult.toolCallID == toolCallID
            }
        }
        guard let conversationMessage else { return }
        var didToggle = false
        for (index, part) in conversationMessage.parts.enumerated() {
            guard case var .toolResult(toolResult) = part,
                  toolResult.toolCallID == toolCallID
            else {
                continue
            }
            toolResult.isCollapsed.toggle()
            conversationMessage.parts[index] = .toolResult(toolResult)
            didToggle = true
        }
        guard didToggle else { return }
        recordMessageInTranscript(conversationMessage)
        notifyMessagesDidChange(scrolling: false)
    }

    public func delete(_ messageID: String) {
        cancelCurrentTask(reason: .messageDeleted) { [self] in
            storageProvider.delete([messageID])
            refreshContentsFromDatabase()
        }
    }

    public func delete(after messageID: String, completion: @escaping () -> Void = {}) {
        cancelCurrentTask(reason: .messageDeleted) { [self] in
            guard let index = messages.firstIndex(where: { $0.id == messageID }) else {
                completion()
                return
            }
            let idsToDelete = messages.dropFirst(index + 1).map(\.id)
            if !idsToDelete.isEmpty {
                storageProvider.delete(idsToDelete)
            }
            refreshContentsFromDatabase()
            completion()
        }
    }

    public func clear(completion: @escaping () -> Void = {}) {
        cancelCurrentTask(reason: .conversationCleared) { [self] in
            stopThinkingForAll()
            let messageIDs = messages.map(\.id)
            if !messageIDs.isEmpty {
                storageProvider.delete(messageIDs)
            }
            storageProvider.setTitle("", for: id)
            lastUsage = nil
            refreshContentsFromDatabase(scrolling: false)
            completion()
        }
    }

    public func interruptCurrentTurn(reason: InterruptReason = .userStop) {
        guard queryGuard.isActive else { return }
        guard let task = currentTask else {
            logger.notice(
                "interrupt requested session=\(self.id, privacy: .public) reason=\(reason.rawValue, privacy: .public) hasTask=false"
            )
            queryGuard.forceEnd()
            return
        }
        logger.notice(
            "interrupt requested session=\(self.id, privacy: .public) reason=\(reason.rawValue, privacy: .public) hasTask=true taskCancelledBefore=\(String(task.isCancelled), privacy: .public)"
        )
        currentInterruptReason = reason
        queryGuard.forceEnd()
        task.cancel()
        currentTask = nil
    }

    public func consumeInterruptReason() -> InterruptReason {
        let reason = currentInterruptReason ?? .cancelled
        logger.notice(
            "interrupt reason consumed session=\(self.id, privacy: .public) reason=\(reason.rawValue, privacy: .public)"
        )
        currentInterruptReason = nil
        return reason
    }

    func cancelCurrentTask(reason: InterruptReason = .taskReplaced, then action: @escaping () -> Void) {
        if let task = currentTask {
            logger.notice(
                "cancel current task session=\(self.id, privacy: .public) reason=\(reason.rawValue, privacy: .public) taskCancelledBefore=\(String(task.isCancelled), privacy: .public)"
            )
            currentInterruptReason = reason
            queryGuard.forceEnd()
            task.cancel()
            currentTask = nil
        }
        action()
    }

    // MARK: - Thinking Duration

    func startThinking(for messageID: String) {
        if thinkingDurationTimer[messageID] != nil { return }
        guard let message = messages.first(where: { $0.id == messageID }) else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            for (index, part) in message.parts.enumerated() {
                if case var .reasoning(reasoningPart) = part {
                    reasoningPart.duration += 1
                    message.parts[index] = .reasoning(reasoningPart)
                    break
                }
            }
            notifyMessagesDidChange(scrolling: false)
        }
        RunLoop.main.add(timer, forMode: .common)
        thinkingDurationTimer[messageID] = timer
    }

    func stopThinkingForAll() {
        thinkingDurationTimer.values.forEach { $0.invalidate() }
        thinkingDurationTimer.removeAll()
    }

    func stopThinking(for messageID: String) {
        thinkingDurationTimer[messageID]?.invalidate()
        thinkingDurationTimer.removeValue(forKey: messageID)
    }
}
