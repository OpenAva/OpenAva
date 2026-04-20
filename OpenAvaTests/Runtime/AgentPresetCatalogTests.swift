import XCTest
@testable import OpenAva

final class AgentPresetCatalogTests: XCTestCase {
    func testBuiltInPresetsContainCommonIDs() {
        let presets = AgentPresetCatalog.builtInPresets()
        let ids = Set(presets.map(\.id))

        XCTAssertTrue(ids.contains("marketing"))
        XCTAssertTrue(ids.contains("sales"))
        XCTAssertTrue(ids.contains("support"))
        XCTAssertTrue(ids.contains("hr"))
        XCTAssertTrue(ids.contains("finance"))
        XCTAssertTrue(ids.contains("legal"))
        XCTAssertTrue(ids.contains("design"))
        XCTAssertTrue(ids.contains("product"))
        XCTAssertTrue(ids.contains("engineering"))
        XCTAssertTrue(ids.contains("operations"))
    }

    func testBuiltInPresetsPreserveExpectedOrder() {
        let presets = AgentPresetCatalog.builtInPresets()

        XCTAssertEqual(
            presets.map(\.id),
            ["marketing", "sales", "support", "hr", "finance", "legal", "design", "product", "engineering", "operations"]
        )
    }

    func testLoadMergesExternalPresetsAndOverridesDuplicates() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-presets-\(UUID().uuidString).json", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let externalPresets = [
            AgentPreset(
                id: "marketing",
                title: "Custom Marketing",
                subtitle: "Custom marketing subtitle",
                agentName: "Custom Marketing Agent",
                agentEmoji: "🧪",
                agentVibe: "Direct",
                soulCoreTruths: "Test quickly"
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

        let marketing = try XCTUnwrap(loaded.first(where: { $0.id == "marketing" }))
        XCTAssertEqual(marketing.title, "Custom Marketing")
        XCTAssertEqual(marketing.agentEmoji, "🧪")

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
