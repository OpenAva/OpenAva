import ChatClient
import XCTest
@testable import OpenAva

final class TeamSwarmCapabilityTests: XCTestCase {
    func testTeamToolDefinitionsExposeCoreSwarmTools() {
        let definitions = TeamTools().toolDefinitions()
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

    @MainActor
    func testTeamMemberRuntimeUsesUnifiedToolset() async {
        let runtime = ToolRuntime.makeDefault(configureTeamSwarm: false)
        let provider = ToolRegistryProvider(toolRuntime: runtime, invocationSessionID: "team-member-test::main")

        let tools = await provider.enabledTools()
        let functionNames = Set(tools.compactMap(Self.functionName(from:)))

        XCTAssertTrue(functionNames.contains("team_task_update"))
        XCTAssertTrue(functionNames.contains("team_task_list"))
        XCTAssertTrue(functionNames.contains("team_message_send"))

        let found = await provider.findTool(for: ToolRequest(name: "team_task_update", arguments: "{}"))
        XCTAssertNotNil(found)
        XCTAssertEqual(found?.displayName, "team_task_update")
    }

    private static func functionName(from tool: ChatRequestBody.Tool) -> String? {
        switch tool {
        case let .function(name, _, _, _):
            name
        }
    }
}
