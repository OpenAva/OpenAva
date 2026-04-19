import XCTest
@testable import OpenAva

final class AgentMemoryStoreTests: XCTestCase {
    func testReadOperationsDoNotCreateMemoryDirectoryOrImplicitPromptIndex() async throws {
        let runtimeRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: runtimeRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: runtimeRoot) }

        let store = AgentMemoryStore(runtimeRootURL: runtimeRoot)
        let memoryDirectory = runtimeRoot.appendingPathComponent("memory", isDirectory: true)

        let recallHits = try await store.recall(query: "anything")
        let entries = try await store.listEntries()

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

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: runtimeRoot
                    .appendingPathComponent("memory", isDirectory: true)
                    .appendingPathComponent("MEMORY.md", isDirectory: false)
                    .path
            )
        )

        let hits = try await store.recall(query: "response style preference", limit: 3)
        XCTAssertEqual(hits.first?.slug, created.slug)
        XCTAssertTrue(hits.first?.content.contains("terse") == true)

        let removed = try await store.forget(slug: created.slug)
        XCTAssertTrue(removed)
        let afterDelete = try await store.recall(query: "concise", limit: 3)
        XCTAssertTrue(afterDelete.isEmpty)
    }

    func testRecallDoesNotMatchContentOnlyText() async throws {
        let runtimeRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: runtimeRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: runtimeRoot) }

        let store = AgentMemoryStore(runtimeRootURL: runtimeRoot)
        _ = try await store.upsert(
            name: "Response style",
            type: .feedback,
            description: "Brevity preference",
            content: "Keep answers terse and avoid wrap-up summaries.",
            slug: "response-style"
        )

        let hits = try await store.recall(query: "wrap-up summaries", limit: 3)
        XCTAssertTrue(hits.isEmpty)
    }

    func testUpsertWithoutSlugCreatesNewEntryInsteadOfDeduplicatingTopic() async throws {
        let runtimeRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: runtimeRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: runtimeRoot) }

        let store = AgentMemoryStore(runtimeRootURL: runtimeRoot)
        let first = try await store.upsert(
            name: "Response style",
            type: .feedback,
            description: "Brevity preference",
            content: "Keep answers terse."
        )
        let second = try await store.upsert(
            name: "Response style",
            type: .feedback,
            description: "Brevity preference",
            content: "Keep answers terse and skip wrap-up summaries."
        )

        let entries = try await store.listEntries()
        XCTAssertNotEqual(second.slug, first.slug)
        XCTAssertEqual(first.version, 1)
        XCTAssertEqual(second.version, 1)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(Set(entries.map(\.slug)), [first.slug, second.slug])

        let versionFile = runtimeRoot
            .appendingPathComponent("memory", isDirectory: true)
            .appendingPathComponent(".versions", isDirectory: true)
            .appendingPathComponent(first.slug, isDirectory: true)
            .appendingPathComponent("v1.md", isDirectory: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: versionFile.path))
    }

    func testUpsertWithExplicitSlugUpdatesExistingEntryAndArchivesPreviousVersion() async throws {
        let runtimeRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: runtimeRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: runtimeRoot) }

        let store = AgentMemoryStore(runtimeRootURL: runtimeRoot)
        let first = try await store.upsert(
            name: "Response style",
            type: .feedback,
            description: "Brevity preference",
            content: "Keep answers terse.",
            slug: "response-style"
        )
        let second = try await store.upsert(
            name: "Response style",
            type: .feedback,
            description: "Brevity preference",
            content: "Keep answers terse and skip wrap-up summaries.",
            slug: "response-style"
        )

        let entries = try await store.listEntries()
        XCTAssertEqual(second.slug, first.slug)
        XCTAssertEqual(second.version, 2)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.slug, first.slug)
        XCTAssertEqual(entries.first?.version, 2)
        XCTAssertTrue(entries.first?.content.contains("skip wrap-up") == true)

        let versionFile = runtimeRoot
            .appendingPathComponent("memory", isDirectory: true)
            .appendingPathComponent(".versions", isDirectory: true)
            .appendingPathComponent(first.slug, isDirectory: true)
            .appendingPathComponent("v1.md", isDirectory: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: versionFile.path))
        let archived = try String(contentsOf: versionFile, encoding: .utf8)
        XCTAssertTrue(archived.contains("Keep answers terse."))
    }

    func testExplicitConflictsMarkPreviousMemoryInactive() async throws {
        let runtimeRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: runtimeRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: runtimeRoot) }

        let store = AgentMemoryStore(runtimeRootURL: runtimeRoot)
        let english = try await store.upsert(
            name: "Preferred response language English",
            type: .user,
            description: "Preferred response language",
            content: "Reply in English.",
            slug: "language-english"
        )
        let chinese = try await store.upsert(
            name: "Preferred response language Chinese",
            type: .user,
            description: "Preferred response language",
            content: "Reply in simplified Chinese.",
            slug: "language-chinese",
            conflictsWith: [english.slug]
        )

        let entries = try await store.listEntries()
        XCTAssertEqual(entries.map(\.slug), [chinese.slug])

        let conflictedFile = runtimeRoot
            .appendingPathComponent("memory", isDirectory: true)
            .appendingPathComponent("\(english.slug).md", isDirectory: false)
        let raw = try String(contentsOf: conflictedFile, encoding: .utf8)
        XCTAssertTrue(raw.contains("status: conflicted"))
        XCTAssertTrue(raw.contains("resolved_by: \(chinese.slug)"))
    }

    func testExpiredMemoryDoesNotAppearInRecallOrList() async throws {
        let runtimeRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: runtimeRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: runtimeRoot) }

        let store = AgentMemoryStore(runtimeRootURL: runtimeRoot)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let expiresAt = formatter.string(from: Date(timeIntervalSinceNow: -300))

        let expired = try await store.upsert(
            name: "Temporary campaign note",
            type: .project,
            description: "Short-lived campaign memory",
            content: "Only relevant for yesterday's campaign.",
            expiresAt: expiresAt
        )

        XCTAssertEqual(expired.status, .expired)
        let entries = try await store.listEntries()
        XCTAssertTrue(entries.isEmpty)
        let recallHits = try await store.recall(query: "campaign", limit: 3)
        XCTAssertTrue(recallHits.isEmpty)
    }
}
