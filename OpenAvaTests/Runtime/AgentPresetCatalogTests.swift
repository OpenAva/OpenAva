import XCTest
@testable import OpenAva

final class AgentPresetCatalogTests: XCTestCase {
    func testBuiltInPresetsContainCommonIDs() {
        let presets = AgentPresetCatalog.builtInPresets()
        let ids = Set(presets.map(\.id))

        XCTAssertTrue(ids.contains("explorer"))
        XCTAssertTrue(ids.contains("planner"))
        XCTAssertTrue(ids.contains("designer"))
        XCTAssertTrue(ids.contains("executor"))
        XCTAssertTrue(ids.contains("reviewer"))
        XCTAssertTrue(ids.contains("summarizer"))
    }

    func testBuiltInPresetsPreserveExpectedOrder() {
        let presets = AgentPresetCatalog.builtInPresets()

        XCTAssertEqual(
            presets.map(\.id),
            ["explorer", "planner", "designer", "executor", "reviewer", "summarizer"]
        )
    }

    func testLoadMergesExternalPresetsAndOverridesDuplicates() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-presets-\(UUID().uuidString).json", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let externalPresets = [
            AgentPreset(
                id: "explorer",
                title: "Custom Explorer",
                subtitle: "Custom explorer subtitle",
                agentName: "Custom Explorer Agent",
                agentEmoji: "🧪",
                agentVibe: "Direct",
                soulCoreTruths: "Search carefully"
            ),
            AgentPreset(
                id: "ops",
                title: "Ops Helper",
                subtitle: "Operations support",
                agentName: "Ops Helper",
                agentEmoji: "🛠️",
                agentVibe: "Calm",
                soulCoreTruths: "Keep systems stable"
            ),
        ]

        let encoded = try JSONEncoder().encode(externalPresets)
        try encoded.write(to: tempURL)

        let loaded = AgentPresetCatalog.load(environment: [
            AgentPresetCatalog.environmentPathKey: tempURL.path,
        ])

        let explorer = try XCTUnwrap(loaded.first(where: { $0.id == "explorer" }))
        XCTAssertEqual(explorer.title, "Custom Explorer")
        XCTAssertEqual(explorer.agentEmoji, "🧪")

        let ops = loaded.first(where: { $0.id == "ops" })
        XCTAssertNotNil(ops)
    }

    func testLoadFallsBackToBuiltInWhenPathInvalid() {
        let loaded = AgentPresetCatalog.load(environment: [
            AgentPresetCatalog.environmentPathKey: "/tmp/does-not-exist-agent-presets.json",
        ])

        XCTAssertEqual(loaded.map(\.id), AgentPresetCatalog.builtInPresets().map(\.id))
    }
}
