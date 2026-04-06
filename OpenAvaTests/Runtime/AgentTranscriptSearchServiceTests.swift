import XCTest
@testable import OpenAva

final class AgentTranscriptSearchServiceTests: XCTestCase {
    func testSearchFindsMessageTextAcrossPersistedTranscript() throws {
        let runtimeRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let transcriptDirectory = runtimeRoot
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("session-1", isDirectory: true)
        try FileManager.default.createDirectory(at: transcriptDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: runtimeRoot) }

        let transcriptURL = transcriptDirectory.appendingPathComponent("transcript.jsonl", isDirectory: false)
        let lines = [
            #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"Need a concise summary for the onboarding flow."}]}}"#,
            #"{"type":"summary","summary":"Chose the bundled migration approach for memory porting."}"#,
        ]
        try lines.joined(separator: "\n").write(to: transcriptURL, atomically: true, encoding: .utf8)

        let service = AgentTranscriptSearchService(runtimeRootURL: runtimeRoot)
        let hits = try service.search(query: "bundled migration", limit: 5)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.sessionID, "session-1")
        XCTAssertEqual(hits.first?.entryType, "summary")
    }

    func testSearchPrefersNewestTranscriptAndLatestHitWithinTranscript() throws {
        let runtimeRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sessionsRoot = runtimeRoot.appendingPathComponent("sessions", isDirectory: true)
        let session1Directory = sessionsRoot.appendingPathComponent("session-1", isDirectory: true)
        let session2Directory = sessionsRoot.appendingPathComponent("session-2", isDirectory: true)
        try FileManager.default.createDirectory(at: session1Directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: session2Directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: runtimeRoot) }

        let transcript1URL = session1Directory.appendingPathComponent("transcript.jsonl", isDirectory: false)
        let transcript2URL = session2Directory.appendingPathComponent("transcript.jsonl", isDirectory: false)

        try [
            #"{"type":"summary","summary":"older target hit"}"#,
        ].joined(separator: "\n").write(to: transcript1URL, atomically: true, encoding: .utf8)

        try [
            #"{"type":"summary","summary":"newer target hit first"}"#,
            #"{"type":"summary","summary":"newest target hit second"}"#,
        ].joined(separator: "\n").write(to: transcript2URL, atomically: true, encoding: .utf8)

        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1000)],
            ofItemAtPath: transcript1URL.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 2000)],
            ofItemAtPath: transcript2URL.path
        )

        let service = AgentTranscriptSearchService(runtimeRootURL: runtimeRoot)
        let hits = try service.search(query: "target hit", limit: 2)

        XCTAssertEqual(hits.count, 2)
        XCTAssertEqual(hits[0].sessionID, "session-2")
        XCTAssertEqual(hits[0].lineNumber, 2)
        XCTAssertEqual(hits[1].sessionID, "session-2")
        XCTAssertEqual(hits[1].lineNumber, 1)
    }
}
