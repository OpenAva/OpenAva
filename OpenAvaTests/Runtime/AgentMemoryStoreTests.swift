import XCTest
@testable import OpenAva

final class AgentMemoryStoreTests: XCTestCase {
    func testReadOperationsDoNotCreateMemoryDirectory() async throws {
        let runtimeRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: runtimeRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: runtimeRoot) }

        let store = AgentMemoryStore(runtimeRootURL: runtimeRoot)
        let memoryDirectory = runtimeRoot.appendingPathComponent("memory", isDirectory: true)

        let promptContext = try await store.promptContext()
        let recallHits = try await store.recall(query: "anything")
        let entries = try await store.listEntries()

        XCTAssertEqual(promptContext, "")
        XCTAssertTrue(recallHits.isEmpty)
        XCTAssertTrue(entries.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: memoryDirectory.path))
    }

    func testUpsertRecallForgetFlow() async throws {
        let runtimeRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: runtimeRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: runtimeRoot) }

        let store = AgentMemoryStore(runtimeRootURL: runtimeRoot)
        let created = try await store.upsert(
            name: "User prefers concise answers",
            type: .feedback,
            description: "Response style preference",
            content: "Keep answers terse and avoid trailing summaries."
        )

        let promptContext = try await store.promptContext()
        XCTAssertTrue(promptContext.contains("User prefers concise answers"))
        XCTAssertTrue(promptContext.contains("feedback"))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: runtimeRoot
                    .appendingPathComponent("memory", isDirectory: true)
                    .appendingPathComponent("MEMORY.md", isDirectory: false)
                    .path
            )
        )

        let hits = try await store.recall(query: "concise summaries", limit: 3)
        XCTAssertEqual(hits.first?.entry.slug, created.slug)
        XCTAssertTrue(hits.first?.entry.content.contains("terse") == true)

        let removed = try await store.forget(slug: created.slug)
        XCTAssertTrue(removed)
        let afterDelete = try await store.recall(query: "concise", limit: 3)
        XCTAssertTrue(afterDelete.isEmpty)
    }
}
