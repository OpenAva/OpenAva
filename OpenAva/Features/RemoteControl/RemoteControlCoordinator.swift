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
        await SkillLaunchService.enqueueAutoSend(message: message)
        return .init(enqueued: true)
    }

    func pairCodeDidUpdate(_ code: String, peerName: String) {
        RemoteControlStatusStore.shared.updatePairingCode(code, peerName: peerName)
    }
}
