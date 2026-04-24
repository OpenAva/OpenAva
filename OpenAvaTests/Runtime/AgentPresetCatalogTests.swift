import XCTest
@testable import OpenAva

final class AgentPresetCatalogTests: XCTestCase {
    func testBuiltInPresetsContainCommonIDs() {
        let presets = AgentPresetCatalog.builtInPresets()
        let ids = Set(presets.map(\.id))

        XCTAssertTrue(ids.contains("nova"))
        XCTAssertTrue(ids.contains("atlas"))
        XCTAssertTrue(ids.contains("iris"))
        XCTAssertTrue(ids.contains("jett"))
        XCTAssertTrue(ids.contains("vera"))
        XCTAssertTrue(ids.contains("sage"))
    }

    func testBuiltInPresetsPreserveExpectedOrder() {
        let presets = AgentPresetCatalog.builtInPresets()

        XCTAssertEqual(
            presets.map(\.id),
            ["nova", "atlas", "iris", "jett", "vera", "sage"]
        )
    }

    func testLoadMergesExternalPresetsAndOverridesDuplicates() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-presets-\(UUID().uuidString).json", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let externalPresets = [
            AgentPreset(
                id: "nova",
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

        let nova = try XCTUnwrap(loaded.first(where: { $0.id == "nova" }))
        XCTAssertEqual(nova.title, "Custom Explorer")
        XCTAssertEqual(nova.agentEmoji, "🧪")

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
