import XCTest
@testable import OpenAva

final class TeamSwarmCapabilityTests: XCTestCase {
    func testTeamToolDefinitionsExposeCoreSwarmTools() {
        let definitions = TeamToolDefinitions().toolDefinitions()
        let functionNames = Set(definitions.map(\.functionName))

        XCTAssertTrue(functionNames.contains("team_status"))
        XCTAssertTrue(functionNames.contains("team_message_send"))
        XCTAssertTrue(functionNames.contains("team_task_create"))
        XCTAssertTrue(functionNames.contains("team_task_list"))
        XCTAssertTrue(functionNames.contains("team_task_get"))
        XCTAssertTrue(functionNames.contains("team_task_update"))
        XCTAssertTrue(functionNames.contains("team_plan_approve"))
        XCTAssertFalse(functionNames.contains("team_create"))
        XCTAssertFalse(functionNames.contains("Agent"))
    }

    func testPromptBuilderIncludesTeamGuidance() {
        let prompt = AgentPromptBuilder.composeSystemPrompt(
            baseSystemPrompt: nil,
            context: nil,
            skillCatalog: [],
            memoryContext: nil,
            rootDirectory: nil
        )

        XCTAssertTrue(prompt.contains("## Teams"))
        XCTAssertTrue(prompt.contains("preconfigured agent pools"))
        XCTAssertTrue(prompt.contains("team_message_send"))
        XCTAssertTrue(prompt.contains("team_plan_approve"))
        XCTAssertTrue(prompt.contains("topologies"))
        XCTAssertTrue(prompt.contains("pending approvals"))
    }
}
