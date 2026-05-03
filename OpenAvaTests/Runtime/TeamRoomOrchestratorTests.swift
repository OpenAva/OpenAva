import Foundation
import XCTest
@testable import OpenAva

@MainActor
final class TeamRoomOrchestratorTests: XCTestCase {
    func testResolveParticipantsForCustomTeamUsesAgentPoolOrder() {
        let first = makeAgent(name: "First", emoji: "1️⃣")
        let second = makeAgent(name: "Second", emoji: "2️⃣")
        let third = makeAgent(name: "Third", emoji: "3️⃣")
        let team = TeamProfile(
            name: "Focused Team",
            agentPoolIDs: [third.id, first.id]
        )

        let participants = TeamRoomOrchestrator.resolveParticipants(
            activeContext: .team(team.id),
            teams: [team],
            agents: [first, second, third]
        )

        XCTAssertEqual(participants.map(\.id), [third.id, first.id])
        XCTAssertFalse(participants.contains(second))
    }

    func testAppendAgentReplyWritesVisibleAgentMetadataToRoomTranscript() {
        let storage = DisposableStorageProvider()
        let session = ConversationSession(
            id: "team-room-test",
            configuration: .init(storage: storage)
        )
        let agent = makeAgent(name: "Reviewer", emoji: "🧪")
        let team = TeamProfile(name: "Review Team", agentPoolIDs: [agent.id])
        let context = TeamRoomOrchestrator.SubmissionContext(
            activeContext: .team(team.id),
            teams: [team],
            agents: [agent],
            fallbackModelConfig: nil,
            agentCount: 1
        )

        let message = TeamRoomOrchestrator.appendAgentReply(
            .init(agent: agent, text: "Agent-authored response", isError: false),
            to: session,
            context: context,
            turnID: "turn-123"
        )

        XCTAssertEqual(message.role, .assistant)
        XCTAssertEqual(message.textContent, "Agent-authored response")
        XCTAssertEqual(message.metadata["agentID"], agent.id.uuidString)
        XCTAssertEqual(message.metadata["agentName"], "Reviewer")
        XCTAssertEqual(message.metadata["agentEmoji"], "🧪")
        XCTAssertEqual(message.metadata["teamID"], team.id.uuidString)
        XCTAssertEqual(message.metadata["teamRoomTurnID"], "turn-123")
        XCTAssertEqual(message.metadata[ConversationSession.PromptInput.sourceMetadataKey], "team_room_agent_reply")

        let persisted = storage.messages(in: session.id)
        XCTAssertEqual(persisted.last?.id, message.id)
        XCTAssertEqual(persisted.last?.metadata["agentName"], "Reviewer")
        XCTAssertEqual(persisted.last?.metadata["teamRoomTurnID"], "turn-123")
    }

    func testApplyAgentMetadataCanMarkToolMessagesInCanonicalRoomTranscript() {
        let session = ConversationSession(
            id: "team-room-tool-test",
            configuration: .init(storage: DisposableStorageProvider())
        )
        let agent = makeAgent(name: "Builder", emoji: "🛠️")
        let context = TeamRoomOrchestrator.SubmissionContext(
            activeContext: .allAgentsTeam,
            teams: [],
            agents: [agent],
            fallbackModelConfig: nil,
            agentCount: 1
        )
        let toolMessage = session.appendNewMessage(role: .tool)

        TeamRoomOrchestrator.applyAgentMetadata(
            to: toolMessage,
            agent: agent,
            context: context,
            turnID: "turn-tool",
            source: "team_room_agent_tool_result"
        )

        XCTAssertEqual(toolMessage.metadata["agentID"], agent.id.uuidString)
        XCTAssertEqual(toolMessage.metadata["agentName"], "Builder")
        XCTAssertEqual(toolMessage.metadata["teamRoomTurnID"], "turn-tool")
        XCTAssertEqual(toolMessage.metadata["teamRoomContext"], "globalTeam")
        XCTAssertEqual(toolMessage.metadata[ConversationSession.PromptInput.sourceMetadataKey], "team_room_agent_tool_result")
    }

    private func makeAgent(name: String, emoji: String) -> AgentProfile {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        return AgentProfile(
            name: name,
            emoji: emoji,
            workspacePath: root.appendingPathComponent("workspace", isDirectory: true).path,
            localContextPath: root.path
        )
    }
}
