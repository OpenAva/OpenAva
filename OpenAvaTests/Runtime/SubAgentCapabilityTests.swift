import XCTest
@testable import OpenAva

final class SubAgentCapabilityTests: XCTestCase {
    func testSubAgentDefaultsAllowLongerExecutionBeforeTurnLimit() {
        XCTAssertEqual(SubAgentRegistry.generalPurpose.maxTurns, 16)
        XCTAssertEqual(SubAgentRegistry.explore.maxTurns, 12)
        XCTAssertEqual(SubAgentRegistry.plan.maxTurns, 12)
    }

    func testSubAgentToolDefinitionsExposeRunContinueStatusAndCancel() {
        let definitions = SubAgentTools().toolDefinitions()
        let functionNames = Set(definitions.map(\.functionName))

        XCTAssertEqual(functionNames, ["subagent_run", "subagent_continue", "subagent_status", "subagent_cancel"])
    }

    func testExploreSubAgentIsReadOnlyAndBlocksRecursiveLaunch() {
        let definition = SubAgentRegistry.explore

        XCTAssertTrue(definition.allowsTool(functionName: "fs_read"))
        XCTAssertTrue(definition.allowsTool(functionName: "web_search"))
        XCTAssertTrue(definition.allowsTool(functionName: "memory_recall"))
        XCTAssertFalse(definition.allowsTool(functionName: "fs_write"))
        XCTAssertFalse(definition.allowsTool(functionName: "javascript_execute"))
        XCTAssertFalse(definition.allowsTool(functionName: "memory_upsert"))
        XCTAssertFalse(definition.allowsTool(functionName: "subagent_run"))
        XCTAssertFalse(definition.allowsTool(functionName: "subagent_continue"))
    }

    func testPlanSubAgentDoesNotExposeJavaScriptExecute() {
        let definition = SubAgentRegistry.plan

        XCTAssertTrue(definition.allowsTool(functionName: "fs_read"))
        XCTAssertFalse(definition.allowsTool(functionName: "javascript_execute"))
    }

    func testPromptBuilderIncludesSubAgentGuidance() {
        let prompt = AgentPromptBuilder.composeSystemPrompt(
            baseSystemPrompt: nil,
            context: nil,
            skillCatalog: [],
            rootDirectory: nil
        )

        XCTAssertTrue(prompt.contains("## Sub Agents"))
        XCTAssertTrue(prompt.contains("subagent_run"))
        XCTAssertTrue(prompt.contains("subagent_continue"))
        XCTAssertTrue(prompt.contains("subagent_status"))
        XCTAssertTrue(prompt.contains("must not recursively spawn additional sub agents"))
    }

    func testSubAgentDefaultsDoNotDependOnReservedFinalTurnBehavior() {
        XCTAssertGreaterThan(SubAgentRegistry.generalPurpose.maxTurns, 1)
        XCTAssertGreaterThan(SubAgentRegistry.explore.maxTurns, 1)
    }
}
