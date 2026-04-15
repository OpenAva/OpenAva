import Foundation
import XCTest
@testable import OpenAva

final class IdentityStoreTests: XCTestCase {
    func testAgentStoreLoadReturnsCreatedAgentAsActive() throws {
        let workspaceRootURL = makeTemporaryWorkspaceRoot()
        defer { try? FileManager.default.removeItem(at: workspaceRootURL) }

        let profile = try AgentStore.createAgent(
            name: "Nova",
            emoji: "🦊",
            workspaceRootURL: workspaceRootURL
        )

        let snapshot = AgentStore.load(workspaceRootURL: workspaceRootURL)
        XCTAssertEqual(snapshot.agents.count, 1)
        XCTAssertEqual(snapshot.activeAgent?.id, profile.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: profile.workspaceURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: profile.runtimeURL.path))
    }

    func testAgentStoreUpdateAgentChangesNameAndEmoji() throws {
        let workspaceRootURL = makeTemporaryWorkspaceRoot()
        defer { try? FileManager.default.removeItem(at: workspaceRootURL) }

        let profile = try AgentStore.createAgent(
            name: "Atlas",
            emoji: "🤖",
            workspaceRootURL: workspaceRootURL
        )

        let updated = AgentStore.updateAgent(
            agentID: profile.id,
            name: "Luna",
            emoji: "🌙",
            workspaceRootURL: workspaceRootURL
        )
        XCTAssertEqual(updated?.name, "Luna")
        XCTAssertEqual(updated?.emoji, "🌙")

        let snapshot = AgentStore.load(workspaceRootURL: workspaceRootURL)
        XCTAssertEqual(snapshot.activeAgent?.name, "Luna")
        XCTAssertEqual(snapshot.activeAgent?.emoji, "🌙")
    }

    private func makeTemporaryWorkspaceRoot() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
