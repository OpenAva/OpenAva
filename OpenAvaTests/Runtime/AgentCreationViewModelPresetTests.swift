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
            id: "coding",
            title: "Coding Partner",
            subtitle: "Build features faster",
            agentName: "Coding Partner",
            agentEmoji: "💻",
            agentVibe: "Direct",
            soulCoreTruths: "Reason step by step\nOffer actionable suggestions"
        )

        let viewModel = AgentCreationViewModel(defaults: defaults, presets: [preset])
        viewModel.applyPreset(preset, avoiding: [])

        XCTAssertEqual(viewModel.selectedPresetID, "coding")
        XCTAssertEqual(viewModel.data.agentName, "Coding Partner")
        XCTAssertEqual(viewModel.data.agentEmoji, "💻")
        XCTAssertEqual(viewModel.data.agentVibe, "Direct")
        XCTAssertEqual(viewModel.data.soulCoreTruths, "Reason step by step\nOffer actionable suggestions")
    }

    func testApplyPresetWithoutEmojiFallsBackToRandomEmoji() throws {
        let suiteName = "LocalAgentCreationViewModelPresetTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preset = AgentPreset(
            id: "general",
            title: "General Assistant",
            subtitle: "General support",
            agentName: "General Assistant",
            agentEmoji: "   ",
            agentVibe: "Warm",
            soulCoreTruths: "Be genuinely helpful"
        )

        let viewModel = AgentCreationViewModel(defaults: defaults, presets: [preset])
        viewModel.applyPreset(preset, avoiding: [])

        XCTAssertFalse(viewModel.data.agentEmoji.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertTrue(viewModel.emojiCandidates.contains(viewModel.data.agentEmoji))
    }
}
