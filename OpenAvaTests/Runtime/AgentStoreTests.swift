import Foundation
import XCTest
@testable import OpenAva

final class AgentStoreTests: XCTestCase {
    func testCreateAgentSetsActiveAndCreatesDirectories() throws {
        let suiteName = "AgentStoreTests.\(UUID().uuidString)"
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
        #if targetEnvironment(macCatalyst)
            let expectedWorkspaceRoot = try XCTUnwrap(FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first)
                .appendingPathComponent("OpenAva", isDirectory: true)
        #else
            let expectedWorkspaceRoot = try XCTUnwrap(FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first)
        #endif
        XCTAssertEqual(profile.workspaceURL.path, expectedWorkspaceRoot.appendingPathComponent(profile.name, isDirectory: true).path)
        XCTAssertEqual(profile.runtimeURL.path, profile.workspaceURL.appendingPathComponent(".runtime", isDirectory: true).path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: profile.workspaceURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: profile.runtimeURL.path))
    }

    func testSetSelectedModelPersistsForAgent() throws {
        let suiteName = "AgentStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let profile = try AgentStore.createAgent(
            name: "Atlas",
            emoji: "🤖",
            defaults: defaults
        )
        defer { try? FileManager.default.removeItem(at: profile.workspaceURL) }

        let modelID = UUID()
        XCTAssertTrue(AgentStore.setSelectedModel(modelID, for: profile.id, defaults: defaults))

        let snapshot = AgentStore.load(defaults: defaults)
        guard let active = snapshot.activeAgent else {
            XCTFail("Expected active agent")
            return
        }

        XCTAssertEqual(active.selectedModelID, modelID)
    }

    func testDeleteAgentRemovesProfileAndDirectory() throws {
        let suiteName = "AgentStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let profile = try AgentStore.createAgent(
            name: "Nova",
            emoji: "🦊",
            defaults: defaults
        )
        let workspaceURL = profile.workspaceURL

        XCTAssertTrue(FileManager.default.fileExists(atPath: workspaceURL.path))
        XCTAssertTrue(AgentStore.deleteAgent(profile.id, defaults: defaults))

        let snapshot = AgentStore.load(defaults: defaults)
        XCTAssertEqual(snapshot.agents.count, 0)
        XCTAssertNil(snapshot.activeAgent)
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspaceURL.path))
    }

    func testDeleteActiveAgentFallsBackToRemainingAgent() throws {
        let suiteName = "AgentStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = try AgentStore.createAgent(
            name: "Atlas",
            emoji: "🤖",
            defaults: defaults
        )
        let second = try AgentStore.createAgent(
            name: "Luna",
            emoji: "🌙",
            defaults: defaults
        )
        defer {
            try? FileManager.default.removeItem(at: first.workspaceURL)
            try? FileManager.default.removeItem(at: second.workspaceURL)
        }

        XCTAssertTrue(AgentStore.setActiveAgent(second.id, defaults: defaults))
        XCTAssertTrue(AgentStore.deleteAgent(second.id, defaults: defaults))

        let snapshot = AgentStore.load(defaults: defaults)
        XCTAssertEqual(snapshot.agents.map(\.id), [first.id])
        XCTAssertEqual(snapshot.activeAgent?.id, first.id)
    }

    func testDeleteLastAgentClearsActiveAgentID() throws {
        let suiteName = "AgentStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let profile = try AgentStore.createAgent(
            name: "Solo",
            emoji: "🧭",
            defaults: defaults
        )

        XCTAssertTrue(AgentStore.deleteAgent(profile.id, defaults: defaults))

        let snapshot = AgentStore.load(defaults: defaults)
        XCTAssertTrue(snapshot.agents.isEmpty)
        XCTAssertNil(snapshot.activeAgentID)
    }

    func testRenameAgentMovesWorkspaceAndUpdatesRuntimePath() throws {
        let suiteName = "AgentStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let profile = try AgentStore.createAgent(
            name: "Atlas",
            emoji: "🤖",
            defaults: defaults
        )
        defer { try? FileManager.default.removeItem(at: profile.workspaceURL) }

        let markerURL = profile.workspaceURL.appendingPathComponent("marker.txt", isDirectory: false)
        try "ok".write(to: markerURL, atomically: true, encoding: .utf8)

        guard let renamed = AgentStore.renameAgent(
            agentID: profile.id,
            name: "Nova",
            defaults: defaults
        ) else {
            XCTFail("Expected rename to succeed")
            return
        }

        XCTAssertEqual(renamed.name, "Nova")
        XCTAssertFalse(FileManager.default.fileExists(atPath: profile.workspaceURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: renamed.workspaceURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: renamed.runtimeURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: renamed.workspaceURL.appendingPathComponent("marker.txt").path))
    }

    func testLoadUsesPlatformSpecificWorkspacePathBehavior() throws {
        let suiteName = "AgentStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let profile = try AgentStore.createAgent(
            name: "Nova",
            emoji: "🦊",
            defaults: defaults
        )
        defer { try? FileManager.default.removeItem(at: profile.workspaceURL) }

        let stalePayload: [String: Any] = [
            "version": 1,
            "agents": [[
                "id": profile.id.uuidString,
                "name": profile.name,
                "emoji": profile.emoji,
                "workspacePath": "/private/var/mobile/Containers/Data/Application/OLD/workspace",
                "localRuntimePath": "/private/var/mobile/Containers/Data/Application/OLD/runtime",
                "selectedModelID": NSNull(),
                "createdAtMs": profile.createdAtMs,
            ]],
            "activeAgentID": profile.id.uuidString,
        ]

        let staleData = try JSONSerialization.data(withJSONObject: stalePayload)
        defaults.set(staleData, forKey: "agent.state.v1")

        let snapshot = AgentStore.load(defaults: defaults)
        guard let loaded = snapshot.activeAgent else {
            XCTFail("Expected active agent")
            return
        }

        #if targetEnvironment(macCatalyst)
            XCTAssertEqual(loaded.workspaceURL.path, "/private/var/mobile/Containers/Data/Application/OLD/workspace")
            XCTAssertEqual(loaded.runtimeURL.path, "/private/var/mobile/Containers/Data/Application/OLD/runtime")
            XCTAssertFalse(FileManager.default.fileExists(atPath: loaded.workspaceURL.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: loaded.runtimeURL.path))
        #else
            let expectedWorkspaceRoot = try XCTUnwrap(FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first)
            let expectedWorkspaceURL = expectedWorkspaceRoot.appendingPathComponent(profile.name, isDirectory: true)
            XCTAssertEqual(loaded.workspaceURL.path, expectedWorkspaceURL.path)
            XCTAssertEqual(loaded.runtimeURL.path, expectedWorkspaceURL.appendingPathComponent(".runtime", isDirectory: true).path)
            XCTAssertTrue(FileManager.default.fileExists(atPath: loaded.workspaceURL.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: loaded.runtimeURL.path))
        #endif
    }
}
