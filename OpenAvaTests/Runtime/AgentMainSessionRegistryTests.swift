import Foundation
import XCTest
@testable import OpenAva

@MainActor
final class AgentMainSessionRegistryTests: XCTestCase {
    override func tearDown() {
        AgentMainSessionRegistry.shared.removeAll()
        ConversationSessionManager.shared.removeAllSessions()
        super.tearDown()
    }

    func testSessionResourcesUseInvocationSessionSuffixAsMainSessionID() throws {
        let agent = try AgentStore.createAgent(
            name: "Worker-\(UUID().uuidString)",
            emoji: "🧪",
            fileManager: .default
        )
        defer {
            AgentMainSessionRegistry.shared.removeAll()
            ConversationSessionManager.shared.removeAllSessions()
            TranscriptStorageProvider.removeProvider(runtimeRootURL: agent.runtimeURL)
            _ = AgentStore.deleteAgent(agent.id, fileManager: .default)
        }

        let resources = AgentMainSessionRegistry.shared.sessionResources(
            for: agent,
            modelConfig: makeModelConfig(),
            invocationSessionID: "\(agent.id.uuidString)::review-session",
            shouldExtractDurableMemory: false
        )

        XCTAssertEqual(resources.session.id, "review-session")
    }

    func testSessionResourcesCacheSeparatesDifferentMainSessionIDs() throws {
        let agent = try AgentStore.createAgent(
            name: "Worker-\(UUID().uuidString)",
            emoji: "🧪",
            fileManager: .default
        )
        defer {
            AgentMainSessionRegistry.shared.removeAll()
            ConversationSessionManager.shared.removeAllSessions()
            TranscriptStorageProvider.removeProvider(runtimeRootURL: agent.runtimeURL)
            _ = AgentStore.deleteAgent(agent.id, fileManager: .default)
        }

        let modelConfig = makeModelConfig()
        let firstResources = AgentMainSessionRegistry.shared.sessionResources(
            for: agent,
            modelConfig: modelConfig,
            invocationSessionID: "\(agent.id.uuidString)::main",
            shouldExtractDurableMemory: false
        )
        let secondResources = AgentMainSessionRegistry.shared.sessionResources(
            for: agent,
            modelConfig: modelConfig,
            invocationSessionID: "\(agent.id.uuidString)::team-review",
            shouldExtractDurableMemory: false
        )

        XCTAssertEqual(firstResources.session.id, "main")
        XCTAssertEqual(secondResources.session.id, "team-review")
        XCTAssertTrue(firstResources.session !== secondResources.session)
    }

    func testSubmitToMainSessionSerializesConcurrentOperations() async throws {
        let agent = try AgentStore.createAgent(
            name: "Worker-\(UUID().uuidString)",
            emoji: "🧪",
            fileManager: .default
        )
        defer {
            AgentMainSessionRegistry.shared.removeAll()
            ConversationSessionManager.shared.removeAllSessions()
            TranscriptStorageProvider.removeProvider(runtimeRootURL: agent.runtimeURL)
            _ = AgentStore.deleteAgent(agent.id, fileManager: .default)
        }

        let modelConfig = makeModelConfig()
        let recorder = EventRecorder()
        let invocationSessionID = "\(agent.id.uuidString)::main"

        let first = Task {
            try await AgentMainSessionRegistry.shared.submitToMainSession(
                for: agent,
                modelConfig: modelConfig,
                invocationSessionID: invocationSessionID,
                shouldExtractDurableMemory: false
            ) { _ in
                await recorder.record("first-start")
                try? await Task.sleep(nanoseconds: 100_000_000)
                await recorder.record("first-end")
                return "first"
            }
        }

        try? await Task.sleep(nanoseconds: 20_000_000)

        let second = Task {
            try await AgentMainSessionRegistry.shared.submitToMainSession(
                for: agent,
                modelConfig: modelConfig,
                invocationSessionID: invocationSessionID,
                shouldExtractDurableMemory: false
            ) { _ in
                await recorder.record("second-start")
                await recorder.record("second-end")
                return "second"
            }
        }

        let firstResult = try await first.value
        let secondResult = try await second.value
        let events = await recorder.snapshot()

        XCTAssertEqual(firstResult, "first")
        XCTAssertEqual(secondResult, "second")
        XCTAssertEqual(events, ["first-start", "first-end", "second-start", "second-end"])
    }

    private func makeModelConfig() -> AppConfig.LLMModel {
        AppConfig.LLMModel(
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
    }
}

private actor EventRecorder {
    private var events: [String] = []

    func record(_ event: String) {
        events.append(event)
    }

    func snapshot() -> [String] {
        events
    }
}
