import ChatClient
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
            members: [third.id, first.id]
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
        let team = TeamProfile(name: "Review Team", members: [agent.id])
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
        XCTAssertEqual(message.metadata["agentID"], agent.id)
        XCTAssertEqual(message.metadata["agentName"], "Reviewer")
        XCTAssertEqual(message.metadata["agentEmoji"], "🧪")
        XCTAssertEqual(message.metadata["teamID"], team.id)
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

        XCTAssertEqual(toolMessage.metadata["agentID"], agent.id)
        XCTAssertEqual(toolMessage.metadata["agentName"], "Builder")
        XCTAssertEqual(toolMessage.metadata["teamRoomTurnID"], "turn-tool")
        XCTAssertEqual(toolMessage.metadata["teamRoomContext"], "globalTeam")
        XCTAssertEqual(toolMessage.metadata[ConversationSession.PromptInput.sourceMetadataKey], "team_room_agent_tool_result")
    }

    func testBuildAgentRequestMessagesIncludesSameTurnPriorAgentReplies() async {
        let session = ConversationSession(
            id: "team-room-visible-context-test",
            configuration: .init(storage: DisposableStorageProvider())
        )
        let lila = makeAgent(name: "Lila", emoji: "🦞")
        let nova = makeAgent(name: "Nova", emoji: "🔭")
        let context = TeamRoomOrchestrator.SubmissionContext(
            activeContext: .allAgentsTeam,
            teams: [],
            agents: [lila, nova],
            fallbackModelConfig: nil,
            agentCount: 2
        )
        let turnID = "turn-visible"

        _ = session.appendNewMessage(role: .user) { message in
            message.textContent = "你们相互挑战下各自的观点"
            message.metadata["teamRoomTurnID"] = turnID
            message.metadata["teamRoomContext"] = "globalTeam"
            message.metadata[ConversationSession.PromptInput.sourceMetadataKey] = "user"
        }
        TeamRoomOrchestrator.appendAgentReply(
            .init(agent: lila, text: "Layer 2 是最大机会，但需要防大厂免费开放。", isError: false),
            to: session,
            context: context,
            turnID: turnID
        )

        let requestMessages = await TeamRoomOrchestrator.shared.buildAgentRequestMessages(
            roomSession: session,
            capabilities: [],
            turnID: turnID
        )
        let userTexts = requestMessages.compactMap(Self.userText)

        XCTAssertTrue(userTexts.contains("你们相互挑战下各自的观点"))
        XCTAssertTrue(userTexts.contains { text in
            text.contains("[Team Room Agent: 🦞 Lila]")
                && text.contains("Layer 2 是最大机会")
        })
        XCTAssertFalse(requestMessages.contains { message in
            if case .assistant = message { return true }
            return false
        })
    }

    private static func userText(from message: ChatRequestBody.Message) -> String? {
        guard case let .user(content, _) = message else { return nil }
        guard case let .text(text) = content else { return nil }
        return text
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
