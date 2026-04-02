import Foundation
import XCTest
@testable import OpenAva

@MainActor
final class AgentCreationViewModelPresetTests: XCTestCase {
    func testApplyPresetFillsCreationFieldsAndSelection() throws {
        let suiteName = "LocalAgentCreationViewModelPresetTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preset = AgentPreset(
            id: "engineering",
            title: "Engineering Lead",
            subtitle: "Build features faster",
            agentName: "Engineering Lead",
            agentEmoji: "💻",
            agentVibe: "Direct",
            soulCoreTruths: "Reason step by step\nOffer actionable suggestions"
        )

        let viewModel = AgentCreationViewModel(defaults: defaults, presets: [preset])
        viewModel.applyPreset(preset, avoiding: [])

        XCTAssertEqual(viewModel.selectedPresetID, "engineering")
        XCTAssertEqual(viewModel.data.agentName, "Engineering Lead")
        XCTAssertEqual(viewModel.data.agentEmoji, "💻")
        XCTAssertEqual(viewModel.data.agentVibe, "Direct")
        XCTAssertEqual(viewModel.data.soulCoreTruths, "Reason step by step\nOffer actionable suggestions")
    }

    func testApplyPresetWithoutEmojiFallsBackToRandomEmoji() throws {
        let suiteName = "LocalAgentCreationViewModelPresetTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preset = AgentPreset(
            id: "support",
            title: "Support Specialist",
            subtitle: "General support",
            agentName: "Support Specialist",
            agentEmoji: "   ",
            agentVibe: "Warm",
            soulCoreTruths: "Be genuinely helpful"
        )

        let viewModel = AgentCreationViewModel(defaults: defaults, presets: [preset])
        viewModel.applyPreset(preset, avoiding: [])

        XCTAssertFalse(viewModel.data.agentEmoji.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertTrue(viewModel.emojiCandidates.contains(viewModel.data.agentEmoji))
    }

    func testDefaultTeamPresetsUseCatalogOrder() throws {
        let suiteName = "LocalAgentCreationViewModelPresetTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let viewModel = AgentCreationViewModel(defaults: defaults, presets: AgentPresetCatalog.builtInPresets())

        XCTAssertEqual(viewModel.defaultTeamPresets.map(\.id), AgentPresetCatalog.defaultTeamPresetIDs)
        XCTAssertTrue(viewModel.canCreateDefaultTeam == false)
    }

    func testToggleDefaultTeamPresetUpdatesSelectedTeam() throws {
        let suiteName = "LocalAgentCreationViewModelPresetTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let presets = AgentPresetCatalog.builtInPresets()
        let viewModel = AgentCreationViewModel(defaults: defaults, presets: presets)
        let marketing = try XCTUnwrap(presets.first(where: { $0.id == "marketing" }))

        XCTAssertTrue(viewModel.containsDefaultTeamPreset(marketing))

        viewModel.toggleDefaultTeamPreset(marketing)
        XCTAssertFalse(viewModel.containsDefaultTeamPreset(marketing))

        viewModel.toggleDefaultTeamPreset(marketing)
        XCTAssertTrue(viewModel.containsDefaultTeamPreset(marketing))
    }

    func testCanCreateDefaultTeamDependsOnSelectionAndUserInfo() throws {
        let suiteName = "LocalAgentCreationViewModelPresetTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let presets = AgentPresetCatalog.builtInPresets()
        let viewModel = AgentCreationViewModel(defaults: defaults, presets: presets)

        XCTAssertFalse(viewModel.canCreateDefaultTeam)

        viewModel.data.userCallName = "Yuan"
        XCTAssertTrue(viewModel.canCreateDefaultTeam)

        for preset in presets {
            if viewModel.containsDefaultTeamPreset(preset) {
                viewModel.toggleDefaultTeamPreset(preset)
            }
        }

        XCTAssertTrue(viewModel.selectedDefaultTeamPresets.isEmpty)
        XCTAssertFalse(viewModel.canCreateDefaultTeam)
    }
}
