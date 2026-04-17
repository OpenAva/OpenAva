import Foundation
import XCTest
@testable import OpenAva

final class AgentStoreTests: XCTestCase {
    func testCreateAgentSetsActiveAndCreatesDirectories() throws {
        let fileManager = FileManager.default
        let workspaceRootURL = makeTemporaryWorkspaceRoot()
        defer { try? fileManager.removeItem(at: workspaceRootURL) }

        let profile = try AgentStore.createAgent(
            name: "Nova",
            emoji: "🦊",
            fileManager: fileManager,
            workspaceRootURL: workspaceRootURL
        )

        let snapshot = AgentStore.load(fileManager: fileManager, workspaceRootURL: workspaceRootURL)
        XCTAssertEqual(snapshot.agents.count, 1)
        XCTAssertEqual(snapshot.activeAgent?.id, profile.id)
        XCTAssertEqual(profile.workspaceURL.path, workspaceRootURL.appendingPathComponent(profile.name, isDirectory: true).path)
        XCTAssertEqual(profile.runtimeURL.path, profile.workspaceURL.appendingPathComponent(".runtime", isDirectory: true).path)
        XCTAssertTrue(fileManager.fileExists(atPath: profile.workspaceURL.path))
        XCTAssertTrue(fileManager.fileExists(atPath: profile.runtimeURL.path))

        let stateText = try String(contentsOf: workspaceRootURL.appendingPathComponent(".openava.json", isDirectory: false), encoding: .utf8)
        XCTAssertTrue(stateText.contains(profile.id.uuidString))
        XCTAssertTrue(stateText.contains("\"activeAgentID\""))
    }

    func testSetSelectedModelPersistsForAgent() throws {
        let workspaceRootURL = makeTemporaryWorkspaceRoot()
        defer { try? FileManager.default.removeItem(at: workspaceRootURL) }

        let profile = try AgentStore.createAgent(
            name: "Atlas",
            emoji: "🤖",
            workspaceRootURL: workspaceRootURL
        )

        let modelID = UUID()
        XCTAssertTrue(AgentStore.setSelectedModel(modelID, for: profile.id, workspaceRootURL: workspaceRootURL))

        let snapshot = AgentStore.load(workspaceRootURL: workspaceRootURL)
        guard let active = snapshot.activeAgent else {
            XCTFail("Expected active agent")
            return
        }

        XCTAssertEqual(active.selectedModelID, modelID)
    }

    func testAgentMutationsPreserveUserDefaults() throws {
        let workspaceRootURL = makeTemporaryWorkspaceRoot()
        defer { try? FileManager.default.removeItem(at: workspaceRootURL) }

        AgentStore.saveUser(
            callName: "Yuan",
            context: "简洁、直接、可执行",
            workspaceRootURL: workspaceRootURL
        )

        let profile = try AgentStore.createAgent(
            name: "Atlas",
            emoji: "🤖",
            workspaceRootURL: workspaceRootURL
        )
        _ = AgentStore.setSelectedModel(UUID(), for: profile.id, workspaceRootURL: workspaceRootURL)

        let user = AgentStore.loadUser(workspaceRootURL: workspaceRootURL)
        XCTAssertEqual(user?.callName, "Yuan")
        XCTAssertEqual(user?.context, "简洁、直接、可执行")
    }

    func testDeleteAgentRemovesProfileAndDirectory() throws {
        let workspaceRootURL = makeTemporaryWorkspaceRoot()
        defer { try? FileManager.default.removeItem(at: workspaceRootURL) }

        let profile = try AgentStore.createAgent(
            name: "Nova",
            emoji: "🦊",
            workspaceRootURL: workspaceRootURL
        )
        let workspaceURL = profile.workspaceURL

        XCTAssertTrue(FileManager.default.fileExists(atPath: workspaceURL.path))
        XCTAssertTrue(AgentStore.deleteAgent(profile.id, workspaceRootURL: workspaceRootURL))

        let snapshot = AgentStore.load(workspaceRootURL: workspaceRootURL)
        XCTAssertEqual(snapshot.agents.count, 0)
        XCTAssertNil(snapshot.activeAgent)
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspaceURL.path))
    }

    func testDeleteActiveAgentFallsBackToRemainingAgent() throws {
        let workspaceRootURL = makeTemporaryWorkspaceRoot()
        defer { try? FileManager.default.removeItem(at: workspaceRootURL) }

        let first = try AgentStore.createAgent(
            name: "Atlas",
            emoji: "🤖",
            workspaceRootURL: workspaceRootURL
        )
        let second = try AgentStore.createAgent(
            name: "Luna",
            emoji: "🌙",
            workspaceRootURL: workspaceRootURL
        )

        XCTAssertTrue(AgentStore.setActiveAgent(second.id, workspaceRootURL: workspaceRootURL))
        XCTAssertTrue(AgentStore.deleteAgent(second.id, workspaceRootURL: workspaceRootURL))

        let snapshot = AgentStore.load(workspaceRootURL: workspaceRootURL)
        XCTAssertEqual(snapshot.agents.map(\.id), [first.id])
        XCTAssertEqual(snapshot.activeAgent?.id, first.id)
    }

    func testDeleteLastAgentClearsActiveAgentID() throws {
        let workspaceRootURL = makeTemporaryWorkspaceRoot()
        defer { try? FileManager.default.removeItem(at: workspaceRootURL) }

        let profile = try AgentStore.createAgent(
            name: "Solo",
            emoji: "🧭",
            workspaceRootURL: workspaceRootURL
        )

        XCTAssertTrue(AgentStore.deleteAgent(profile.id, workspaceRootURL: workspaceRootURL))

        let snapshot = AgentStore.load(workspaceRootURL: workspaceRootURL)
        XCTAssertTrue(snapshot.agents.isEmpty)
        XCTAssertNil(snapshot.activeAgentID)
    }

    func testRenameAgentMovesWorkspaceAndUpdatesRuntimePath() throws {
        let workspaceRootURL = makeTemporaryWorkspaceRoot()
        defer { try? FileManager.default.removeItem(at: workspaceRootURL) }

        let profile = try AgentStore.createAgent(
            name: "Atlas",
            emoji: "🤖",
            workspaceRootURL: workspaceRootURL
        )

        let markerURL = profile.workspaceURL.appendingPathComponent("marker.txt", isDirectory: false)
        try "ok".write(to: markerURL, atomically: true, encoding: .utf8)

        guard let renamed = AgentStore.renameAgent(
            agentID: profile.id,
            name: "Nova",
            workspaceRootURL: workspaceRootURL
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

    func testLoadRepairsMissingActiveAgentByFallingBackToFirstAgent() throws {
        let workspaceRootURL = makeTemporaryWorkspaceRoot()
        defer { try? FileManager.default.removeItem(at: workspaceRootURL) }

        let firstWorkspaceURL = workspaceRootURL.appendingPathComponent("Nova", isDirectory: true)
        let secondWorkspaceURL = workspaceRootURL.appendingPathComponent("Atlas", isDirectory: true)

        let first = AgentProfile(
            id: UUID(),
            name: "Nova",
            emoji: "🦊",
            workspacePath: firstWorkspaceURL.path,
            localRuntimePath: firstWorkspaceURL.appendingPathComponent(".runtime", isDirectory: true).path
        )
        let second = AgentProfile(
            id: UUID(),
            name: "Atlas",
            emoji: "🤖",
            workspacePath: secondWorkspaceURL.path,
            localRuntimePath: secondWorkspaceURL.appendingPathComponent(".runtime", isDirectory: true).path
        )
        try FileManager.default.createDirectory(at: first.workspaceURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second.workspaceURL, withIntermediateDirectories: true)

        let stalePayload = """
        {
          "activeAgentID" : "\(UUID().uuidString)",
          "agents" : [
            {
              "autoCompactEnabled" : true,
              "createdAtMs" : \(first.createdAtMs),
              "emoji" : "\(first.emoji)",
              "id" : "\(first.id.uuidString)",
              "localRuntimePath" : "\(first.localRuntimePath)",
              "name" : "\(first.name)",
              "selectedModelID" : null,
              "workspacePath" : "\(first.workspacePath)"
            },
            {
              "autoCompactEnabled" : true,
              "createdAtMs" : \(second.createdAtMs),
              "emoji" : "\(second.emoji)",
              "id" : "\(second.id.uuidString)",
              "localRuntimePath" : "\(second.localRuntimePath)",
              "name" : "\(second.name)",
              "selectedModelID" : null,
              "workspacePath" : "\(second.workspacePath)"
            }
          ]
        }
        """
        try stalePayload.write(
            to: workspaceRootURL.appendingPathComponent(".openava.json", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )

        let snapshot = AgentStore.load(workspaceRootURL: workspaceRootURL)
        XCTAssertEqual(snapshot.activeAgent?.id, first.id)
    }

    private func makeTemporaryWorkspaceRoot() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
