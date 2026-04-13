import Foundation
import XCTest
@testable import OpenAva

@MainActor
final class AgentCreationViewModelPresetTests: XCTestCase {
    func testApplyPresetFillsCreationFieldsAndSelection() {
        let preset = AgentPreset(
            id: "engineering",
            title: "Engineering Lead",
            subtitle: "Build features faster",
            agentName: "Engineering Lead",
            agentEmoji: "💻",
            agentVibe: "Direct",
            soulCoreTruths: "Reason step by step\nOffer actionable suggestions"
        )

        let viewModel = AgentCreationViewModel(presets: [preset])
        viewModel.applyPreset(preset, avoiding: [])

        XCTAssertEqual(viewModel.selectedPresetID, "engineering")
        XCTAssertEqual(viewModel.data.agentName, "Engineering Lead")
        XCTAssertEqual(viewModel.data.agentEmoji, "💻")
        XCTAssertEqual(viewModel.data.agentVibe, "Direct")
        XCTAssertEqual(viewModel.data.soulCoreTruths, "Reason step by step\nOffer actionable suggestions")
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

        let viewModel = AgentCreationViewModel(presets: [preset])
        viewModel.applyPreset(preset, avoiding: [])

        XCTAssertFalse(viewModel.data.agentEmoji.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertTrue(viewModel.emojiCandidates.contains(viewModel.data.agentEmoji))
    }

    func testDefaultTeamPresetsUseCatalogOrder() {
        let viewModel = AgentCreationViewModel(presets: AgentPresetCatalog.builtInPresets())

        XCTAssertEqual(viewModel.defaultTeamPresets.map(\.id), AgentPresetCatalog.defaultTeamPresetIDs)
        XCTAssertFalse(viewModel.canCreateTeam)
    }

    func testToggleDefaultTeamPresetUpdatesSelectedTeam() throws {
        let presets = AgentPresetCatalog.builtInPresets()
        let viewModel = AgentCreationViewModel(presets: presets)
        let marketing = try XCTUnwrap(presets.first(where: { $0.id == "marketing" }))

        XCTAssertFalse(viewModel.containsDefaultTeamPreset(marketing))

        viewModel.toggleDefaultTeamPreset(marketing)
        XCTAssertTrue(viewModel.containsDefaultTeamPreset(marketing))

        viewModel.toggleDefaultTeamPreset(marketing)
        XCTAssertFalse(viewModel.containsDefaultTeamPreset(marketing))
    }

    func testCanCreateTeamDependsOnTeamNameAndUserInfo() throws {
        let presets = AgentPresetCatalog.builtInPresets()
        let viewModel = AgentCreationViewModel(presets: presets)

        XCTAssertFalse(viewModel.canCreateTeam)

        viewModel.data.userCallName = "Yuan"
        XCTAssertFalse(viewModel.canCreateTeam)

        viewModel.data.teamName = "OpenAva Team"
        XCTAssertTrue(viewModel.canCreateTeam)

        let firstPreset = try XCTUnwrap(presets.first)
        viewModel.toggleDefaultTeamPreset(firstPreset)
        XCTAssertEqual(viewModel.selectedDefaultTeamPresets.map(\.id), [firstPreset.id])

        viewModel.data.teamName = "   "
        XCTAssertFalse(viewModel.canCreateTeam)
    }

    func testTeamModeInitializesDefaultTeamName() {
        let viewModel = AgentCreationViewModel(initialMode: .defaultTeam, presets: [])
        XCTAssertFalse(viewModel.data.teamName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
}
