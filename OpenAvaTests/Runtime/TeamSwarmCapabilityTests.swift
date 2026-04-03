import XCTest
@testable import OpenAva

final class TeamSwarmCapabilityTests: XCTestCase {
    func testTeamToolDefinitionsExposeCoreSwarmTools() {
        let definitions = TeamToolDefinitions().toolDefinitions()
        let functionNames = Set(definitions.map(\.functionName))

        XCTAssertTrue(functionNames.contains("TeamCreate"))
        XCTAssertTrue(functionNames.contains("Agent"))
        XCTAssertTrue(functionNames.contains("SendMessage"))
        XCTAssertTrue(functionNames.contains("TaskCreate"))
        XCTAssertTrue(functionNames.contains("TaskList"))
        XCTAssertTrue(functionNames.contains("TaskGet"))
        XCTAssertTrue(functionNames.contains("TaskUpdate"))
        XCTAssertTrue(functionNames.contains("TeamApprovePlan"))
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
        XCTAssertTrue(prompt.contains("TeamCreate"))
        XCTAssertTrue(prompt.contains("SendMessage"))
        XCTAssertTrue(prompt.contains("TeamApprovePlan"))
    }
}
