import Foundation
import XCTest
@testable import OpenAva

final class TeamMentionResolverTests: XCTestCase {
    // MARK: - parseAddressed

    func testParseAddressedReturnsExactNameForAtMention() {
        let result = TeamMentionResolver.parseAddressed(
            from: #"{"addressed": ["Jett"]}"#,
            agentNames: ["Jett", "Alice", "Bob"]
        )
        XCTAssertEqual(result, ["Jett"])
    }

    func testParseAddressedIsCaseInsensitive() {
        let result = TeamMentionResolver.parseAddressed(
            from: #"{"addressed": ["jett"]}"#,
            agentNames: ["Jett", "Alice"]
        )
        XCTAssertEqual(result, ["jett"])
    }

    func testParseAddressedEmptyArrayForBroadcast() {
        let result = TeamMentionResolver.parseAddressed(
            from: #"{"addressed": []}"#,
            agentNames: ["Jett", "Alice"]
        )
        XCTAssertTrue(result.isEmpty)
    }

    func testParseAddressedFiltersOutUnknownNames() {
        let result = TeamMentionResolver.parseAddressed(
            from: #"{"addressed": ["Jett", "Ghost"]}"#,
            agentNames: ["Jett", "Alice"]
        )
        XCTAssertEqual(result, ["Jett"])
    }

    func testParseAddressedHandlesMultipleAddressed() {
        let result = TeamMentionResolver.parseAddressed(
            from: #"{"addressed": ["Jett", "Alice"]}"#,
            agentNames: ["Jett", "Alice", "Bob"]
        )
        XCTAssertEqual(Set(result), Set(["Jett", "Alice"]))
    }

    func testParseAddressedToleratesWrappingText() {
        // LLMs sometimes produce preamble before the JSON.
        let result = TeamMentionResolver.parseAddressed(
            from: "Sure! {\"addressed\": [\"Alice\"]} Hope this helps.",
            agentNames: ["Jett", "Alice"]
        )
        XCTAssertEqual(result, ["Alice"])
    }

    func testParseAddressedReturnsEmptyForMalformedJSON() {
        let result = TeamMentionResolver.parseAddressed(
            from: "I cannot determine this.",
            agentNames: ["Jett", "Alice"]
        )
        XCTAssertTrue(result.isEmpty)
    }

    func testParseAddressedReturnsEmptyForEmptyText() {
        let result = TeamMentionResolver.parseAddressed(from: "", agentNames: ["Jett"])
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - resolveAddressedParticipants integration (no LLM – single/zero agent short-circuits)

    @MainActor
    func testResolveAddressedParticipantsReturnsSingleAgentWithoutLLMCall() async {
        let jett = makeAgent(name: "Jett")
        let storage = DisposableStorageProvider()
        let session = ConversationSession(id: "test", configuration: .init(storage: storage))
        let context = TeamRoomOrchestrator.SubmissionContext(
            activeContext: .globalTeam,
            teams: [],
            agents: [jett],
            fallbackModelConfig: nil,
            agentCount: 1
        )
        // With only 1 participant and no model, the guard returns immediately.
        let result = await TeamRoomOrchestrator.shared.resolveAddressedParticipants(
            all: [jett],
            roomSession: session,
            context: context,
            turnID: "t1"
        )
        XCTAssertEqual(result.map(\.id), [jett.id])
    }

    @MainActor
    func testResolveAddressedParticipantsReturnsAllWhenNoFallbackModel() async {
        let jett = makeAgent(name: "Jett")
        let alice = makeAgent(name: "Alice")
        let storage = DisposableStorageProvider()
        let session = ConversationSession(id: "test2", configuration: .init(storage: storage))
        let context = TeamRoomOrchestrator.SubmissionContext(
            activeContext: .globalTeam,
            teams: [],
            agents: [jett, alice],
            fallbackModelConfig: nil, // no model → should broadcast
            agentCount: 2
        )
        let result = await TeamRoomOrchestrator.shared.resolveAddressedParticipants(
            all: [jett, alice],
            roomSession: session,
            context: context,
            turnID: "t2"
        )
        XCTAssertEqual(result.map(\.id), [jett.id, alice.id])
    }

    // MARK: - Private helpers

    private func makeAgent(name: String) -> AgentProfile {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        return AgentProfile(
            name: name,
            emoji: "🤖",
            workspacePath: root.appendingPathComponent("workspace", isDirectory: true).path,
            localRuntimePath: root.appendingPathComponent("runtime", isDirectory: true).path
        )
    }
}
