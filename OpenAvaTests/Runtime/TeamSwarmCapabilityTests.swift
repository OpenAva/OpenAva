import ChatClient
import XCTest
@testable import OpenAva

final class TeamSwarmCapabilityTests: XCTestCase {
    @MainActor
    override func setUp() async throws {
        try await super.setUp()
        await ToolRegistry.shared.clear()
    }

    @MainActor
    override func tearDown() async throws {
        await ToolRegistry.shared.clear()
        TeamSwarmCoordinator.shared.configure(agentStoreRootURL: nil)
        TeamSwarmCoordinator.shared.reload()
        try await super.tearDown()
    }

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

    func testPromptBuilderDoesNotIncludeTeamGuidanceForSingleAgent() {
        let prompt = AgentPromptBuilder.composeSystemPrompt(
            baseSystemPrompt: nil,
            context: nil,
            skillCatalog: [],
            rootDirectory: nil,
            agentCount: 1
        )

        XCTAssertFalse(prompt.contains("## Teams"))
        XCTAssertFalse(prompt.contains("team_message_send"))
        XCTAssertFalse(prompt.contains("team_plan_approve"))
    }

    func testPromptBuilderIncludesTeamGuidanceForMultiAgent() {
        let prompt = AgentPromptBuilder.composeSystemPrompt(
            baseSystemPrompt: nil,
            context: nil,
            skillCatalog: [],
            rootDirectory: nil,
            agentCount: 3
        )

        XCTAssertTrue(prompt.contains("## Teams"))
        XCTAssertTrue(prompt.contains("team_message_send"))
        XCTAssertTrue(prompt.contains("team_task_update"))
        XCTAssertTrue(prompt.contains("team_plan_approve"))
    }

    @MainActor
    func testSingleAgentRuntimeDoesNotExposeTeamTools() async {
        let runtime = ToolRuntime.makeDefault(configureTeamSwarm: false, agentCount: 1)
        let provider = ToolRegistryProvider(toolRuntime: runtime, invocationSessionID: "team-member-test::main")

        let tools = await provider.enabledTools()
        let functionNames = Set(tools.compactMap(Self.functionName(from:)))

        XCTAssertFalse(functionNames.contains("team_task_update"))
        XCTAssertFalse(functionNames.contains("team_task_list"))
        XCTAssertFalse(functionNames.contains("team_message_send"))

        let found = await provider.findTool(for: ToolRequest(name: "team_task_update", arguments: "{}"))
        XCTAssertNil(found)
    }

    @MainActor
    func testMultiAgentRuntimeExposesTeamTools() async {
        let runtime = ToolRuntime.makeDefault(configureTeamSwarm: false, agentCount: 3)
        let provider = ToolRegistryProvider(toolRuntime: runtime, invocationSessionID: "team-member-test-enabled::main")

        let tools = await provider.enabledTools()
        let functionNames = Set(tools.compactMap(Self.functionName(from:)))

        XCTAssertTrue(functionNames.contains("team_task_update"))
        XCTAssertTrue(functionNames.contains("team_task_list"))
        XCTAssertTrue(functionNames.contains("team_message_send"))

        let found = await provider.findTool(for: ToolRequest(name: "team_task_update", arguments: "{}"))
        XCTAssertNotNil(found)
        XCTAssertEqual(found?.displayName, "team_task_update")
    }

    @MainActor
    func testImplicitTeamDoesNotMaterializeForSingleAgentWorkspace() throws {
        let workspaceRootURL = makeTemporaryWorkspaceRoot()
        defer { try? FileManager.default.removeItem(at: workspaceRootURL) }

        let agent = try AgentStore.createAgent(
            name: "Solo-\(UUID().uuidString)",
            emoji: "🧪",
            fileManager: .default,
            workspaceRootURL: workspaceRootURL
        )
        defer {
            _ = AgentStore.deleteAgent(agent.id, fileManager: .default, workspaceRootURL: workspaceRootURL)
        }

        let coordinator = TeamSwarmCoordinator.shared
        coordinator.configure(agentStoreRootURL: workspaceRootURL)
        coordinator.reload()

        let snapshot = coordinator.snapshot(context: .init(sessionID: "\(agent.id.uuidString)::main"))

        XCTAssertNil(snapshot)
    }

    @MainActor
    func testImplicitTeamMaterializesForMultiAgentWorkspace() throws {
        let workspaceRootURL = makeTemporaryWorkspaceRoot()
        defer { try? FileManager.default.removeItem(at: workspaceRootURL) }

        let first = try AgentStore.createAgent(
            name: "WorkerA-\(UUID().uuidString)",
            emoji: "🧪",
            fileManager: .default,
            workspaceRootURL: workspaceRootURL
        )
        let second = try AgentStore.createAgent(
            name: "WorkerB-\(UUID().uuidString)",
            emoji: "🧪",
            fileManager: .default,
            workspaceRootURL: workspaceRootURL
        )
        defer {
            _ = AgentStore.deleteAgent(first.id, fileManager: .default, workspaceRootURL: workspaceRootURL)
            _ = AgentStore.deleteAgent(second.id, fileManager: .default, workspaceRootURL: workspaceRootURL)
        }

        let coordinator = TeamSwarmCoordinator.shared
        coordinator.configure(agentStoreRootURL: workspaceRootURL)
        coordinator.reload()

        let snapshot = try XCTUnwrap(coordinator.snapshot(context: .init(sessionID: "\(first.id.uuidString)::main")))

        XCTAssertEqual(Set(snapshot.team.members.map(\.id)), Set([first.id.uuidString, second.id.uuidString]))
    }

    private static func functionName(from tool: ChatRequestBody.Tool) -> String? {
        switch tool {
        case let .function(name, _, _, _):
            name
        }
    }

    @MainActor
    private func makeTemporaryWorkspaceRoot() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
