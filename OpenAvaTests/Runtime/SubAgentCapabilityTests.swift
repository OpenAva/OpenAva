import XCTest
@testable import OpenAva

final class SubAgentCapabilityTests: XCTestCase {
    func testSubAgentToolDefinitionsExposeRunStatusAndCancel() {
        let definitions = SubAgentToolDefinitions().toolDefinitions()
        let functionNames = Set(definitions.map(\.functionName))

        XCTAssertEqual(functionNames, ["subagent_run", "subagent_status", "subagent_cancel"])
    }

    func testExploreSubAgentIsReadOnlyAndBlocksRecursiveLaunch() {
        let definition = SubAgentRegistry.explore

        XCTAssertTrue(definition.allowsTool(functionName: "fs_read"))
        XCTAssertTrue(definition.allowsTool(functionName: "web_search"))
        XCTAssertFalse(definition.allowsTool(functionName: "fs_write"))
        XCTAssertFalse(definition.allowsTool(functionName: "memory_write_long_term"))
        XCTAssertFalse(definition.allowsTool(functionName: "subagent_run"))
    }

    func testPromptBuilderIncludesSubAgentGuidance() {
        let prompt = AgentPromptBuilder.composeSystemPrompt(
            baseSystemPrompt: nil,
            context: nil,
            skillCatalog: [],
            memoryContext: nil,
            rootDirectory: nil
        )

        XCTAssertTrue(prompt.contains("## Sub Agents"))
        XCTAssertTrue(prompt.contains("subagent_run"))
        XCTAssertTrue(prompt.contains("subagent_status"))
        XCTAssertTrue(prompt.contains("must not recursively spawn additional sub agents"))
    }
}
