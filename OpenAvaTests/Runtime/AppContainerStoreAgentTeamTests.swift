import Foundation
import XCTest
@testable import OpenAva

@MainActor
final class AppContainerStoreAgentTeamTests: XCTestCase {
    private var originalProjectData: Data?

    override func setUp() {
        super.setUp()
        originalProjectData = try? Data(contentsOf: projectFileURL())
        removeProjectFile()
    }

    override func tearDown() {
        restoreProjectFile()
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
                id: "nova",
                title: "探索者",
                subtitle: "信息检索",
                agentName: "探索者",
                agentEmoji: "🔭",
                agentVibe: "专业",
                soulCoreTruths: "聚焦探索"
            ),
            AgentPreset(
                id: "jett",
                title: "执行者",
                subtitle: "任务执行",
                agentName: "执行者",
                agentEmoji: "⚡️",
                agentVibe: "直接",
                soulCoreTruths: "推动落实"
            ),
        ]

        let beforeAgents = AgentStore.load(fileManager: fileManager, workspaceRootURL: workspaceRootURL).agents.map(\.id)

        let profiles = try containerStore.createAgents(
            from: presets,
            callName: "Yuan",
            context: "Building OpenAva"
        )

        XCTAssertEqual(profiles.count, 2)
        XCTAssertEqual(profiles.map(\.name), ["探索者", "执行者"])

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
            XCTAssertTrue(soulContent.contains("聚焦探索") || soulContent.contains("推动落实"))
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
        XCTAssertEqual(containerStore.teams.first?.description, "Main coordination team")
        XCTAssertTrue(team.members.isEmpty)

        let metadata = try XCTUnwrap(TeamStore.loadMetadata(for: .team(team.id), workspaceRootURL: workspaceRootURL))
        XCTAssertEqual(metadata.members, [])
        XCTAssertEqual(metadata.defaultTopology, .automatic)
        let teamDirectoryURL = try XCTUnwrap(
            TeamStore.contextDirectoryURL(for: .team(team.id), workspaceRootURL: workspaceRootURL)
        )
        let identityURL = teamDirectoryURL.appendingPathComponent("IDENTITY.md", isDirectory: false)
        let identityText = try String(contentsOf: identityURL, encoding: .utf8)
        XCTAssertTrue(identityText.contains("  Core Team"))
        XCTAssertTrue(identityText.contains("  🧭"))
        XCTAssertTrue(identityText.contains("  Main coordination team"))

        let agent = try containerStore.createAgent(name: "Operator", emoji: "🛠️")
        let updatedTeam = try XCTUnwrap(containerStore.addAgents([agent.id], toTeam: team.id))
        XCTAssertEqual(updatedTeam.members, [agent.id])
    }

    func testCreateAgentDefaultsToFirstConfiguredModel() throws {
        let workspaceRootURL = makeTemporaryWorkspaceRoot()
        defer { try? FileManager.default.removeItem(at: workspaceRootURL) }

        let suiteName = "AppContainerStoreAgentTeamTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let unavailableModelID = OpenAvaID.generate(.model)
        let availableModelID = OpenAvaID.generate(.model)
        let config = AppConfig(
            session: .init(defaultSessionKey: "main"),
            llmCollection: .init(models: [
                .init(
                    id: unavailableModelID,
                    name: "Missing API Key",
                    endpoint: URL(string: "https://example.invalid/v1"),
                    apiKey: nil,
                    apiKeyHeader: "Authorization",
                    model: "missing-key",
                    provider: LLMProvider.custom.rawValue,
                    systemPrompt: nil,
                    contextTokens: 128_000,
                    requestTimeoutMs: 60000
                ),
                .init(
                    id: availableModelID,
                    name: "Configured",
                    endpoint: URL(string: "https://example.invalid/v1"),
                    apiKey: "test-key",
                    apiKeyHeader: "Authorization",
                    model: "configured-model",
                    provider: LLMProvider.custom.rawValue,
                    systemPrompt: nil,
                    contextTokens: 128_000,
                    requestTimeoutMs: 60000
                ),
            ]),
            agent: .init(
                id: nil,
                name: "Agent",
                emoji: "🤖",
                selectedModelID: nil,
                thinkingStrength: .medium,
                workspaceRootURL: nil,
                supportRootURL: nil
            )
        )
        let containerStore = AppContainerStore(
            container: .make(config: config),
            defaults: defaults,
            fileManager: .default,
            agentWorkspaceRootURL: workspaceRootURL
        )

        let agent = try containerStore.createAgent(name: "Operator", emoji: "🛠️")

        let metadata = try XCTUnwrap(ChatContextMetadata.load(from: agent.contextURL))
        XCTAssertEqual(metadata.selectedModelID, availableModelID)
        XCTAssertNotEqual(metadata.selectedModelID, unavailableModelID)
    }

    func testRenameActiveTeamUpdatesIdentityDocumentAndReloadedProfile() throws {
        let workspaceRootURL = makeTemporaryWorkspaceRoot()
        defer { try? FileManager.default.removeItem(at: workspaceRootURL) }

        let suiteName = "AppContainerStoreAgentTeamTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let containerStore = AppContainerStore(
            container: .makeDefault(),
            defaults: defaults,
            fileManager: .default,
            agentWorkspaceRootURL: workspaceRootURL
        )
        let team = try XCTUnwrap(containerStore.createTeam(name: "Core Team", emoji: "🧭", description: "Main coordination team"))

        XCTAssertTrue(containerStore.setActiveSessionContext(.team(team.id)))
        XCTAssertTrue(containerStore.renameActiveTeam(to: "Planning Room"))

        let reloaded = try XCTUnwrap(TeamStore.team(id: team.id, workspaceRootURL: workspaceRootURL))
        XCTAssertEqual(reloaded.name, "Planning Room")
        XCTAssertEqual(reloaded.emoji, "🧭")
        XCTAssertEqual(reloaded.description, "Main coordination team")

        let teamDirectoryURL = try XCTUnwrap(
            TeamStore.contextDirectoryURL(for: .team(team.id), workspaceRootURL: workspaceRootURL)
        )
        let identityText = try String(
            contentsOf: teamDirectoryURL.appendingPathComponent("IDENTITY.md", isDirectory: false),
            encoding: .utf8
        )
        XCTAssertTrue(identityText.contains("  Planning Room"))
        XCTAssertFalse(identityText.contains("  Core Team"))
    }

    func testAllAgentsTeamHasIdentityDocumentAndCanBeRenamed() throws {
        let workspaceRootURL = makeTemporaryWorkspaceRoot()
        defer { try? FileManager.default.removeItem(at: workspaceRootURL) }

        let suiteName = "AppContainerStoreAgentTeamTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let containerStore = AppContainerStore(
            container: .makeDefault(),
            defaults: defaults,
            fileManager: .default,
            agentWorkspaceRootURL: workspaceRootURL
        )

        let initialTeam = try XCTUnwrap(containerStore.allAgentsTeam)
        XCTAssertEqual(initialTeam.id, TeamStore.allAgentsTeamID)
        XCTAssertEqual(initialTeam.name, L10n.tr("chat.menu.allAgentsTeam"))

        XCTAssertTrue(containerStore.renameActiveTeam(to: "Everyone Room"))

        let renamedTeam = try XCTUnwrap(containerStore.allAgentsTeam)
        XCTAssertEqual(renamedTeam.name, "Everyone Room")
        XCTAssertEqual(renamedTeam.emoji, "👥")

        let teamDirectoryURL = try XCTUnwrap(
            TeamStore.contextDirectoryURL(for: .allAgentsTeam, workspaceRootURL: workspaceRootURL)
        )
        let identityText = try String(
            contentsOf: teamDirectoryURL.appendingPathComponent("IDENTITY.md", isDirectory: false),
            encoding: .utf8
        )
        XCTAssertTrue(identityText.contains("  Everyone Room"))
        XCTAssertTrue(identityText.contains("  👥"))
    }

    func testTeamDescriptionAndTopologyPersistToMetadataNotProjectState() throws {
        let workspaceRootURL = makeTemporaryWorkspaceRoot()
        defer { try? FileManager.default.removeItem(at: workspaceRootURL) }

        let suiteName = "AppContainerStoreAgentTeamTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let containerStore = AppContainerStore(
            container: .makeDefault(),
            defaults: defaults,
            fileManager: .default,
            agentWorkspaceRootURL: workspaceRootURL
        )

        let team = try XCTUnwrap(containerStore.createTeam(
            name: "Research Team",
            emoji: "🔎",
            description: "Find evidence before recommending.",
            defaultTopology: .tree
        ))

        let metadata = try XCTUnwrap(TeamStore.loadMetadata(for: .team(team.id), workspaceRootURL: workspaceRootURL))
        XCTAssertEqual(metadata.members, [])
        XCTAssertEqual(metadata.defaultTopology, .tree)
        XCTAssertEqual(containerStore.teams.first?.description, "Find evidence before recommending.")
        XCTAssertEqual(containerStore.teams.first?.defaultTopology, .tree)
        XCTAssertTrue(containerStore.teams.first?.identityDocument?.contains("Research Team") == true)

        let projectURL = try XCTUnwrap(OpenAvaProjectFile.fileURL(workspaceRootURL: workspaceRootURL))
        let projectData = try Data(contentsOf: projectURL)
        let projectObject = try XCTUnwrap(JSONSerialization.jsonObject(with: projectData) as? [String: Any])
        let teams = try XCTUnwrap(projectObject["teams"] as? [[String: Any]])
        let storedTeam = try XCTUnwrap(teams.first)
        XCTAssertEqual(storedTeam["id"] as? String, team.id)
        XCTAssertNil(storedTeam["name"])
        XCTAssertNil(storedTeam["emoji"])
        XCTAssertNil(storedTeam["members"])
        XCTAssertNil(storedTeam["description"])
        XCTAssertNil(storedTeam["defaultTopology"])
        XCTAssertNil(storedTeam["createdAt"])
        XCTAssertNil(storedTeam["updatedAt"])
    }

    func testChatSessionMenuIncludesCustomTeamAndSelection() {
        let teamID = UUID().uuidString
        let team = TeamProfile(
            id: teamID,
            name: "Core Team",
            emoji: "🧭",
            members: []
        )

        let entries = ChatTopBar.sessionMenuEntries(
            teams: [team],
            agents: [],
            activeContext: .team(teamID)
        )

        XCTAssertGreaterThanOrEqual(entries.count, 2)
        XCTAssertEqual(entries[0].kind, .allAgentsTeam)
        XCTAssertEqual(entries[1].kind, .team(teamID))
        XCTAssertEqual(entries[1].displayTitle, "🧭 Core Team")
        XCTAssertTrue(entries[1].isSelected)
        XCTAssertFalse(entries[0].isSelected)
    }

    func testTeamChatConfigurationMenuHidesAgentManagementActions() {
        let teamSections = ChatTopBar.configurationSections(
            autoCompactEnabled: true,
            isBackgroundEnabled: false,
            includeBackgroundExecution: true,
            includeAgentManagement: false,
            includeTeamRename: true
        )
        let teamItemIDs = Set(teamSections.flatMap(\.items).map(\.id))

        XCTAssertTrue(teamItemIDs.contains("background-execution"))
        XCTAssertTrue(teamItemIDs.contains("open-cron"))
        XCTAssertTrue(teamItemIDs.contains("open-remote-control"))
        XCTAssertTrue(teamItemIDs.contains("rename-agent"))
        XCTAssertFalse(teamItemIDs.contains("auto-compact"))
        XCTAssertFalse(teamItemIDs.contains("delete-agent"))

        let agentSections = ChatTopBar.configurationSections(
            autoCompactEnabled: true,
            isBackgroundEnabled: false,
            includeBackgroundExecution: true,
            includeAgentManagement: true
        )
        let agentItemIDs = Set(agentSections.flatMap(\.items).map(\.id))

        XCTAssertTrue(agentItemIDs.contains("auto-compact"))
        XCTAssertTrue(agentItemIDs.contains("rename-agent"))
        XCTAssertTrue(agentItemIDs.contains("delete-agent"))
    }

    func testContainerStoreCanActivateCustomTeamContext() throws {
        let workspaceRootURL = makeTemporaryWorkspaceRoot()
        defer { try? FileManager.default.removeItem(at: workspaceRootURL) }

        let suiteName = "AppContainerStoreAgentTeamTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let containerStore = AppContainerStore(
            container: .makeDefault(),
            defaults: defaults,
            fileManager: .default,
            agentWorkspaceRootURL: workspaceRootURL
        )

        let team = try XCTUnwrap(containerStore.createTeam(name: "Core Team", emoji: "🧭"))

        XCTAssertTrue(containerStore.setActiveSessionContext(.team(team.id)))
        XCTAssertEqual(containerStore.activeSessionContext, .team(team.id))
    }

    func testAllAgentsTeamPersistsModelPreferencesToMetadata() throws {
        let workspaceRootURL = makeTemporaryWorkspaceRoot()
        defer { try? FileManager.default.removeItem(at: workspaceRootURL) }

        let suiteName = "AppContainerStoreAgentTeamTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let containerStore = AppContainerStore(
            container: .makeDefault(),
            defaults: defaults,
            fileManager: .default,
            agentWorkspaceRootURL: workspaceRootURL
        )
        let modelID = OpenAvaID.generate(.model)

        XCTAssertEqual(containerStore.activeSessionContext, .allAgentsTeam)
        containerStore.selectLLMModel(id: modelID)
        containerStore.selectThinkingStrength(.high)

        let metadata = try XCTUnwrap(TeamStore.loadMetadata(for: .allAgentsTeam, workspaceRootURL: workspaceRootURL))
        XCTAssertEqual(metadata.selectedModelID, modelID)
        XCTAssertEqual(metadata.thinkingStrength, .high)
        XCTAssertTrue(metadata.autoCompactEnabled)
        XCTAssertLessThanOrEqual(metadata.createdAt, Date())

        let metadataURL = workspaceRootURL
            .appendingPathComponent(".openava", isDirectory: true)
            .appendingPathComponent("teams", isDirectory: true)
            .appendingPathComponent(TeamStore.allAgentsTeamID, isDirectory: true)
            .appendingPathComponent("metadata.json", isDirectory: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: metadataURL.path))
    }

    func testSwitchingFromAgentBackToAllAgentsTeamClearsAgentScopedWorkspaceConfig() throws {
        let workspaceRootURL = makeTemporaryWorkspaceRoot()
        defer { try? FileManager.default.removeItem(at: workspaceRootURL) }

        let suiteName = "AppContainerStoreAgentTeamTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let containerStore = AppContainerStore(
            container: .makeDefault(),
            defaults: defaults,
            fileManager: .default,
            agentWorkspaceRootURL: workspaceRootURL
        )
        let agent = try containerStore.createAgent(name: "Operator", emoji: "🛠️")

        _ = containerStore.setActiveSessionContext(.agent(agent.id))
        XCTAssertEqual(containerStore.container.config.agent.id, agent.id)
        XCTAssertEqual(
            containerStore.container.config.agent.workspaceRootURL?.standardizedFileURL,
            agent.workspaceURL.standardizedFileURL
        )
        XCTAssertEqual(
            containerStore.container.config.agent.supportRootURL?.standardizedFileURL,
            agent.contextURL.standardizedFileURL
        )

        XCTAssertTrue(containerStore.setActiveSessionContext(.allAgentsTeam))
        XCTAssertEqual(containerStore.activeSessionContext, .allAgentsTeam)
        XCTAssertNil(containerStore.container.config.agent.id)
        XCTAssertEqual(
            containerStore.container.config.agent.workspaceRootURL?.standardizedFileURL,
            workspaceRootURL.standardizedFileURL
        )
        XCTAssertEqual(
            containerStore.container.config.agent.supportRootURL?.standardizedFileURL,
            workspaceRootURL
                .appendingPathComponent(".openava", isDirectory: true)
                .standardizedFileURL
        )
        let teamSupportURL = containerStore.teamSessionsRootURL
        XCTAssertEqual(
            teamSupportURL?.standardizedFileURL,
            workspaceRootURL
                .appendingPathComponent(".openava", isDirectory: true)
                .appendingPathComponent("teams", isDirectory: true)
                .appendingPathComponent(TeamStore.allAgentsTeamID, isDirectory: true)
                .standardizedFileURL
        )
        XCTAssertNotEqual(
            teamSupportURL?.standardizedFileURL,
            agent.contextURL.standardizedFileURL
        )
    }

    private func removeProjectFile() {
        try? FileManager.default.removeItem(at: projectFileURL())
    }

    private func restoreProjectFile() {
        let url = projectFileURL()
        if let originalProjectData {
            try? originalProjectData.write(to: url, options: [.atomic])
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func projectFileURL() -> URL {
        let rootURL = try? AgentStore.workspaceRootDirectory(fileManager: .default)
        if let rootURL, let fileURL = OpenAvaProjectFile.fileURL(workspaceRootURL: rootURL) {
            return fileURL
        }
        let fallbackRootURL = FileManager.default.temporaryDirectory.appendingPathComponent("OpenAva", isDirectory: true)
        return AgentStore.supportDirectoryURL(workspaceRootURL: fallbackRootURL)
            .appendingPathComponent("project.json", isDirectory: false)
    }

    private func makeTemporaryWorkspaceRoot() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
