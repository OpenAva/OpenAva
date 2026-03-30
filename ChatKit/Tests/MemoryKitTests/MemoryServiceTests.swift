import Foundation
import XCTest
@testable import MemoryKit

final class MemoryServiceTests: XCTestCase {
    private var workspaceURL: URL!
    private var service: MemoryService!

    override func setUpWithError() throws {
        workspaceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MemoryServiceTests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        service = try MemoryService(workspaceDirectory: workspaceURL)
    }

    override func tearDownWithError() throws {
        if let workspaceURL {
            try? FileManager.default.removeItem(at: workspaceURL)
        }
        workspaceURL = nil
        service = nil
    }

    func testWriteLongTermMemoryReplaceOverwritesFile() async throws {
        let result = try await service.writeLongTermMemory(content: "# Durable\nFact", mode: .replace)
        let content = try String(contentsOf: workspaceURL.appendingPathComponent("MEMORY.md"), encoding: .utf8)

        XCTAssertTrue(result.changed)
        XCTAssertFalse(result.duplicateSkipped)
        XCTAssertEqual(content, "# Durable\nFact")
    }

    func testWriteLongTermMemoryAppendSkipsDuplicateFragment() async throws {
        _ = try await service.writeLongTermMemory(content: "- durable fact", mode: .append)
        let result = try await service.writeLongTermMemory(content: "- durable fact", mode: .append)
        let content = try String(contentsOf: workspaceURL.appendingPathComponent("MEMORY.md"), encoding: .utf8)

        XCTAssertFalse(result.changed)
        XCTAssertTrue(result.duplicateSkipped)
        XCTAssertEqual(content, "- durable fact")
    }

    func testAppendHistoryPrefixesTimestamp() async throws {
        let now = Date(timeIntervalSince1970: 1_742_553_600)
        let result = try await service.appendHistory(entry: "Captured a durable project decision.", now: now)
        let content = try String(contentsOf: workspaceURL.appendingPathComponent("HISTORY.md"), encoding: .utf8)

        XCTAssertTrue(result.entry.hasPrefix("[2025-03-21 00:00] "))
        XCTAssertTrue(content.contains("Captured a durable project decision."))
    }

    func testSearchHistoryKeywordUsesCaseInsensitiveMatching() async throws {
        try await service.appendHistory(
            entry: "Reviewed Project Atlas milestones.",
            now: Date(timeIntervalSince1970: 1_742_553_600)
        )
        try await service.appendHistory(
            entry: "Captured another unrelated event.",
            now: Date(timeIntervalSince1970: 1_742_557_200)
        )

        let result = try await service.searchHistory(
            query: "project atlas",
            mode: .keyword,
            caseInsensitive: true,
            limit: 10
        )

        XCTAssertEqual(result.mode, .keyword)
        XCTAssertEqual(result.query, "project atlas")
        XCTAssertEqual(result.hits.count, 1)
        XCTAssertTrue(result.hits[0].line.contains("Project Atlas"))
    }

    func testSearchHistoryRegexReturnsMatchingEntries() async throws {
        try await service.appendHistory(
            entry: "Decision: ship memory refactor this week.",
            now: Date(timeIntervalSince1970: 1_742_553_600)
        )
        try await service.appendHistory(
            entry: "Note: follow up with UI cleanup later.",
            now: Date(timeIntervalSince1970: 1_742_557_200)
        )

        let result = try await service.searchHistory(
            query: "Decision:.*refactor",
            mode: .regex,
            limit: 10
        )

        XCTAssertEqual(result.mode, .regex)
        XCTAssertEqual(result.hits.count, 1)
        XCTAssertTrue(result.hits[0].line.contains("ship memory refactor"))
    }

    // MARK: - Recent history context

    func testRecentHistoryContextIncludesTodayAndYesterdayEntries() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        // now = 2025-03-22 10:40 UTC
        let now = Date(timeIntervalSince1970: 1_742_640_000)

        let store = try MemoryStore(workspaceDirectory: workspaceURL)
        try await store.appendHistory("[2025-03-20 10:00] Old entry from two days ago.")
        try await store.appendHistory("[2025-03-21 09:00] Yesterday's entry.")
        try await store.appendHistory("[2025-03-22 08:00] Today's entry.")

        let context = try await store.recentHistoryContext(now: now, calendar: calendar)
        XCTAssertTrue(context.contains("Yesterday's entry."), "Should include yesterday's entry")
        XCTAssertTrue(context.contains("Today's entry."), "Should include today's entry")
        XCTAssertFalse(context.contains("Old entry from two days ago."), "Should exclude entries older than yesterday")
    }

    func testMemoryContextCombinesLongTermAndRecentHistory() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let now = Date(timeIntervalSince1970: 1_742_640_000) // 2025-03-22 00:00 UTC

        let store = try MemoryStore(workspaceDirectory: workspaceURL)
        try await store.writeLongTermMemory("- Prefers dark mode")
        try await store.appendHistory("[2025-03-22 08:00] Shipped feature X.")

        let context = try await store.memoryContext(now: now, calendar: calendar)
        XCTAssertTrue(context.contains("## Long-term Memory"), "Should include long-term memory section")
        XCTAssertTrue(context.contains("Prefers dark mode"), "Should include long-term memory content")
        XCTAssertTrue(context.contains("## Recent History"), "Should include recent history section")
        XCTAssertTrue(context.contains("Shipped feature X."), "Should include today's history")
    }

    func testMemoryContextOmitsRecentHistorySectionWhenNoRecentEntries() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let now = Date(timeIntervalSince1970: 1_742_640_000) // 2025-03-22 00:00 UTC

        let store = try MemoryStore(workspaceDirectory: workspaceURL)
        try await store.writeLongTermMemory("- Some durable fact")
        // Only add an old entry, not today/yesterday
        try await store.appendHistory("[2025-03-19 10:00] Old event.")

        let context = try await store.memoryContext(now: now, calendar: calendar)
        XCTAssertTrue(context.contains("## Long-term Memory"), "Should include long-term memory")
        XCTAssertFalse(context.contains("## Recent History"), "Should omit recent history section when no recent entries")
    }
}
