import Foundation
import OpenClawKit

@MainActor
final class RemoteControlCoordinator {
    static let shared = RemoteControlCoordinator()

    struct State: Equatable {
        var activeAgentID: UUID?
        var activeSessionKey: String?
        var defaultSessionKey: String
        var sessionSummaries: [ChatSession]
        var runtimeRootURL: URL?
    }

    private var state = State(
        activeAgentID: nil,
        activeSessionKey: nil,
        defaultSessionKey: "main",
        sessionSummaries: [],
        runtimeRootURL: nil
    )

    private weak var containerStore: AppContainerStore?
    private var setSessionKey: ((String) -> Void)?

    private init() {}

    func bind(containerStore: AppContainerStore, setSessionKey: @escaping (String) -> Void) {
        self.containerStore = containerStore
        self.setSessionKey = setSessionKey
        refresh(
            activeAgentID: containerStore.activeAgent?.id,
            activeSessionKey: containerStore.activeAgent?.selectedSessionKey,
            defaultSessionKey: containerStore.container.defaultSessionKey,
            sessions: [],
            runtimeRootURL: containerStore.activeAgent?.runtimeURL
        )
    }

    func refresh(
        activeAgentID: UUID?,
        activeSessionKey: String?,
        defaultSessionKey: String,
        sessions: [ChatSession],
        runtimeRootURL: URL?
    ) {
        state = State(
            activeAgentID: activeAgentID,
            activeSessionKey: normalizedSessionKey(activeSessionKey, fallback: defaultSessionKey),
            defaultSessionKey: normalizedSessionKey(defaultSessionKey, fallback: "main"),
            sessionSummaries: sessions,
            runtimeRootURL: runtimeRootURL
        )
    }

    func listAgents() -> LocalControlListAgentsPayload {
        let agents = containerStore?.agents ?? []
        let activeID = containerStore?.activeAgent?.id.uuidString
        return .init(
            agents: agents.map { agent in
                .init(
                    id: agent.id.uuidString,
                    name: agent.name,
                    emoji: agent.emoji,
                    isActive: agent.id.uuidString == activeID
                )
            },
            activeAgentID: activeID
        )
    }

    func selectAgent(id rawID: String) -> LocalControlSelectAgentPayload? {
        guard let uuid = UUID(uuidString: rawID),
              containerStore?.setActiveAgent(uuid) == true
        else {
            return nil
        }
        return .init(activeAgentID: rawID)
    }

    func listSessions(agentID _: String?) -> LocalControlListSessionsPayload {
        let activeKey = currentSessionKey
        let summaries = state.sessionSummaries.map { session in
            LocalControlSessionSummary(
                key: session.key,
                displayName: session.displayName,
                updatedAtMs: session.updatedAt,
                isActive: session.key == activeKey
            )
        }
        return .init(sessions: summaries, activeSessionKey: activeKey)
    }

    func createSession(preferredKey: String?) -> LocalControlCreateSessionPayload {
        let candidate = normalizedSessionKey(preferredKey, fallback: "chat-\(UUID().uuidString)")
        setSessionKey?(candidate)
        let summary = LocalControlSessionSummary(
            key: candidate,
            displayName: candidate,
            updatedAtMs: Int64(Date().timeIntervalSince1970 * 1000),
            isActive: true
        )
        return .init(session: summary)
    }

    func selectSession(key: String) -> LocalControlSelectSessionPayload {
        let normalized = normalizedSessionKey(key, fallback: state.defaultSessionKey)
        setSessionKey?(normalized)
        return .init(activeSessionKey: normalized)
    }

    func sendMessage(_ message: String, sessionKey: String?) async -> LocalControlSendMessagePayload {
        let normalizedSession = normalizedSessionKey(sessionKey, fallback: currentSessionKey)
        setSessionKey?(normalizedSession)
        await SkillInvocationService.enqueueAutoSend(message: message, conversationID: normalizedSession)
        return .init(enqueued: true, sessionKey: normalizedSession)
    }

    func pairCodeDidUpdate(_ code: String, peerName: String) {
        RemoteControlStatusStore.shared.updatePairingCode(code, peerName: peerName)
    }

    private var currentSessionKey: String {
        normalizedSessionKey(state.activeSessionKey, fallback: state.defaultSessionKey)
    }

    private func normalizedSessionKey(_ key: String?, fallback: String) -> String {
        let trimmed = (key ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackTrimmed = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? (fallbackTrimmed.isEmpty ? "main" : fallbackTrimmed) : trimmed
    }
}
