import Foundation
import XCTest
@testable import OpenAva

@MainActor
final class HeartbeatRuntimeRegistryTests: XCTestCase {
    func testSyncRegistersUpdatesAndRemovesRuntimesByAgentID() {
        var runtimes: [String: MockHeartbeatRuntime] = [:]
        let registry = HeartbeatRuntimeRegistry { agentID in
            let runtime = MockHeartbeatRuntime(agentID: agentID)
            runtimes[agentID] = runtime
            return runtime
        }

        registry.sync(
            configurations: [makeConfiguration(agentID: "agent-a"), makeConfiguration(agentID: "agent-b")],
            schedulingEnabled: true
        )

        XCTAssertEqual(Set(registry.registeredAgentIDs), ["agent-a", "agent-b"])
        XCTAssertEqual(runtimes["agent-a"]?.applyCallCount, 1)
        XCTAssertEqual(runtimes["agent-a"]?.lastSchedulingEnabled, true)
        XCTAssertEqual(runtimes["agent-b"]?.applyCallCount, 1)

        registry.sync(
            configurations: [makeConfiguration(agentID: "agent-b")],
            schedulingEnabled: false
        )

        XCTAssertEqual(registry.registeredAgentIDs, ["agent-b"])
        XCTAssertTrue(runtimes["agent-a"]?.didStop == true)
        XCTAssertEqual(runtimes["agent-b"]?.applyCallCount, 2)
        XCTAssertEqual(runtimes["agent-b"]?.lastSchedulingEnabled, false)
    }

    func testRequestRunNowRoutesToMatchingRuntime() async {
        var runtimes: [String: MockHeartbeatRuntime] = [:]
        let registry = HeartbeatRuntimeRegistry { agentID in
            let runtime = MockHeartbeatRuntime(agentID: agentID)
            runtime.requestRunNowResult = agentID == "agent-a"
            runtimes[agentID] = runtime
            return runtime
        }
        registry.sync(configurations: [makeConfiguration(agentID: "agent-a")], schedulingEnabled: true)

        let matched = await registry.requestRunNow(for: "agent-a")
        let missing = await registry.requestRunNow(for: "missing")

        XCTAssertTrue(matched)
        XCTAssertFalse(missing)
        XCTAssertEqual(runtimes["agent-a"]?.requestRunNowCallCount, 1)
    }

    func testProcessPendingCronTriggersRoutesToMatchingRuntime() async {
        var runtimes: [String: MockHeartbeatRuntime] = [:]
        let registry = HeartbeatRuntimeRegistry { agentID in
            let runtime = MockHeartbeatRuntime(agentID: agentID)
            runtimes[agentID] = runtime
            return runtime
        }
        registry.sync(configurations: [makeConfiguration(agentID: "agent-a")], schedulingEnabled: true)

        let matched = await registry.processPendingCronTriggers(for: "agent-a")
        let missing = await registry.processPendingCronTriggers(for: "missing")

        XCTAssertTrue(matched)
        XCTAssertFalse(missing)
        XCTAssertEqual(runtimes["agent-a"]?.processPendingCronTriggersCallCount, 1)
    }

    private func makeConfiguration(agentID: String) -> HeartbeatRuntimeConfiguration {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let profile = AgentProfile(
            id: UUID(),
            name: agentID,
            emoji: "🫀",
            workspacePath: root.appendingPathComponent("workspace", isDirectory: true).path,
            localContextPath: root.path,
            selectedModelID: nil,
            autoCompactEnabled: true
        )
        return HeartbeatRuntimeConfiguration(
            agent: profile,
            agentID: agentID,
            mainSessionID: "main",
            agentName: profile.name,
            agentEmoji: profile.emoji,
            workspaceRootURL: profile.workspaceURL,
            supportRootURL: profile.contextURL,
            modelConfig: AppConfig.LLMModel(
                name: "Test Model",
                endpoint: URL(string: "https://example.com/v1"),
                apiKey: nil,
                apiKeyHeader: "Authorization",
                model: "test-model",
                provider: "openai-compatible",
                systemPrompt: nil,
                contextTokens: 128_000,
                requestTimeoutMs: 30000
            )
        )
    }
}

@MainActor
private final class MockHeartbeatRuntime: HeartbeatRuntimeControlling {
    let agentID: String
    var applyCallCount = 0
    var lastSchedulingEnabled: Bool?
    var didStop = false
    var requestRunNowResult = false
    var requestRunNowCallCount = 0
    var processPendingCronTriggersCallCount = 0

    init(agentID: String) {
        self.agentID = agentID
    }

    func apply(configuration _: HeartbeatRuntimeConfiguration, schedulingEnabled: Bool) {
        applyCallCount += 1
        lastSchedulingEnabled = schedulingEnabled
    }

    func stop() {
        didStop = true
    }

    func requestRunNow() async -> Bool {
        requestRunNowCallCount += 1
        return requestRunNowResult
    }

    func processPendingCronTriggers() async {
        processPendingCronTriggersCallCount += 1
    }
}
