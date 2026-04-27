import Foundation
import XCTest
@testable import OpenAva

final class ChatSubmissionHelpersTests: XCTestCase {
    func testResolveTeamPromptMentionTargetRecognizesLocalizedEveryoneMention() {
        let token = localizedEveryoneMentionToken()

        let result = resolveTeamPromptMentionTarget(
            in: "\(token) 请同步一下进度",
            agents: []
        )

        XCTAssertEqual(result, .everyone(message: "请同步一下进度"))
    }

    func testResolveTeamPromptMentionTargetRecognizesPrimaryAllMentionAlias() {
        let result = resolveTeamPromptMentionTarget(
            in: "@all share your updates",
            agents: []
        )

        XCTAssertEqual(result, .everyone(message: "share your updates"))
    }

    func testResolveTeamPromptMentionTargetRecognizesLegacyEveryoneAlias() {
        let result = resolveTeamPromptMentionTarget(
            in: "@everyone share your updates",
            agents: []
        )

        XCTAssertEqual(result, .everyone(message: "share your updates"))
    }

    func testResolveTeamPromptMentionTargetRecognizesSpecificAgentMention() {
        let agent = makeAgent(name: "Alice", emoji: "🪄")

        let result = resolveTeamPromptMentionTarget(
            in: "请 @Alice 跟进这个问题",
            agents: [agent]
        )

        XCTAssertEqual(result, .agent(agent))
    }

    func testResolveTeamPromptMentionTargetDoesNotTreatEmailAsEveryoneMention() {
        let result = resolveTeamPromptMentionTarget(
            in: "联系 foo@everyone.com 获取更多信息",
            agents: []
        )

        XCTAssertEqual(result, .none)
    }

    private func makeAgent(name: String, emoji: String) -> AgentProfile {
        AgentProfile(
            id: UUID(),
            name: name,
            emoji: emoji,
            workspacePath: "/tmp/workspace-\(UUID().uuidString)",
            localRuntimePath: "/tmp/runtime-\(UUID().uuidString)"
        )
    }
}
