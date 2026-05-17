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
        XCTAssertEqual(profile.workspaceURL.path, workspaceRootURL.path)
        XCTAssertEqual(
            profile.contextURL.path,
            workspaceRootURL
                .appendingPathComponent(".openava", isDirectory: true)
                .appendingPathComponent("agents", isDirectory: true)
                .appendingPathComponent(profile.id, isDirectory: true)
                .path
        )
        XCTAssertTrue(fileManager.fileExists(atPath: profile.workspaceURL.path))
        XCTAssertTrue(fileManager.fileExists(atPath: profile.contextURL.path))
        XCTAssertTrue(fileManager.fileExists(atPath: profile.contextURL.path))
        let metadata = try XCTUnwrap(ChatContextMetadata.load(from: profile.contextURL))
        XCTAssertEqual(metadata.thinkingStrength, .medium)
        XCTAssertTrue(metadata.autoCompactEnabled)
        XCTAssertLessThanOrEqual(metadata.createdAt, Date())

        let projectURL = try XCTUnwrap(OpenAvaProjectFile.fileURL(workspaceRootURL: workspaceRootURL))
        let projectText = try String(contentsOf: projectURL, encoding: .utf8)
        XCTAssertTrue(projectText.contains(profile.id))
        XCTAssertTrue(projectText.contains("\"activeAgentID\""))
        XCTAssertFalse(projectText.contains("\"agents\""))
    }

    func testCreateAgentWritesDiceBearAvatarToIdentity() throws {
        let workspaceRootURL = makeTemporaryWorkspaceRoot()
        defer { try? FileManager.default.removeItem(at: workspaceRootURL) }

        let profile = try AgentStore.createAgent(
            name: "Nova",
            emoji: "🦊",
            avatarIdentityValue: AgentAvatarDefaults.identityValue(
                kind: .diceBear,
                seed: "nova-seed",
                name: "Nova",
                emoji: "🦊"
            ),
            workspaceRootURL: workspaceRootURL
        )

        let identityText = try String(
            contentsOf: profile.contextURL.appendingPathComponent("IDENTITY.md", isDirectory: false),
            encoding: .utf8
        )
        XCTAssertTrue(identityText.contains("- **Avatar:**"))
        XCTAssertTrue(identityText.contains("https://api.dicebear.com/9.x/notionists/png?seed=nova-seed"))

        let snapshot = AgentStore.load(workspaceRootURL: workspaceRootURL)
        XCTAssertEqual(snapshot.activeAgent?.avatarIdentityValue, "https://api.dicebear.com/9.x/notionists/png?seed=nova-seed")
        XCTAssertEqual(snapshot.activeAgent?.avatarDescriptor.kind, .diceBear)
        XCTAssertEqual(snapshot.activeAgent?.avatarDescriptor.diceBearSeed, "nova-seed")
    }

    func testCreateAgentWritesUploadedAvatarPathToIdentity() throws {
        let workspaceRootURL = makeTemporaryWorkspaceRoot()
        defer { try? FileManager.default.removeItem(at: workspaceRootURL) }

        let profile = try AgentStore.createAgent(
            name: "Nova",
            emoji: "🦊",
            avatarIdentityValue: AgentAvatarDefaults.uploadedAvatarIdentityValue,
            workspaceRootURL: workspaceRootURL
        )

        let identityText = try String(
            contentsOf: profile.contextURL.appendingPathComponent("IDENTITY.md", isDirectory: false),
            encoding: .utf8
        )
        XCTAssertTrue(identityText.contains("- **Avatar:**"))
        XCTAssertTrue(identityText.contains("  avatar.png"))

        let snapshot = AgentStore.load(workspaceRootURL: workspaceRootURL)
        XCTAssertEqual(snapshot.activeAgent?.avatarIdentityValue, "avatar.png")
        XCTAssertEqual(snapshot.activeAgent?.avatarDescriptor.kind, .uploaded)
    }

    func testSetSelectedModelPersistsForAgent() throws {
        let workspaceRootURL = makeTemporaryWorkspaceRoot()
        defer { try? FileManager.default.removeItem(at: workspaceRootURL) }

        let profile = try AgentStore.createAgent(
            name: "Atlas",
            emoji: "🤖",
            workspaceRootURL: workspaceRootURL
        )

        let modelID = OpenAvaID.generate(.model)
        XCTAssertTrue(AgentStore.setSelectedModel(modelID, for: profile.id, workspaceRootURL: workspaceRootURL))

        let snapshot = AgentStore.load(workspaceRootURL: workspaceRootURL)
        guard let active = snapshot.activeAgent else {
            XCTFail("Expected active agent")
            return
        }

        XCTAssertEqual(active.selectedModelID, modelID)
        let metadata = try XCTUnwrap(ChatContextMetadata.load(from: active.contextURL))
        XCTAssertEqual(metadata.selectedModelID, modelID)
    }

    func testUpdateAgentSyncsIdentityMetadataUsedByDiscovery() throws {
        let workspaceRootURL = makeTemporaryWorkspaceRoot()
        defer { try? FileManager.default.removeItem(at: workspaceRootURL) }

        let profile = try AgentStore.createAgent(
            name: "Atlas",
            emoji: "🤖",
            workspaceRootURL: workspaceRootURL
        )

        let updated = try XCTUnwrap(AgentStore.updateAgent(
            agentID: profile.id,
            name: "Nova",
            emoji: "🦊",
            workspaceRootURL: workspaceRootURL
        ))
        XCTAssertEqual(updated.name, "Nova")
        XCTAssertEqual(updated.emoji, "🦊")

        let snapshot = AgentStore.load(workspaceRootURL: workspaceRootURL)
        XCTAssertEqual(snapshot.activeAgent?.name, "Nova")
        XCTAssertEqual(snapshot.activeAgent?.emoji, "🦊")

        let identityText = try String(contentsOf: profile.contextURL.appendingPathComponent("IDENTITY.md", isDirectory: false), encoding: .utf8)
        XCTAssertTrue(identityText.contains("  Nova"))
        XCTAssertTrue(identityText.contains("  🦊"))
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
        _ = AgentStore.setSelectedModel(UUID().uuidString, for: profile.id, workspaceRootURL: workspaceRootURL)

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
        let contextURL = profile.contextURL
        let supportURL = profile.contextURL

        XCTAssertTrue(FileManager.default.fileExists(atPath: workspaceURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: contextURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: supportURL.path))
        XCTAssertTrue(AgentStore.deleteAgent(profile.id, workspaceRootURL: workspaceRootURL))

        let snapshot = AgentStore.load(workspaceRootURL: workspaceRootURL)
        XCTAssertEqual(snapshot.agents.count, 0)
        XCTAssertNil(snapshot.activeAgent)
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspaceURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: contextURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: supportURL.path))
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

    func testRenameAgentUpdatesNameWithoutMovingSharedWorkspace() throws {
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
        XCTAssertEqual(renamed.workspaceURL.path, profile.workspaceURL.path)
        XCTAssertEqual(renamed.contextURL.path, profile.contextURL.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: renamed.workspaceURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: renamed.contextURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: renamed.contextURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: markerURL.path))
    }

    func testRenameAgentKeepsAvatarInAgentContextDirectory() throws {
        let workspaceRootURL = makeTemporaryWorkspaceRoot()
        defer { try? FileManager.default.removeItem(at: workspaceRootURL) }

        let profile = try AgentStore.createAgent(
            name: "Atlas",
            emoji: "🤖",
            workspaceRootURL: workspaceRootURL
        )
        let avatarData = try XCTUnwrap(
            Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a5EYAAAAASUVORK5CYII=")
        )
        try avatarData.write(to: profile.avatarURL, options: [.atomic])

        guard let renamed = AgentStore.renameAgent(
            agentID: profile.id,
            name: "Nova",
            workspaceRootURL: workspaceRootURL
        ) else {
            XCTFail("Expected rename to succeed")
            return
        }

        XCTAssertEqual(renamed.avatarURL.path, profile.avatarURL.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: renamed.avatarURL.path))
    }

    func testLoadRepairsMissingActiveAgentByFallingBackToFirstAgent() throws {
        let workspaceRootURL = makeTemporaryWorkspaceRoot()
        defer { try? FileManager.default.removeItem(at: workspaceRootURL) }

        let first = try AgentStore.createAgent(
            name: "Nova",
            emoji: "🦊",
            workspaceRootURL: workspaceRootURL
        )
        _ = try AgentStore.createAgent(
            name: "Atlas",
            emoji: "🤖",
            workspaceRootURL: workspaceRootURL
        )

        let staleProjectPayload = """
        {
          "activeAgentID" : "\(OpenAvaID.generate(.agent))"
        }
        """
        let projectURL = try XCTUnwrap(OpenAvaProjectFile.fileURL(workspaceRootURL: workspaceRootURL))
        try staleProjectPayload.write(
            to: projectURL,
            atomically: true,
            encoding: .utf8
        )

        let snapshot = AgentStore.load(workspaceRootURL: workspaceRootURL)
        XCTAssertEqual(snapshot.activeAgent?.id, first.id)
    }

    func testLoadDiscoversAgentsFromIdentityFiles() throws {
        let workspaceRootURL = makeTemporaryWorkspaceRoot()
        defer { try? FileManager.default.removeItem(at: workspaceRootURL) }

        let agentID = OpenAvaID.generate(.agent)
        let agentDirectoryURL = AgentStore.agentContextDirectory(for: agentID, workspaceRootURL: workspaceRootURL)
        try AgentTemplateWriter.writeAgentFile(
            at: agentDirectoryURL,
            name: "Copied Agent",
            emoji: "🧬",
            avatar: "https://api.dicebear.com/9.x/notionists/png?seed=copied"
        )

        let snapshot = AgentStore.load(workspaceRootURL: workspaceRootURL)

        XCTAssertEqual(snapshot.agents.count, 1)
        XCTAssertEqual(snapshot.activeAgentID, agentID)
        XCTAssertEqual(snapshot.activeAgent?.name, "Copied Agent")
        XCTAssertEqual(snapshot.activeAgent?.emoji, "🧬")
        XCTAssertEqual(snapshot.activeAgent?.avatarIdentityValue, "https://api.dicebear.com/9.x/notionists/png?seed=copied")
        XCTAssertEqual(snapshot.activeAgent?.avatarDescriptor.kind, .diceBear)
        XCTAssertEqual(snapshot.activeAgent?.avatarDescriptor.diceBearSeed, "copied")
        XCTAssertEqual(
            snapshot.activeAgent?.contextURL.path,
            agentDirectoryURL.path
        )

        let projectURL = try XCTUnwrap(OpenAvaProjectFile.fileURL(workspaceRootURL: workspaceRootURL))
        let projectText = try String(contentsOf: projectURL, encoding: .utf8)
        XCTAssertTrue(projectText.contains(agentID))
        XCTAssertFalse(projectText.contains("\"agents\""))
    }

    func testLoadDiscoversAgentWhenIdentityEmojiIsMissing() throws {
        let workspaceRootURL = makeTemporaryWorkspaceRoot()
        defer { try? FileManager.default.removeItem(at: workspaceRootURL) }

        let profile = try AgentStore.createAgent(
            name: "Atlas",
            emoji: "🤖",
            workspaceRootURL: workspaceRootURL
        )
        let identityText = """
        # IDENTITY.md - Who Am I?

        Name: Atlas
        Vibe: Useful
        """
        try identityText.write(
            to: profile.contextURL.appendingPathComponent("IDENTITY.md", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )

        let snapshot = AgentStore.load(workspaceRootURL: workspaceRootURL)

        XCTAssertEqual(snapshot.agents.count, 1)
        XCTAssertEqual(snapshot.activeAgent?.name, "Atlas")
        XCTAssertEqual(snapshot.activeAgent?.emoji, "🤖")
    }

    func testLoadSkipsAgentWhenIdentityNameIsMissing() throws {
        let workspaceRootURL = makeTemporaryWorkspaceRoot()
        defer { try? FileManager.default.removeItem(at: workspaceRootURL) }

        let profile = try AgentStore.createAgent(
            name: "Atlas",
            emoji: "🤖",
            workspaceRootURL: workspaceRootURL
        )
        let identityText = """
        # IDENTITY.md - Who Am I?

        Emoji: 🦊
        Vibe: Useful
        """
        try identityText.write(
            to: profile.contextURL.appendingPathComponent("IDENTITY.md", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )

        let snapshot = AgentStore.load(workspaceRootURL: workspaceRootURL)

        XCTAssertTrue(snapshot.agents.isEmpty)
        XCTAssertNil(snapshot.activeAgentID)
    }

    private func makeTemporaryWorkspaceRoot() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
