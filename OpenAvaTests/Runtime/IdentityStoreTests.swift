import Foundation
import XCTest
@testable import OpenAva

final class IdentityStoreTests: XCTestCase {
    func testAgentStoreLoadReturnsCreatedAgentAsActive() throws {
        let suiteName = "IdentityStoreCompatTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let profile = try AgentStore.createAgent(
            name: "Nova",
            emoji: "🦊",
            defaults: defaults
        )
        defer { try? FileManager.default.removeItem(at: profile.workspaceURL) }

        let snapshot = AgentStore.load(defaults: defaults)
        XCTAssertEqual(snapshot.agents.count, 1)
        XCTAssertEqual(snapshot.activeAgent?.id, profile.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: profile.workspaceURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: profile.runtimeURL.path))
    }

    func testAgentStoreUpdateAgentChangesNameAndEmoji() throws {
        let suiteName = "IdentityStoreCompatTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let profile = try AgentStore.createAgent(
            name: "Atlas",
            emoji: "🤖",
            defaults: defaults
        )
        defer { try? FileManager.default.removeItem(at: profile.workspaceURL) }

        let updated = AgentStore.updateAgent(agentID: profile.id, name: "Luna", emoji: "🌙", defaults: defaults)
        XCTAssertEqual(updated?.name, "Luna")
        XCTAssertEqual(updated?.emoji, "🌙")

        let snapshot = AgentStore.load(defaults: defaults)
        XCTAssertEqual(snapshot.activeAgent?.name, "Luna")
        XCTAssertEqual(snapshot.activeAgent?.emoji, "🌙")
    }
}
