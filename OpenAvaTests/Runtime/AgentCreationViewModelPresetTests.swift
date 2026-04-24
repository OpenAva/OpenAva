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

    func testCanCompleteDependsOnUserAndAgentIdentity() {
        let viewModel = AgentCreationViewModel(presets: [], userDirectoryURL: testDirectoryURL)

        XCTAssertFalse(viewModel.canComplete)

        viewModel.data.userCallName = "Yuan"
        XCTAssertTrue(viewModel.canComplete)

        viewModel.data.agentName = "   "
        XCTAssertFalse(viewModel.canComplete)

        viewModel.data.agentName = "Operator"
        viewModel.data.agentEmoji = "   "
        XCTAssertFalse(viewModel.canComplete)
    }

    func testInitialModeRemainsSingleAgent() {
        let viewModel = AgentCreationViewModel(initialMode: .singleAgent, presets: [], userDirectoryURL: testDirectoryURL)

        XCTAssertEqual(viewModel.creationMode, .singleAgent)
    }
}
