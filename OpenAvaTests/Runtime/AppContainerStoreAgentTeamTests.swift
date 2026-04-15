import Foundation
import XCTest
@testable import OpenAva

@MainActor
final class AppContainerStoreAgentTeamTests: XCTestCase {
    override func setUp() {
        super.setUp()
        removeTeamStoreFile()
    }

    override func tearDown() {
        removeTeamStoreFile()
        super.tearDown()
    }

    func testCreateAgentsFromPresetsCreatesProfilesAndFiles() throws {
        let fileManager = FileManager.default
        let workspaceRootURL = makeTemporaryWorkspaceRoot()
        defer { try? fileManager.removeItem(at: workspaceRootURL) }

        let suiteName = "AppContainerStoreAgentTeamTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let containerStore = AppContainerStore(
            container: .makeDefault(),
            defaults: defaults,
            fileManager: fileManager,
            agentWorkspaceRootURL: workspaceRootURL
        )

        let presets = [
            AgentPreset(
                id: "marketing",
                title: "增长营销",
                subtitle: "增长",
                agentName: "增长营销",
                agentEmoji: "📣",
                agentVibe: "犀利",
                soulCoreTruths: "聚焦增长"
            ),
            AgentPreset(
                id: "sales",
                title: "销售顾问",
                subtitle: "销售",
                agentName: "销售顾问",
                agentEmoji: "🤝",
                agentVibe: "直接",
                soulCoreTruths: "推动成交"
            ),
        ]

        let beforeAgents = AgentStore.load(fileManager: fileManager, workspaceRootURL: workspaceRootURL).agents.map(\.id)

        let profiles = try containerStore.createAgents(
            from: presets,
            callName: "Yuan",
            context: "Building OpenAva"
        )

        XCTAssertEqual(profiles.count, 2)
        XCTAssertEqual(profiles.map(\.name), ["增长营销", "销售顾问"])

        let snapshot = AgentStore.load(fileManager: fileManager, workspaceRootURL: workspaceRootURL)
        let newProfiles = snapshot.agents.filter { !beforeAgents.contains($0.id) }
        XCTAssertEqual(newProfiles.count, 2)
        XCTAssertEqual(snapshot.activeAgent?.id, profiles.first?.id)

        for profile in profiles {
            let userURL = profile.workspaceURL.appendingPathComponent(AgentContextDocumentKind.user.fileName, isDirectory: false)
            let soulURL = profile.workspaceURL.appendingPathComponent(AgentContextDocumentKind.soul.fileName, isDirectory: false)
            let identityURL = profile.workspaceURL.appendingPathComponent(AgentContextDocumentKind.identity.fileName, isDirectory: false)

            XCTAssertTrue(fileManager.fileExists(atPath: userURL.path))
            XCTAssertTrue(fileManager.fileExists(atPath: soulURL.path))
            XCTAssertTrue(fileManager.fileExists(atPath: identityURL.path))

            let identityContent = try String(contentsOf: identityURL, encoding: .utf8)
            let userContent = try String(contentsOf: userURL, encoding: .utf8)
            let soulContent = try String(contentsOf: soulURL, encoding: .utf8)

            XCTAssertTrue(identityContent.contains(profile.name))
            XCTAssertTrue(userContent.contains("Yuan"))
            XCTAssertTrue(soulContent.contains("聚焦增长") || soulContent.contains("推动成交"))
        }

        for profile in newProfiles {
            _ = AgentStore.deleteAgent(profile.id, fileManager: fileManager, workspaceRootURL: workspaceRootURL)
        }
    }

    func testCreateTeamAndAddAgentToExistingTeam() throws {
        let workspaceRootURL = makeTemporaryWorkspaceRoot()
        defer { try? FileManager.default.removeItem(at: workspaceRootURL) }

        let suiteName = "AppContainerStoreAgentTeamTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let fileManager = FileManager.default
        let containerStore = AppContainerStore(
            container: .makeDefault(),
            defaults: defaults,
            fileManager: fileManager,
            agentWorkspaceRootURL: workspaceRootURL
        )

        let team = try XCTUnwrap(containerStore.createTeam(name: "Core Team", emoji: "🧭", description: "Main coordination team"))
        XCTAssertEqual(containerStore.teams.map(\.name), ["Core Team"])
        XCTAssertEqual(containerStore.teams.map(\.emoji), ["🧭"])
        XCTAssertTrue(team.agentPoolIDs.isEmpty)

        let agent = try containerStore.createAgent(name: "Operator", emoji: "🛠️")
        let updatedTeam = try XCTUnwrap(containerStore.addAgents([agent.id], toTeam: team.id))
        XCTAssertEqual(updatedTeam.agentPoolIDs, [agent.id])
    }

    private func removeTeamStoreFile() {
        guard let rootURL = TeamStore.storageDirectoryURL(fileManager: .default) else { return }
        try? FileManager.default.removeItem(at: rootURL.appendingPathComponent("teams.json", isDirectory: false))
    }

    private func makeTemporaryWorkspaceRoot() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
