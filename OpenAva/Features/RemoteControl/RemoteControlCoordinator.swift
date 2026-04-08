import Foundation
import OpenClawKit

@MainActor
final class RemoteControlCoordinator {
    static let shared = RemoteControlCoordinator()

    private weak var containerStore: AppContainerStore?

    private init() {}

    func bind(containerStore: AppContainerStore) {
        self.containerStore = containerStore
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

    func sendMessage(_ message: String) async -> LocalControlSendMessagePayload {
        await SkillLaunchService.enqueueAutoSend(message: message, sessionID: currentSessionID)
        return .init(enqueued: true)
    }

    func pairCodeDidUpdate(_ code: String, peerName: String) {
        RemoteControlStatusStore.shared.updatePairingCode(code, peerName: peerName)
    }

    private var currentSessionID: String {
        let defaultSessionKey = containerStore?.container.defaultSessionKey
        return normalizedSessionKey(defaultSessionKey, fallback: "main")
    }

    private func normalizedSessionKey(_ key: String?, fallback: String) -> String {
        let trimmed = (key ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackTrimmed = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? (fallbackTrimmed.isEmpty ? "main" : fallbackTrimmed) : trimmed
    }
}
