import Foundation
import XCTest
@testable import OpenAva

@MainActor
final class AgentCreationViewModelPresetTests: XCTestCase {
    private var testDirectoryURL: URL!

    override func setUp() {
        super.setUp()
        testDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentCreationViewModelPresetTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: testDirectoryURL, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let testDirectoryURL {
            try? FileManager.default.removeItem(at: testDirectoryURL)
        }
        testDirectoryURL = nil
        super.tearDown()
    }

    func testApplyPresetFillsCreationFieldsAndSelection() {
        let preset = AgentPreset(
            id: "jett",
            title: "Jett",
            subtitle: "Execute tasks",
            agentName: "Jett",
            agentEmoji: "⚡️",
            agentVibe: "Direct",
            soulCoreTruths: "Reason step by step\nOffer actionable suggestions"
        )

        let viewModel = AgentCreationViewModel(presets: [preset], userDirectoryURL: testDirectoryURL)
        viewModel.applyPreset(preset, avoiding: [])

        XCTAssertEqual(viewModel.selectedPresetID, "jett")
        XCTAssertEqual(viewModel.data.agentName, "Jett")
        XCTAssertEqual(viewModel.data.agentEmoji, "⚡️")
        XCTAssertEqual(viewModel.data.agentVibe, "Direct")
        XCTAssertEqual(viewModel.data.soulCoreTruths, "Reason step by step\nOffer actionable suggestions")
        XCTAssertEqual(viewModel.data.agentAvatarKind, .diceBear)
        XCTAssertEqual(viewModel.data.agentAvatarSeed, "jett")
    }

    func testDefaultAvatarUsesDiceBearNotionistsURL() {
        let viewModel = AgentCreationViewModel(presets: [], userDirectoryURL: testDirectoryURL)
        viewModel.data.agentName = "Nova Explorer"

        XCTAssertEqual(
            viewModel.agentAvatarDescriptor.diceBearURL.absoluteString,
            "https://api.dicebear.com/9.x/notionists/png?seed=Nova%20Explorer"
        )
    }

    func testSelectingEmojiSwitchesAvatarKindToEmoji() {
        let viewModel = AgentCreationViewModel(presets: [], userDirectoryURL: testDirectoryURL)

        viewModel.setAgentEmoji("🦊")

        XCTAssertEqual(viewModel.data.agentAvatarKind, .emoji)
        XCTAssertEqual(viewModel.agentAvatarDescriptor.displayEmoji, "🦊")
    }

    func testApplyPresetWithoutEmojiFallsBackToRandomEmoji() {
        let preset = AgentPreset(
            id: "support",
            title: "Support Specialist",
            subtitle: "General support",
            agentName: "Support Specialist",
            agentEmoji: "   ",
            agentVibe: "Warm",
            soulCoreTruths: "Be genuinely helpful"
        )

        let viewModel = AgentCreationViewModel(presets: [preset], userDirectoryURL: testDirectoryURL)
        viewModel.applyPreset(preset, avoiding: [])

        XCTAssertFalse(viewModel.data.agentEmoji.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertTrue(viewModel.emojiCandidates.contains(viewModel.data.agentEmoji))
    }

    func testRandomizeAgentNameUsesBuiltInEnglishNamePool() {
        let viewModel = AgentCreationViewModel(presets: [], userDirectoryURL: testDirectoryURL)
        viewModel.data.agentName = "Custom"

        viewModel.randomizeAgentName(avoiding: [])

        XCTAssertTrue(viewModel.agentNameCandidates.contains(viewModel.data.agentName))
    }

    func testApplyAgentDefaultsUsesRandomNameInsteadOfOwnerBasedDefault() {
        let viewModel = AgentCreationViewModel(presets: [], userDirectoryURL: testDirectoryURL)
        viewModel.data.userCallName = "Yuan"

        viewModel.applyAgentDefaultsIfNeeded(avoiding: [], usedAgentNames: [])

        XCTAssertTrue(viewModel.agentNameCandidates.contains(viewModel.data.agentName))
        XCTAssertNotEqual(
            viewModel.data.agentName,
            L10n.tr("agent.creation.defaultNameWithOwner", "Yuan")
        )
    }

    func testRandomizeAgentNameAvoidsExistingAgentNames() throws {
        let viewModel = AgentCreationViewModel(presets: [], userDirectoryURL: testDirectoryURL)
        let expected = try XCTUnwrap(viewModel.agentNameCandidates.last)
        let usedNames = Set(
            viewModel.agentNameCandidates.dropLast().enumerated().map { index, name in
                index == 0 ? "  \(name.uppercased())  " : name
            }
        )

        viewModel.randomizeAgentName(avoiding: usedNames)

        XCTAssertEqual(viewModel.data.agentName, expected)
    }

    func testRandomizeAgentNameFallsBackToUniqueDefaultNameWhenPoolIsExhausted() {
        let viewModel = AgentCreationViewModel(presets: [], userDirectoryURL: testDirectoryURL)

        let usedNames = Set(viewModel.agentNameCandidates).union([
            L10n.tr("agent.creation.defaultName"),
        ])

        viewModel.randomizeAgentName(avoiding: usedNames)

        XCTAssertEqual(
            viewModel.data.agentName,
            "\(L10n.tr("agent.creation.defaultName")) 2"
        )
    }

    func testCanCompleteDependsOnUserAndAgentIdentity() {
        let viewModel = AgentCreationViewModel(presets: [], userDirectoryURL: testDirectoryURL)

        XCTAssertFalse(viewModel.canComplete)

        viewModel.data.userCallName = "Yuan"
        XCTAssertFalse(viewModel.canComplete)

        viewModel.applyAgentDefaultsIfNeeded(avoiding: [], usedAgentNames: [])
        XCTAssertTrue(viewModel.canComplete)

        viewModel.data.agentName = "   "
        XCTAssertFalse(viewModel.canComplete)

        viewModel.data.agentName = "Operator"
        viewModel.data.agentEmoji = "   "
        XCTAssertFalse(viewModel.canComplete)
    }

    func testCreateAgentPersistsUploadedAvatarInWorkspace() async throws {
        let workspaceRootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentCreationAvatarTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceRootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspaceRootURL) }

        let suiteName = "AgentCreationAvatarTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let containerStore = AppContainerStore(
            container: .makeDefault(),
            defaults: defaults,
            fileManager: .default,
            agentWorkspaceRootURL: workspaceRootURL
        )

        let viewModel = AgentCreationViewModel(presets: [], userDirectoryURL: testDirectoryURL)
        viewModel.data.userCallName = "Yuan"
        viewModel.data.agentName = "Nova"
        viewModel.data.agentEmoji = "🦊"
        let avatarData = try XCTUnwrap(
            Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a5EYAAAAASUVORK5CYII=")
        )
        XCTAssertTrue(viewModel.setAgentAvatarData(avatarData))

        try await viewModel.createAgent(containerStore: containerStore)

        let createdProfile = try XCTUnwrap(containerStore.activeAgent)
        XCTAssertTrue(FileManager.default.fileExists(atPath: createdProfile.avatarURL.path))
        XCTAssertEqual(createdProfile.avatarURL.lastPathComponent, "avatar.png")
        XCTAssertEqual(createdProfile.avatarKind, .uploaded)

        let identityText = try String(
            contentsOf: createdProfile.contextURL.appendingPathComponent("IDENTITY.md", isDirectory: false),
            encoding: .utf8
        )
        XCTAssertTrue(identityText.contains("- **Avatar:**"))
        XCTAssertTrue(identityText.contains("  avatar.png"))
    }

    func testCreateAgentPersistsDiceBearAvatarURLToIdentity() async throws {
        let workspaceRootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentCreationDiceBearAvatarTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceRootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspaceRootURL) }

        let suiteName = "AgentCreationDiceBearAvatarTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let containerStore = AppContainerStore(
            container: .makeDefault(),
            defaults: defaults,
            fileManager: .default,
            agentWorkspaceRootURL: workspaceRootURL
        )

        let viewModel = AgentCreationViewModel(presets: [], userDirectoryURL: testDirectoryURL)
        viewModel.data.userCallName = "Yuan"
        viewModel.data.agentName = "Nova"
        viewModel.data.agentEmoji = "🦊"
        viewModel.data.agentAvatarKind = .diceBear
        viewModel.data.agentAvatarSeed = "nova-seed"

        try await viewModel.createAgent(containerStore: containerStore)

        let createdProfile = try XCTUnwrap(containerStore.activeAgent)
        XCTAssertEqual(createdProfile.avatarKind, .diceBear)
        XCTAssertEqual(createdProfile.avatarSeed, "nova-seed")

        let identityText = try String(
            contentsOf: createdProfile.contextURL.appendingPathComponent("IDENTITY.md", isDirectory: false),
            encoding: .utf8
        )
        XCTAssertTrue(identityText.contains("- **Avatar:**"))
        XCTAssertTrue(identityText.contains("  https://api.dicebear.com/9.x/notionists/png?seed=nova-seed"))
    }

    func testCreateAgentDoesNotCreateWorkspaceAgentsFile() async throws {
        let workspaceRootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentCreationWorkspaceAgentsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceRootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspaceRootURL) }

        let suiteName = "AgentCreationWorkspaceAgentsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let containerStore = AppContainerStore(
            container: .makeDefault(),
            defaults: defaults,
            fileManager: .default,
            agentWorkspaceRootURL: workspaceRootURL
        )

        let viewModel = AgentCreationViewModel(presets: [], userDirectoryURL: testDirectoryURL)
        viewModel.data.userCallName = "Yuan"
        viewModel.data.agentName = "Nova"
        viewModel.data.agentEmoji = "🦊"

        try await viewModel.createAgent(containerStore: containerStore)

        let agentsURL = workspaceRootURL.appendingPathComponent("AGENTS.md", isDirectory: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: agentsURL.path))
    }
}
