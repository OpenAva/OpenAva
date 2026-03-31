import ChatClient
import ChatUI
import OpenClawKit
import SwiftUI
import UIKit
import UserNotifications

#if targetEnvironment(macCatalyst)
    private final class CatalystChatViewController: ChatViewController {
        var onOpenModelSettings: (() -> Void)?
        private var commandObserver: NSObjectProtocol?

        override var canBecomeFirstResponder: Bool {
            true
        }

        private func installCommandObserverIfNeeded() {
            guard commandObserver == nil else { return }
            commandObserver = NotificationCenter.default.addObserver(
                forName: .openAvaCatalystGlobalCommand,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                self?.handleGlobalCommand(notification)
            }
        }

        deinit {
            if let commandObserver {
                NotificationCenter.default.removeObserver(commandObserver)
            }
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            installCommandObserverIfNeeded()
            becomeFirstResponder()
        }

        override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
            super.viewWillTransition(to: size, with: coordinator)
            coordinator.animate(alongsideTransition: { [weak self] _ in
                self?.view.setNeedsLayout()
                self?.view.layoutIfNeeded()
            })
        }

        private func handleGlobalCommand(_ notification: Notification) {
            guard let command = CatalystGlobalCommandCenter.resolve(notification) else { return }
            switch command {
            case .newConversation:
                handleNewConversationShortcut()
            case .openModelSettings:
                handleOpenModelSettingsShortcut()
            case .focusInput:
                handleFocusInputShortcut()
            }
        }

        @objc private func handleNewConversationShortcut() {
            chatInputDidTriggerCommand(chatInputView, command: "/new")
        }

        @objc private func handleOpenModelSettingsShortcut() {
            onOpenModelSettings?()
        }

        @objc private func handleFocusInputShortcut() {
            chatInputView.focus()
        }
    }
#endif

/// SwiftUI wrapper for ChatViewController from Common/ChatUI.
struct ChatViewControllerWrapper: UIViewControllerRepresentable {
    enum MenuAction {
        case openLLM
        case openContext
        case openCron
        case openSkills
    }

    let conversationID: String
    let workspaceRootURL: URL?
    let runtimeRootURL: URL?
    let chatClient: (any ChatClient)?
    let toolProvider: ToolProvider?
    let systemPrompt: String?
    let sessions: [ChatSession]
    let agents: [AgentProfile]
    let activeAgentID: UUID?
    let activeAgentName: String
    let activeAgentEmoji: String
    let selectedModelName: String
    let selectedProviderName: String
    let defaultSessionKey: String
    let currentSessionKey: String?
    /// Non-nil when an App Intent wants to auto-send a message through the real agentic loop.
    /// `pendingAutoSendID` is a unique token so the coordinator never submits the same request twice.
    let pendingAutoSendID: String?
    let pendingAutoSendMessage: String?
    let onMenuAction: ((MenuAction) -> Void)?
    let onSessionSwitch: ((String) -> Void)?
    let onAgentSwitch: ((UUID) -> Void)?
    let onCreateLocalAgent: (() -> Void)?
    let onDeleteCurrentAgent: (() -> Void)?
    let onRenameCurrentAgent: ((String) -> Bool)?
    let modelConfig: AppConfig.LLMModel?
    let autoCompactEnabled: Bool
    let onToggleAutoCompact: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onMenuAction: onMenuAction,
            sessions: sessions,
            agents: agents,
            activeAgentID: activeAgentID,
            activeAgentName: activeAgentName,
            activeAgentEmoji: activeAgentEmoji,
            selectedModelName: selectedModelName,
            selectedProviderName: selectedProviderName,
            defaultSessionKey: defaultSessionKey,
            currentSessionKey: currentSessionKey,
            autoCompactEnabled: autoCompactEnabled,
            onSessionSwitch: onSessionSwitch,
            onAgentSwitch: onAgentSwitch,
            onCreateLocalAgent: onCreateLocalAgent,
            onDeleteCurrentAgent: onDeleteCurrentAgent,
            onRenameCurrentAgent: onRenameCurrentAgent,
            onToggleAutoCompact: onToggleAutoCompact
        )
    }

    func makeUIViewController(context: Context) -> ChatViewController {
        let makeNewConversationID: @MainActor () -> String = {
            "chat-\(UUID().uuidString)"
        }

        let storageProvider: any StorageProvider
        let sessionDelegate: SessionDelegate?
        if let runtimeRootURL, activeAgentID != nil {
            // Reuse one provider per runtime root so chat history survives view recreation.
            storageProvider = TranscriptStorageProvider.provider(runtimeRootURL: runtimeRootURL)
            sessionDelegate = AgentSessionDelegate(
                conversationID: conversationID,
                workspaceRootURL: workspaceRootURL,
                runtimeRootURL: runtimeRootURL,
                baseSystemPrompt: systemPrompt,
                chatClient: chatClient,
                agentName: activeAgentName,
                agentEmoji: activeAgentEmoji
            )
        } else {
            // New install / no active agent: avoid touching any runtime-root based agent pipeline.
            storageProvider = DisposableStorageProvider.shared
            sessionDelegate = nil
        }

        // Create session configuration
        let sessionConfiguration = ConversationSession.Configuration(
            storage: storageProvider,
            tools: toolProvider,
            delegate: sessionDelegate,
            systemPrompt: systemPrompt ?? "You are a helpful assistant.",
            collapseReasoningWhenComplete: true
        )

        // Create models with ChatClient
        var models = ConversationSession.Models()
        if let chatClient {
            models.chat = ConversationSession.Model(
                client: chatClient,
                capabilities: [.visual, .tool],
                contextLength: modelConfig?.contextTokens ?? 128_000,
                autoCompactEnabled: autoCompactEnabled
            )
        }

        // Create and configure ChatViewController
        let inputConfiguration = ChatInputConfiguration(
            quickSettingItems: buildQuickSettingItems()
        )
        let viewConfiguration = ChatViewController.Configuration(
            input: inputConfiguration,
            newConversationIDProvider: makeNewConversationID
        )
        let chatViewController: ChatViewController

        #if targetEnvironment(macCatalyst)
            let catalystController = CatalystChatViewController(
                conversationID: conversationID,
                models: models,
                sessionConfiguration: sessionConfiguration,
                configuration: viewConfiguration
            )
            catalystController.onOpenModelSettings = { [weak coordinator = context.coordinator] in
                coordinator?.onMenuAction?(.openLLM)
            }
            chatViewController = catalystController
        #else
            chatViewController = ChatViewController(
                conversationID: conversationID,
                models: models,
                sessionConfiguration: sessionConfiguration,
                configuration: viewConfiguration
            )
        #endif

        // Configure for navigation bar integration
        chatViewController.prefersNavigationBarManaged = false
        // Route top-right menu interactions back to SwiftUI.
        chatViewController.menuDelegate = context.coordinator
        chatViewController.updateHeader(.init(
            agentName: activeAgentName,
            agentEmoji: activeAgentEmoji,
            modelName: selectedModelName,
            providerName: selectedProviderName
        ))

        return chatViewController
    }

    private func buildQuickSettingItems() -> [QuickSettingItem] {
        var items: [QuickSettingItem] = [
            // Localize quick command labels while preserving the slash command token.
            .command(id: "new-conversation", title: L10n.tr("chat.command.newConversation"), icon: "plus", command: "/new"),
        ]

        let frequentSkills = buildFrequentSkillItems()
        items.append(contentsOf: frequentSkills)

        return items
    }

    private func buildFrequentSkillItems() -> [QuickSettingItem] {
        guard let workspaceRootURL else {
            return []
        }

        // Quick skills follow the available skill order directly.
        let availableSkills = AgentSkillsLoader
            .listSkills(filterUnavailable: true, workspaceRootURL: workspaceRootURL)

        // Return all available skills without limit
        return availableSkills.map { skill in
            .skill(
                id: "skill-\(quickSettingSafeID(skill.name))",
                title: skill.displayName,
                icon: skill.emoji ?? "asterisk",
                prompt: L10n.tr("chat.quickSkill.prompt", skill.displayName),
                autoSubmit: false
            )
        }
    }

    private func quickSettingSafeID(_ value: String) -> String {
        value
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "/", with: "-")
    }

    func updateUIViewController(_ uiViewController: ChatViewController, context: Context) {
        // Keep callbacks and data updated when SwiftUI state changes.
        context.coordinator.onMenuAction = onMenuAction
        context.coordinator.sessions = sessions
        context.coordinator.agents = agents
        context.coordinator.activeAgentID = activeAgentID
        context.coordinator.activeAgentName = activeAgentName
        context.coordinator.activeAgentEmoji = activeAgentEmoji
        context.coordinator.selectedModelName = selectedModelName
        context.coordinator.selectedProviderName = selectedProviderName
        context.coordinator.defaultSessionKey = defaultSessionKey
        context.coordinator.currentSessionKey = currentSessionKey

        // Auto-send on behalf of the intent if this is a new request.
        if let id = pendingAutoSendID,
           let message = pendingAutoSendMessage,
           id != context.coordinator.processedAutoSendID
        {
            context.coordinator.processedAutoSendID = id
            // Use the same submission path as manual user input.
            let content = ChatInputContent(text: message)
            uiViewController.chatInputDidSubmit(uiViewController.chatInputView, object: content) { _ in }
        }

        context.coordinator.onSessionSwitch = onSessionSwitch
        context.coordinator.onAgentSwitch = onAgentSwitch
        context.coordinator.onCreateLocalAgent = onCreateLocalAgent
        context.coordinator.onDeleteCurrentAgent = onDeleteCurrentAgent
        context.coordinator.onRenameCurrentAgent = onRenameCurrentAgent
        context.coordinator.autoCompactEnabled = autoCompactEnabled
        context.coordinator.onToggleAutoCompact = onToggleAutoCompact
        uiViewController.updateAutoCompactEnabled(autoCompactEnabled)

        #if targetEnvironment(macCatalyst)
            if let catalystController = uiViewController as? CatalystChatViewController {
                catalystController.onOpenModelSettings = { [weak coordinator = context.coordinator] in
                    coordinator?.onMenuAction?(.openLLM)
                }
            }
        #endif

        uiViewController.menuDelegate = context.coordinator
        uiViewController.updateHeader(.init(
            agentName: activeAgentName,
            agentEmoji: activeAgentEmoji,
            modelName: selectedModelName,
            providerName: selectedProviderName
        ))
    }
}

final class TranscriptStorageProvider: StorageProvider, @unchecked Sendable {
    private struct TranscriptContentBlock: Codable {
        struct ImageURL: Codable {
            let url: String
            let detail: String?
        }

        let type: String
        let text: String?
        let imageUrl: ImageURL?
        let toolCallId: String?
        let toolName: String?
        let toolCallState: String?
        let reasoningDuration: Double
    }

    private struct TranscriptLine: Codable {
        let id: String
        let role: String
        let timestamp: Double
        let content: [TranscriptContentBlock]
        let usage: [String: AnyCodable]?
        let toolCallId: String?
        let toolName: String?
        let stopReason: String?
        let idempotencyKey: String?
    }

    private struct SessionRecord: Codable {
        var key: String
        var kind: String
        var displayName: String
        var updatedAtMs: Int64
        var sessionId: String?
    }

    private struct SessionEnvelope: Codable {
        var sessions: [SessionRecord]
    }

    private static let providersLock = NSLock()
    private static var providersByRootPath: [String: TranscriptStorageProvider] = [:]

    static func provider(runtimeRootURL: URL) -> TranscriptStorageProvider {
        // Runtime root must be explicitly provided by agent configuration.
        let resolvedRoot = runtimeRootURL.standardizedFileURL
        let key = resolvedRoot.path
        providersLock.lock()
        defer { self.providersLock.unlock() }
        if let provider = providersByRootPath[key] {
            return provider
        }
        let provider = TranscriptStorageProvider(runtimeRootURL: resolvedRoot)
        providersByRootPath[key] = provider
        return provider
    }

    /// Remove the cached provider for the given runtime root.
    /// Called when deleting an agent to release memory and prevent stale data.
    static func removeProvider(runtimeRootURL: URL) {
        let resolvedRoot = runtimeRootURL.standardizedFileURL
        let key = resolvedRoot.path
        providersLock.lock()
        defer { self.providersLock.unlock() }
        providersByRootPath.removeValue(forKey: key)
    }

    private let runtimeRootURL: URL
    private let transcriptsDir: URL
    private let sessionsPath: URL
    private let lock = NSLock()

    private var messagesByConversation: [String: [ConversationMessage]] = [:]
    private var loadedConversations = Set<String>()
    private var sessionsByKey: [String: SessionRecord] = [:]
    private var didLoadSessions = false

    private init(runtimeRootURL: URL) {
        self.runtimeRootURL = runtimeRootURL
        transcriptsDir = runtimeRootURL.appendingPathComponent("transcripts", isDirectory: true)
        sessionsPath = runtimeRootURL.appendingPathComponent("sessions.json", isDirectory: false)
        prepareDirectories()
    }

    func listSessions() -> [ChatSession] {
        lock.lock()
        loadSessionsIfNeededLocked()
        let sorted = sessionsByKey.values.sorted { $0.updatedAtMs > $1.updatedAtMs }
        lock.unlock()
        return sorted.map { ChatSession(key: $0.key, displayName: $0.displayName, updatedAt: $0.updatedAtMs) }
    }

    func createMessage(in conversationID: String, role: MessageRole) -> ConversationMessage {
        let message = ConversationMessage(conversationID: conversationID, role: role)
        lock.lock()
        ensureConversationLoadedLocked(conversationID)
        messagesByConversation[conversationID, default: []].append(message)
        lock.unlock()
        return message
    }

    func save(_ messages: [ConversationMessage]) {
        guard let conversationID = messages.first?.conversationID else { return }
        lock.lock()
        ensureConversationLoadedLocked(conversationID)
        messagesByConversation[conversationID] = messages.sorted { $0.createdAt < $1.createdAt }
        upsertSessionLocked(for: conversationID, titleOverride: nil)
        persistConversationLocked(conversationID)
        persistSessionsLocked()
        lock.unlock()
    }

    func messages(in conversationID: String) -> [ConversationMessage] {
        lock.lock()
        ensureConversationLoadedLocked(conversationID)
        let messages = messagesByConversation[conversationID] ?? []
        lock.unlock()
        return messages.sorted { $0.createdAt < $1.createdAt }
    }

    func delete(_ messageIDs: [String]) {
        guard !messageIDs.isEmpty else { return }
        lock.lock()
        var changedConversations: [String] = []
        for (conversationID, messages) in messagesByConversation {
            let filtered = messages.filter { !messageIDs.contains($0.id) }
            if filtered.count != messages.count {
                messagesByConversation[conversationID] = filtered
                upsertSessionLocked(for: conversationID, titleOverride: nil)
                persistConversationLocked(conversationID)
                changedConversations.append(conversationID)
            }
        }
        if !changedConversations.isEmpty {
            persistSessionsLocked()
        }
        lock.unlock()
    }

    func title(for id: String) -> String? {
        lock.lock()
        loadSessionsIfNeededLocked()
        let title = sessionsByKey[id]?.displayName
        lock.unlock()
        return title
    }

    func setTitle(_ title: String, for id: String) {
        lock.lock()
        loadSessionsIfNeededLocked()
        upsertSessionLocked(for: id, titleOverride: title)
        persistSessionsLocked()
        lock.unlock()
    }

    private func prepareDirectories() {
        try? FileManager.default.createDirectory(at: runtimeRootURL, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: transcriptsDir, withIntermediateDirectories: true)
    }

    private func transcriptPath(for conversationID: String) -> URL {
        let safeKey = conversationID
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
        return transcriptsDir.appendingPathComponent("\(safeKey).jsonl", isDirectory: false)
    }

    private func ensureConversationLoadedLocked(_ conversationID: String) {
        guard !loadedConversations.contains(conversationID) else { return }
        messagesByConversation[conversationID] = loadConversationFromDiskLocked(conversationID)
        loadedConversations.insert(conversationID)
    }

    private func loadConversationFromDiskLocked(_ conversationID: String) -> [ConversationMessage] {
        let fileURL = transcriptPath(for: conversationID)
        guard let data = try? Data(contentsOf: fileURL),
              let text = String(data: data, encoding: .utf8)
        else {
            return []
        }

        var messages: [ConversationMessage] = []
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty,
                  let lineData = line.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode(TranscriptLine.self, from: lineData)
            else {
                continue
            }
            messages.append(makeConversationMessage(from: decoded, conversationID: conversationID))
        }
        return messages.sorted { $0.createdAt < $1.createdAt }
    }

    private func persistConversationLocked(_ conversationID: String) {
        let messages = (messagesByConversation[conversationID] ?? []).sorted { $0.createdAt < $1.createdAt }
        var lines: [String] = []
        for message in messages {
            guard let line = makeTranscriptLine(from: message).flatMap({ try? JSONEncoder().encode($0) }),
                  let text = String(data: line, encoding: .utf8)
            else {
                continue
            }
            lines.append(text)
        }
        let payload = lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
        let fileURL = transcriptPath(for: conversationID)
        try? payload.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    private func makeTranscriptLine(from message: ConversationMessage) -> TranscriptLine? {
        let blocks = mapContentBlocks(from: message.parts)
        let fallbackBlock = TranscriptContentBlock(
            type: "text",
            text: message.textContent,
            imageUrl: nil,
            toolCallId: nil,
            toolName: nil,
            toolCallState: nil,
            reasoningDuration: 0
        )
        let storedBlocks = blocks.isEmpty ? [fallbackBlock] : blocks
        let firstToolCall = firstToolCallPart(in: message.parts)
        let firstToolResult = firstToolResultPart(in: message.parts)

        return TranscriptLine(
            id: message.id,
            role: message.role.rawValue,
            timestamp: message.createdAt.timeIntervalSince1970 * 1000,
            content: storedBlocks,
            usage: nil,
            toolCallId: firstToolResult?.toolCallID,
            toolName: firstToolCall?.toolName,
            stopReason: message.finishReason?.rawValue,
            idempotencyKey: nil
        )
    }

    private func mapContentBlocks(from parts: [ContentPart]) -> [TranscriptContentBlock] {
        parts.compactMap { part in
            switch part {
            case let .text(textPart):
                return TranscriptContentBlock(
                    type: "text",
                    text: textPart.text,
                    imageUrl: nil,
                    toolCallId: nil,
                    toolName: nil,
                    toolCallState: nil,
                    reasoningDuration: 0
                )
            case let .reasoning(reasoningPart):
                return TranscriptContentBlock(
                    type: "reasoning",
                    text: reasoningPart.text,
                    imageUrl: nil,
                    toolCallId: nil,
                    toolName: nil,
                    toolCallState: nil,
                    reasoningDuration: reasoningPart.duration
                )
            case let .toolCall(toolCallPart):
                return TranscriptContentBlock(
                    type: "tool_call",
                    text: toolCallPart.parameters,
                    imageUrl: nil,
                    toolCallId: toolCallPart.id,
                    toolName: toolCallPart.toolName,
                    toolCallState: toolCallPart.state.rawValue,
                    reasoningDuration: 0
                )
            case let .toolResult(resultPart):
                return TranscriptContentBlock(
                    type: "tool_result",
                    text: resultPart.result,
                    imageUrl: nil,
                    toolCallId: resultPart.toolCallID,
                    toolName: nil,
                    toolCallState: nil,
                    reasoningDuration: 0
                )
            case let .image(imagePart):
                let label = imagePart.name ?? "image"
                return TranscriptContentBlock(
                    type: "image",
                    text: "[\(label)]",
                    imageUrl: nil,
                    toolCallId: nil,
                    toolName: nil,
                    toolCallState: nil,
                    reasoningDuration: 0
                )
            case let .audio(audioPart):
                let label = audioPart.name ?? "audio"
                return TranscriptContentBlock(
                    type: "audio",
                    text: "[\(label)]",
                    imageUrl: nil,
                    toolCallId: nil,
                    toolName: nil,
                    toolCallState: nil,
                    reasoningDuration: 0
                )
            case let .file(filePart):
                let label = filePart.name ?? "file"
                return TranscriptContentBlock(
                    type: "file",
                    text: "[\(label)]",
                    imageUrl: nil,
                    toolCallId: nil,
                    toolName: nil,
                    toolCallState: nil,
                    reasoningDuration: 0
                )
            }
        }
    }

    private func firstToolCallPart(in parts: [ContentPart]) -> ToolCallContentPart? {
        for part in parts {
            if case let .toolCall(value) = part {
                return value
            }
        }
        return nil
    }

    private func firstToolResultPart(in parts: [ContentPart]) -> ToolResultContentPart? {
        for part in parts {
            if case let .toolResult(value) = part {
                return value
            }
        }
        return nil
    }

    private func makeConversationMessage(from line: TranscriptLine, conversationID: String) -> ConversationMessage {
        let createdAt = Date(timeIntervalSince1970: line.timestamp / 1000)
        let message = ConversationMessage(
            id: line.id,
            conversationID: conversationID,
            role: MessageRole(rawValue: line.role),
            parts: mapParts(from: line),
            createdAt: createdAt,
            metadata: [:]
        )
        if let stopReason = line.stopReason {
            message.metadata["finishReason"] = stopReason
        }
        return message
    }

    private func mapParts(from line: TranscriptLine) -> [ContentPart] {
        var result: [ContentPart] = []
        for block in line.content {
            switch block.type {
            case "reasoning":
                if let text = block.text {
                    result.append(.reasoning(ReasoningContentPart(text: text, duration: block.reasoningDuration)))
                }
            case "tool_call":
                // Preserve the original tool-call id so UI toggles can find the matching result.
                let toolName = block.toolName ?? line.toolName ?? "Tool"
                let parameters = block.text ?? "{}"
                let toolCallState = ToolCallState(rawValue: block.toolCallState ?? "") ?? .succeeded
                result.append(
                    .toolCall(
                        ToolCallContentPart(
                            id: block.toolCallId ?? line.toolCallId ?? UUID().uuidString,
                            toolName: toolName,
                            parameters: parameters,
                            state: toolCallState
                        )
                    )
                )
            case "tool_result":
                let toolCallID = block.toolCallId ?? line.toolCallId ?? UUID().uuidString
                result.append(
                    .toolResult(
                        ToolResultContentPart(
                            toolCallID: toolCallID,
                            result: block.text ?? "",
                            isCollapsed: true
                        )
                    )
                )
            default:
                if let text = block.text {
                    result.append(.text(TextContentPart(text: text)))
                }
            }
        }
        return result
    }

    private func loadSessionsIfNeededLocked() {
        guard !didLoadSessions else { return }
        didLoadSessions = true
        guard let data = try? Data(contentsOf: sessionsPath),
              let envelope = try? JSONDecoder().decode(SessionEnvelope.self, from: data)
        else {
            sessionsByKey = [:]
            return
        }
        sessionsByKey = Dictionary(uniqueKeysWithValues: envelope.sessions.map { ($0.key, $0) })
    }

    private func upsertSessionLocked(for conversationID: String, titleOverride: String?) {
        loadSessionsIfNeededLocked()
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let existing = sessionsByKey[conversationID]
        let title = titleOverride ?? existing?.displayName ?? conversationID

        sessionsByKey[conversationID] = SessionRecord(
            key: conversationID,
            kind: existing?.kind ?? "chat",
            displayName: title,
            updatedAtMs: now,
            sessionId: existing?.sessionId
        )
    }

    private func persistSessionsLocked() {
        let sorted = sessionsByKey.values.sorted { $0.updatedAtMs > $1.updatedAtMs }
        let envelope = SessionEnvelope(sessions: sorted)
        guard let data = try? JSONEncoder().encode(envelope) else { return }
        try? data.write(to: sessionsPath, options: [.atomic])
    }
}

extension ChatViewControllerWrapper {
    final class Coordinator: NSObject, ChatViewControllerMenuDelegate {
        /// Tracks the last auto-sent request ID to prevent re-submission on re-render.
        var processedAutoSendID: String?
        var onMenuAction: ((MenuAction) -> Void)?
        var sessions: [ChatSession]
        var agents: [AgentProfile]
        var activeAgentID: UUID?
        var activeAgentName: String
        var activeAgentEmoji: String
        var selectedModelName: String
        var selectedProviderName: String
        var defaultSessionKey: String
        var currentSessionKey: String?
        var onSessionSwitch: ((String) -> Void)?
        var onAgentSwitch: ((UUID) -> Void)?
        var onCreateLocalAgent: (() -> Void)?
        var onDeleteCurrentAgent: (() -> Void)?
        var onRenameCurrentAgent: ((String) -> Bool)?
        var autoCompactEnabled: Bool
        var onToggleAutoCompact: (() -> Void)?

        init(
            onMenuAction: ((MenuAction) -> Void)?,
            sessions: [ChatSession],
            agents: [AgentProfile],
            activeAgentID: UUID?,
            activeAgentName: String,
            activeAgentEmoji: String,
            selectedModelName: String,
            selectedProviderName: String,
            defaultSessionKey: String,
            currentSessionKey: String?,
            autoCompactEnabled: Bool,
            onSessionSwitch: ((String) -> Void)?,
            onAgentSwitch: ((UUID) -> Void)?,
            onCreateLocalAgent: (() -> Void)?,
            onDeleteCurrentAgent: (() -> Void)?,
            onRenameCurrentAgent: ((String) -> Bool)?,
            onToggleAutoCompact: (() -> Void)?
        ) {
            self.onMenuAction = onMenuAction
            self.sessions = sessions
            self.agents = agents
            self.activeAgentID = activeAgentID
            self.activeAgentName = activeAgentName
            self.activeAgentEmoji = activeAgentEmoji
            self.selectedModelName = selectedModelName
            self.selectedProviderName = selectedProviderName
            self.defaultSessionKey = defaultSessionKey
            self.currentSessionKey = currentSessionKey
            self.autoCompactEnabled = autoCompactEnabled
            self.onSessionSwitch = onSessionSwitch
            self.onAgentSwitch = onAgentSwitch
            self.onCreateLocalAgent = onCreateLocalAgent
            self.onDeleteCurrentAgent = onDeleteCurrentAgent
            self.onRenameCurrentAgent = onRenameCurrentAgent
            self.onToggleAutoCompact = onToggleAutoCompact
        }

        func chatViewControllerMenu(_ controller: ChatViewController) -> UIMenu? {
            let renameTitle = L10n.tr("chat.menu.renameAgent")
            let deleteTitle = L10n.tr("chat.menu.deleteAgent")

            // Keep stable order: chat configuration first, then agent management.
            let modelAction = UIAction(
                title: L10n.tr("settings.llm.navigationTitle"),
                image: UIImage(systemName: "cpu")
            ) { [weak self] _ in
                self?.onMenuAction?(.openLLM)
            }
            let contextAction = UIAction(
                title: L10n.tr("settings.context.navigationTitle"),
                image: UIImage(systemName: "doc.text")
            ) { [weak self] _ in
                self?.onMenuAction?(.openContext)
            }
            let skillsAction = UIAction(
                title: L10n.tr("settings.skills.navigationTitle"),
                image: UIImage(systemName: "square.stack.3d.up")
            ) { [weak self] _ in
                self?.onMenuAction?(.openSkills)
            }
            let cronAction = UIAction(
                title: L10n.tr("settings.cron.navigationTitle"),
                image: UIImage(systemName: "calendar.badge.clock")
            ) { [weak self] _ in
                self?.onMenuAction?(.openCron)
            }
            let isBackgroundEnabled = BackgroundExecutionPreferences.shared.isEnabled
            let backgroundAction = UIAction(
                title: L10n.tr("settings.background.enabled"),
                image: UIImage(systemName: "arrow.down.app"),
                state: isBackgroundEnabled ? .on : .off
            ) { _ in
                let preferences = BackgroundExecutionPreferences.shared
                preferences.isEnabled.toggle()
                if preferences.isEnabled {
                    // Keep permission request aligned with settings page behavior.
                    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
                }
            }
            let autoCompactAction = UIAction(
                title: L10n.tr("chat.menu.autoCompact"),
                image: UIImage(systemName: "rectangle.compress.vertical"),
                state: autoCompactEnabled ? .on : .off
            ) { [weak self] _ in
                self?.onToggleAutoCompact?()
            }
            let renameAction = UIAction(
                title: renameTitle,
                image: UIImage(systemName: "pencil")
            ) { [weak self, weak controller] _ in
                guard let self, let controller else { return }
                self.presentRenameCurrentAgentAlert(from: controller)
            }
            let deleteAction = UIAction(
                title: deleteTitle,
                image: UIImage(systemName: "trash"),
                attributes: [.destructive]
            ) { [weak self, weak controller] _ in
                guard let self, let controller else { return }
                self.presentDeleteCurrentAgentAlert(from: controller)
            }

            let configurationMenu = UIMenu(
                // Keep title empty to remove the section header label in the menu.
                title: "",
                options: .displayInline,
                children: [
                    modelAction,
                    skillsAction,
                    contextAction,
                    cronAction,
                ]
            )
            let agentManagementMenu = UIMenu(
                title: "",
                options: .displayInline,
                children: [backgroundAction, autoCompactAction, renameAction, deleteAction]
            )

            return UIMenu(children: [
                configurationMenu,
                agentManagementMenu,
            ])
        }

        private func presentDeleteCurrentAgentAlert(from controller: ChatViewController) {
            guard activeAgentID != nil else { return }
            let normalizedName = activeAgentName.trimmingCharacters(in: .whitespacesAndNewlines)
            let agentName = normalizedName.isEmpty ? L10n.tr("chat.menu.thisAgent") : "\"\(normalizedName)\""
            let alert = UIAlertController(
                title: L10n.tr("chat.menu.deleteAlert.title"),
                message: L10n.tr("chat.menu.deleteAlert.message", agentName),
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: L10n.tr("common.cancel"), style: .cancel))
            alert.addAction(UIAlertAction(title: L10n.tr("common.delete"), style: .destructive) { [weak self] _ in
                self?.onDeleteCurrentAgent?()
            })
            controller.present(alert, animated: true)
        }

        private func presentRenameCurrentAgentAlert(from controller: ChatViewController) {
            guard activeAgentID != nil else { return }
            let alert = UIAlertController(
                title: L10n.tr("chat.menu.renameAgentNamed", activeAgentName),
                message: L10n.tr("chat.menu.renameAlert.message"),
                preferredStyle: .alert
            )

            alert.addTextField { [activeAgentName] textField in
                textField.placeholder = L10n.tr("chat.menu.renameAlert.placeholder")
                textField.text = activeAgentName
                textField.clearButtonMode = .whileEditing
            }

            alert.addAction(UIAlertAction(title: L10n.tr("common.cancel"), style: .cancel))
            alert.addAction(UIAlertAction(title: L10n.tr("common.save"), style: .default) { [weak self, weak alert] _ in
                guard let self,
                      let rawName = alert?.textFields?.first?.text
                else {
                    return
                }

                let normalizedName = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !normalizedName.isEmpty else { return }

                let didRename = self.onRenameCurrentAgent?(normalizedName) ?? false
                if !didRename {
                    self.presentRenameFailedAlert(from: controller)
                }
            })

            controller.present(alert, animated: true)
        }

        private func presentRenameFailedAlert(from controller: ChatViewController) {
            let alert = UIAlertController(
                title: L10n.tr("chat.menu.renameFailed.title"),
                message: L10n.tr("chat.menu.renameFailed.message"),
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: L10n.tr("common.ok"), style: .default))
            controller.present(alert, animated: true)
        }

        func chatViewControllerLeadingButton(_: ChatViewController, button: UIButton) {
            button.showsMenuAsPrimaryAction = true
            button.menu = buildAgentMenu()
        }

        func chatViewControllerDidTapAgentTitle(_ controller: ChatViewController) {
            controller.presentLeadingMenu()
        }

        func chatViewControllerDidTapModelTitle(_ controller: ChatViewController) {
            _ = controller
            onMenuAction?(.openLLM)
        }

        func chatViewControllerRequestNewConversationID(_ controller: ChatViewController, from _: String) -> String? {
            _ = controller
            let newID = "chat-\(UUID().uuidString)"
            onSessionSwitch?(newID)
            return newID
        }

        private func buildAgentMenu() -> UIMenu {
            let agentActions: [UIAction]
            if agents.isEmpty {
                agentActions = [
                    UIAction(title: L10n.tr("chat.menu.noAgentsAvailable"), attributes: [.disabled]) { _ in },
                ]
            } else {
                agentActions = agents.map { agent in
                    let title = agent.name
                    let image = self.makeAgentMenuImage(for: agent)
                    let state: UIMenuElement.State = (agent.id == self.activeAgentID) ? .on : .off
                    return UIAction(title: title, image: image, state: state) { [weak self] _ in
                        self?.onAgentSwitch?(agent.id)
                    }
                }
            }

            // Keep creation entries in a separate inline section so they stay at the bottom.
            let createLocalAction = UIAction(
                title: L10n.tr("chat.menu.newLocalAgent"),
                image: UIImage(systemName: "plus")
            ) { [weak self] _ in
                self?.onCreateLocalAgent?()
            }
            // Entry is intentionally hidden until remote agent flow is fully tested.
            // let addRemoteAction = UIAction(
            //     title: "Add Remote Agent (Remote Gateway Agent)",
            //     image: UIImage(systemName: "network"))
            // { [weak self] _ in
            //     self?.onAddRemoteAgent?()
            // }

            let agentSection = UIMenu(title: "", options: .displayInline, children: agentActions)
            let entrySection = UIMenu(title: "", options: .displayInline, children: [createLocalAction])
            return UIMenu(title: "", children: [agentSection, entrySection])
        }

        private func makeAgentMenuImage(for agent: AgentProfile) -> UIImage? {
            let prefix = "agent:\(agent.id.uuidString)::"
            let isRunning = ConversationSessionManager.shared.hasExecutingSession(withPrefix: prefix)
            return makeEmojiMenuImage(from: agent.emoji, showsRunningIndicator: isRunning)
        }

        private func makeEmojiMenuImage(from emoji: String, showsRunningIndicator: Bool) -> UIImage? {
            let trimmed = emoji.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty, !showsRunningIndicator {
                return nil
            }

            let size = CGSize(width: 20, height: 20)
            let renderer = UIGraphicsImageRenderer(size: size)
            let image = renderer.image { context in
                if !trimmed.isEmpty {
                    let paragraph = NSMutableParagraphStyle()
                    paragraph.alignment = .center

                    let attributes: [NSAttributedString.Key: Any] = [
                        .font: UIFont.systemFont(ofSize: 16),
                        .paragraphStyle: paragraph,
                    ]

                    let text = trimmed as NSString
                    let textSize = text.size(withAttributes: attributes)
                    let rect = CGRect(
                        x: (size.width - textSize.width) / 2,
                        y: (size.height - textSize.height) / 2,
                        width: textSize.width,
                        height: textSize.height
                    )
                    text.draw(in: rect, withAttributes: attributes)
                }

                if showsRunningIndicator {
                    // Draw a small green dot to indicate there is an in-flight task.
                    let dotDiameter: CGFloat = 7
                    let dotRect = CGRect(
                        x: size.width - dotDiameter - 1,
                        y: size.height - dotDiameter - 1,
                        width: dotDiameter,
                        height: dotDiameter
                    )
                    context.cgContext.setFillColor(UIColor.systemGreen.cgColor)
                    context.cgContext.fillEllipse(in: dotRect)

                    context.cgContext.setStrokeColor(UIColor.systemBackground.cgColor)
                    context.cgContext.setLineWidth(1)
                    context.cgContext.strokeEllipse(in: dotRect.insetBy(dx: 0.5, dy: 0.5))
                }
            }

            return image.withRenderingMode(.alwaysOriginal)
        }
    }
}
