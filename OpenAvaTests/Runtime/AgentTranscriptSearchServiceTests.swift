import XCTest
@testable import OpenAva

final class AgentTranscriptSearchServiceTests: XCTestCase {
    func testSearchFindsMessageTextAcrossPersistedTranscript() throws {
        let supportRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sessionsRoot = supportRoot
            .appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: supportRoot) }

        let transcriptURL = sessionsRoot.appendingPathComponent("session-1.jsonl", isDirectory: false)
        let lines = [
            #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"Need a concise summary for the onboarding flow."}]}}"#,
            #"{"type":"user","message":{"role":"user","metadata":{"isCompactSummary":"true"},"content":[{"type":"text","text":"Chose the bundled migration approach for memory porting."}]}}"#,
        ]
        try lines.joined(separator: "\n").write(to: transcriptURL, atomically: true, encoding: .utf8)

        let service = AgentTranscriptSearchService(supportRootURL: supportRoot)
        let hits = try service.search(query: "bundled migration", limit: 5)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.sessionID, "session-1")
        XCTAssertEqual(hits.first?.entryType, "user")
    }

    func testSearchPrefersNewestTranscriptAndLatestHitWithinTranscript() throws {
        let supportRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sessionsRoot = supportRoot.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: supportRoot) }

        let transcript1URL = sessionsRoot.appendingPathComponent("session-1.jsonl", isDirectory: false)
        let transcript2URL = sessionsRoot.appendingPathComponent("session-2.jsonl", isDirectory: false)

        try [
            #"{"type":"user","message":{"role":"user","metadata":{"isCompactSummary":"true"},"content":[{"type":"text","text":"older target hit"}]}}"#,
        ].joined(separator: "\n").write(to: transcript1URL, atomically: true, encoding: .utf8)

        try [
            #"{"type":"user","message":{"role":"user","metadata":{"isCompactSummary":"true"},"content":[{"type":"text","text":"newer target hit first"}]}}"#,
            #"{"type":"user","message":{"role":"user","metadata":{"isCompactSummary":"true"},"content":[{"type":"text","text":"newest target hit second"}]}}"#,
        ].joined(separator: "\n").write(to: transcript2URL, atomically: true, encoding: .utf8)

        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1000)],
            ofItemAtPath: transcript1URL.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 2000)],
            ofItemAtPath: transcript2URL.path
        )

        let service = AgentTranscriptSearchService(supportRootURL: supportRoot)
        let hits = try service.search(query: "target hit", limit: 2)

        XCTAssertEqual(hits.count, 2)
        XCTAssertEqual(hits[0].sessionID, "session-2")
        XCTAssertEqual(hits[0].lineNumber, 2)
        XCTAssertEqual(hits[1].sessionID, "session-2")
        XCTAssertEqual(hits[1].lineNumber, 1)
    }

    func testSearchOnlyMatchesMessageTextNotMetadataFields() throws {
        let supportRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sessionsRoot = supportRoot
            .appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: supportRoot) }

        let transcriptURL = sessionsRoot.appendingPathComponent("session-3.jsonl", isDirectory: false)
        let lines = [
            #"{"type":"assistant","toolName":"target hit in metadata only","message":{"role":"assistant","content":[{"type":"text","text":"No relevant content here."}]}}"#,
            #"{"type":"user","customTitle":"another target hit metadata","message":{"role":"user","content":[{"type":"text","text":"Still unrelated body text."}]}}"#,
        ]
        try lines.joined(separator: "\n").write(to: transcriptURL, atomically: true, encoding: .utf8)

        let service = AgentTranscriptSearchService(supportRootURL: supportRoot)
        let hits = try service.search(query: "target hit", limit: 5)

        XCTAssertTrue(hits.isEmpty)
    }
}
