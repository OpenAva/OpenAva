import XCTest
@testable import OpenAva

final class AgentPresetCatalogTests: XCTestCase {
    func testBuiltInPresetsContainCommonIDs() {
        let presets = AgentPresetCatalog.builtInPresets()
        let ids = Set(presets.map(\.id))

        XCTAssertTrue(ids.contains("general"))
        XCTAssertTrue(ids.contains("coding"))
        XCTAssertTrue(ids.contains("writing"))
        XCTAssertTrue(ids.contains("research"))
        XCTAssertTrue(ids.contains("product"))
        XCTAssertTrue(ids.contains("meeting"))
    }

    func testLoadMergesExternalPresetsAndOverridesDuplicates() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-presets-\(UUID().uuidString).json", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let externalPresets = [
            AgentPreset(
                id: "coding",
                title: "Custom Coding",
                subtitle: "Custom coding subtitle",
                agentName: "Custom Coding Agent",
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

        let coding = try XCTUnwrap(loaded.first(where: { $0.id == "coding" }))
        XCTAssertEqual(coding.title, "Custom Coding")
        XCTAssertEqual(coding.agentEmoji, "🧪")

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
