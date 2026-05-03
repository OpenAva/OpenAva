import ChatClient
import ChatUI
import Foundation

@MainActor
final class AgentMainSessionRegistry {
    static let shared = AgentMainSessionRegistry()

    struct SessionResources: @unchecked Sendable {
        let session: ConversationSession
        let storageProvider: TranscriptStorageProvider
        let sessionDelegate: AgentSessionDelegate
        let toolRuntime: ToolRuntime
        let toolProvider: ToolRegistryProvider
    }

    private struct CacheKey: Hashable {
        let agentID: UUID
        let modelID: UUID?
        let modelName: String
        let providerName: String
        let agentCount: Int
        let workspacePath: String
        let supportPath: String
        let mainSessionID: String
    }

    private struct CachedEntry {
        let key: CacheKey
        let resources: SessionResources
    }

    /// Serializes execution requests targeting the same agent main session.
    ///
    /// Rationale: Multiple entry points (UI, Team, Heartbeat) can submit turns to the same
    /// `ConversationSession`. Without a shared executor, later submissions will invoke
    /// `submitMessage` and trigger `.taskReplaced` cancellation on an in-flight task.
    private actor MainSessionExecutor {
        private var isRunning = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func enqueue<T: Sendable>(
            _ operation: @escaping @Sendable () async throws -> T
        ) async throws -> T {
            await acquire()
            defer { release() }
            return try await operation()
        }

        private func acquire() async {
            if !isRunning {
                isRunning = true
                return
            }

            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }

        private func release() {
            if waiters.isEmpty {
                isRunning = false
                return
            }

            let next = waiters.removeFirst()
            next.resume()
        }
    }

    private var entriesByAgentID: [UUID: CachedEntry] = [:]
    private var executorsByKey: [CacheKey: MainSessionExecutor] = [:]

    private init() {}

    /// Submit a turn to the agent's canonical main session, serialized across all entry points.
    func submitToMainSession<T: Sendable>(
        for agent: AgentProfile,
        modelConfig: AppConfig.LLMModel,
        invocationSessionID: String,
        shouldExtractDurableMemory: Bool = true,
        agentCount: Int = 1,
        operation: @escaping @MainActor (SessionResources) async throws -> T
    ) async throws -> T {
        let mainSessionID = resolvedMainSessionID(from: invocationSessionID)
        let normalizedAgentCount = max(agentCount, 1)
        let key = CacheKey(
            agentID: agent.id,
            modelID: modelConfig.id,
            modelName: modelConfig.model ?? "",
            providerName: modelConfig.provider,
            agentCount: normalizedAgentCount,
            workspacePath: agent.workspaceURL.standardizedFileURL.path,
            supportPath: agent.contextURL.standardizedFileURL.path,
            mainSessionID: mainSessionID
        )
        let resources = sessionResources(
            for: agent,
            modelConfig: modelConfig,
            invocationSessionID: invocationSessionID,
            shouldExtractDurableMemory: shouldExtractDurableMemory,
            agentCount: normalizedAgentCount
        )
        let executor = executorsByKey[key] ?? {
            let created = MainSessionExecutor()
            executorsByKey[key] = created
            return created
        }()

        return try await executor.enqueue {
            try await operation(resources)
        }
    }

    func sessionResources(
        for agent: AgentProfile,
        modelConfig: AppConfig.LLMModel,
        invocationSessionID: String,
        shouldExtractDurableMemory: Bool = true,
        agentCount: Int = 1
    ) -> SessionResources {
        let mainSessionID = resolvedMainSessionID(from: invocationSessionID)
        let normalizedAgentCount = max(agentCount, 1)
        let key = CacheKey(
            agentID: agent.id,
            modelID: modelConfig.id,
            modelName: modelConfig.model ?? "",
            providerName: modelConfig.provider,
            agentCount: normalizedAgentCount,
            workspacePath: agent.workspaceURL.standardizedFileURL.path,
            supportPath: agent.contextURL.standardizedFileURL.path,
            mainSessionID: mainSessionID
        )

        if let cached = entriesByAgentID[agent.id], cached.key == key {
            return cached.resources
        }

        let storageProvider = TranscriptStorageProvider.provider(supportRootURL: agent.contextURL)
        let sessionDelegate = AgentSessionDelegate(
            sessionID: mainSessionID,
            supportRootURL: agent.contextURL,
            workspaceRootURL: agent.workspaceURL,
            chatClient: nil,
            agentName: agent.name,
            agentEmoji: agent.emoji,
            shouldExtractDurableMemory: shouldExtractDurableMemory
        )
        let toolRuntime = ToolRuntime.makeDefault(
            workspaceRootURL: agent.workspaceURL,
            supportRootURL: agent.contextURL,
            teamsRootURL: agent.workspaceURL,
            modelConfig: modelConfig,
            agentCount: normalizedAgentCount
        )
        let toolProvider = ToolRegistryProvider(
            toolRuntime: toolRuntime,
            invocationSessionID: invocationSessionID
        )
        let sessionConfiguration = ConversationSession.Configuration(
            storage: storageProvider,
            tools: toolProvider,
            delegate: sessionDelegate,
            systemPromptProvider: {
                AgentContextLoader.composeSystemPrompt(
                    baseSystemPrompt: modelConfig.systemPrompt,
                    workspaceRootURL: agent.contextURL,
                    agentCount: normalizedAgentCount
                ) ?? "You are a helpful assistant."
            },
            collapseReasoningWhenComplete: true,
            toolPermissionRulesRootURL: agent.workspaceURL
        )
        let session = ConversationSessionManager.shared.session(
            for: mainSessionID,
            configuration: sessionConfiguration
        )
        session.models = ConversationSession.Models(
            chat: ConversationSession.Model(
                client: LLMChatClient(modelConfig: modelConfig),
                capabilities: [.visual, .tool],
                contextLength: modelConfig.contextTokens,
                maxOutputTokens: modelConfig.resolvedMaxOutputTokens,
                autoCompactEnabled: agent.autoCompactEnabled
            )
        )

        let resources = SessionResources(
            session: session,
            storageProvider: storageProvider,
            sessionDelegate: sessionDelegate,
            toolRuntime: toolRuntime,
            toolProvider: toolProvider
        )
        entriesByAgentID[agent.id] = CachedEntry(key: key, resources: resources)
        return resources
    }

    func remove(agentID: UUID) {
        entriesByAgentID.removeValue(forKey: agentID)
        executorsByKey = executorsByKey.filter { $0.key.agentID != agentID }
    }

    func removeAll() {
        entriesByAgentID.removeAll()
        executorsByKey.removeAll()
    }

    private func resolvedMainSessionID(from invocationSessionID: String) -> String {
        let trimmedInvocationSessionID = invocationSessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInvocationSessionID.isEmpty else {
            return TeamSwarmCoordinator.mainSessionID
        }
        guard let separatorRange = trimmedInvocationSessionID.range(of: "::") else {
            return trimmedInvocationSessionID
        }
        let suffix = trimmedInvocationSessionID[separatorRange.upperBound...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return suffix.isEmpty ? TeamSwarmCoordinator.mainSessionID : suffix
    }
}
