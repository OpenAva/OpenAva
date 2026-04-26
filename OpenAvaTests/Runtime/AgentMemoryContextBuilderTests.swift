import XCTest
@testable import OpenAva

final class AgentMemoryContextBuilderTests: XCTestCase {
    func testSelectedContextUsesSelectorWhenValidFilenamesReturned() async throws {
        let runtimeRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: runtimeRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: runtimeRoot) }

        let store = AgentMemoryStore(runtimeRootURL: runtimeRoot)
        let selected = try await store.upsert(
            name: "Response style",
            type: .feedback,
            description: "Brevity preference",
            content: "Prefer concise answers and skip wrap-up summaries.",
            slug: "response-style"
        )
        _ = try await store.upsert(
            name: "Language",
            type: .user,
            description: "Preferred language",
            content: "Reply in simplified Chinese.",
            slug: "language"
        )

        let builder = AgentMemoryContextBuilder(
            runtimeRootURL: runtimeRoot,
            selector: { _, _, _ in
                [selected.fileURL.lastPathComponent]
            }
        )

        let context = await builder.selectedContext(query: "How should I answer?")

        XCTAssertEqual(context?.entries.map(\.slug), [selected.slug])
        XCTAssertEqual(context?.query, "How should I answer?")
        XCTAssertEqual(context?.usedModelSelection, true)
    }

    func testSelectedContextFallsBackToRecallWhenSelectorFails() async throws {
        let runtimeRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: runtimeRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: runtimeRoot) }

        let store = AgentMemoryStore(runtimeRootURL: runtimeRoot)
        let created = try await store.upsert(
            name: "Build pipeline issue",
            type: .project,
            description: "Catalyst host refresh token regression",
            content: "The current build issue is the missing catalystHostRefreshToken symbol in ChatRootView.",
            slug: "build-pipeline-issue"
        )

        let builder = AgentMemoryContextBuilder(
            runtimeRootURL: runtimeRoot,
            selector: { _, _, _ in nil }
        )

        let context = await builder.selectedContext(query: "Catalyst host refresh token regression")

        XCTAssertEqual(context?.entries.map(\.slug), [created.slug])
        XCTAssertEqual(context?.usedModelSelection, false)
    }

    func testContextSectionRendersDynamicRecallBlock() async throws {
        let runtimeRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: runtimeRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: runtimeRoot) }

        let store = AgentMemoryStore(runtimeRootURL: runtimeRoot)
        let created = try await store.upsert(
            name: "Response style",
            type: .feedback,
            description: "Brevity preference",
            content: "Prefer concise answers and avoid wrap-up summaries.",
            slug: "response-style"
        )

        let builder = AgentMemoryContextBuilder(
            runtimeRootURL: runtimeRoot,
            selector: { _, _, _ in
                [created.fileURL.lastPathComponent]
            }
        )

        let section = await builder.contextSection(query: "Response style")

        XCTAssertTrue(section?.contains("## Dynamic Memory Recall") == true)
        XCTAssertTrue(section?.contains("Current request query: Response style") == true)
        XCTAssertTrue(section?.contains(created.name) == true)
        XCTAssertTrue(section?.contains("Prefer concise answers and avoid wrap-up summaries.") == true)
    }

    func testSelectedContextExcludesAlreadySurfacedSlugsFromSelectorCandidates() async throws {
        let runtimeRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: runtimeRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: runtimeRoot) }

        let store = AgentMemoryStore(runtimeRootURL: runtimeRoot)
        _ = try await store.upsert(
            name: "Response style",
            type: .feedback,
            description: "Brevity preference",
            content: "Prefer concise answers.",
            slug: "response-style"
        )
        let fresh = try await store.upsert(
            name: "Formatting",
            type: .feedback,
            description: "Formatting preference",
            content: "Use bullet lists when summarizing.",
            slug: "formatting"
        )

        let builder = AgentMemoryContextBuilder(
            runtimeRootURL: runtimeRoot,
            selector: { _, manifest, _ in
                XCTAssertFalse(manifest.contains("slug=response-style"))
                XCTAssertTrue(manifest.contains("slug=formatting"))
                return [fresh.fileURL.lastPathComponent]
            }
        )

        let context = await builder.selectedContext(
            query: "How should I answer?",
            alreadySurfacedSlugs: ["response-style"]
        )

        XCTAssertEqual(context?.entries.map(\.slug), [fresh.slug])
        XCTAssertEqual(context?.usedModelSelection, true)
    }

    func testSelectedContextFallbackSkipsAlreadySurfacedMatches() async throws {
        let runtimeRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: runtimeRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: runtimeRoot) }

        let store = AgentMemoryStore(runtimeRootURL: runtimeRoot)
        _ = try await store.upsert(
            name: "Response style",
            type: .feedback,
            description: "Primary brevity preference",
            content: "Prefer concise answers.",
            slug: "response-style"
        )
        let alternate = try await store.upsert(
            name: "Response style backup",
            type: .feedback,
            description: "Secondary brevity preference",
            content: "Keep summaries compact.",
            slug: "response-style-backup"
        )

        let builder = AgentMemoryContextBuilder(
            runtimeRootURL: runtimeRoot,
            selector: { _, _, _ in nil }
        )

        let context = await builder.selectedContext(
            query: "Response style",
            alreadySurfacedSlugs: ["response-style"]
        )

        XCTAssertEqual(context?.entries.map(\.slug), [alternate.slug])
        XCTAssertEqual(context?.usedModelSelection, false)
    }
}
