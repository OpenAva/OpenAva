import Foundation

struct AgentTranscriptSearchService {
    private struct TranscriptLine: Decodable {
        struct Message: Decodable {
            struct ContentBlock: Decodable {
                let text: String?
            }

            let role: String?
            let content: [ContentBlock]?
        }

        let type: String?
        let message: Message?
    }

    struct SearchHit: Equatable {
        let sessionID: String
        let entryType: String
        let lineNumber: Int
        let snippet: String
        let fileURL: URL
    }

    private struct CandidateTranscript: Equatable {
        let sessionID: String
        let fileURL: URL
        let modifiedAt: Date
    }

    private let runtimeRootURL: URL
    private let fileManager: FileManager

    init(runtimeRootURL: URL, fileManager: FileManager = .default) {
        self.runtimeRootURL = runtimeRootURL.standardizedFileURL
        self.fileManager = fileManager
    }

    func search(
        query: String,
        sessionID: String? = nil,
        limit: Int = 20,
        caseInsensitive: Bool = true
    ) throws -> [SearchHit] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return [] }

        let transcripts = try candidateTranscripts(sessionID: sessionID)
        guard !transcripts.isEmpty else { return [] }

        let needle = caseInsensitive ? trimmedQuery.lowercased() : trimmedQuery
        var hits: [SearchHit] = []

        for transcript in transcripts {
            let raw = try String(contentsOf: transcript.fileURL, encoding: .utf8)
            let lines = raw.components(separatedBy: .newlines)
            for index in lines.indices.reversed() {
                let line = lines[index]
                guard !line.isEmpty else { continue }
                guard let record = decodeTranscriptLine(from: line) else { continue }
                let searchable = extractMessageText(from: record)
                guard !searchable.isEmpty else { continue }
                let haystack = caseInsensitive ? searchable.lowercased() : searchable
                guard haystack.contains(needle) else { continue }

                hits.append(
                    SearchHit(
                        sessionID: transcript.sessionID,
                        entryType: record.type ?? "unknown",
                        lineNumber: index + 1,
                        snippet: Self.compact(searchable),
                        fileURL: transcript.fileURL
                    )
                )
                if hits.count >= max(1, limit) {
                    return hits
                }
            }
        }

        return hits
    }

    private var sessionsDirectoryURL: URL {
        runtimeRootURL.appendingPathComponent("sessions", isDirectory: true)
    }

    private func candidateTranscripts(sessionID: String?) throws -> [CandidateTranscript] {
        guard fileManager.fileExists(atPath: sessionsDirectoryURL.path) else {
            return []
        }
        if let sessionID, !sessionID.isEmpty {
            let transcriptURL = sessionsDirectoryURL
                .appendingPathComponent(sessionID, isDirectory: true)
                .appendingPathComponent("transcript.jsonl", isDirectory: false)
            guard fileManager.fileExists(atPath: transcriptURL.path) else {
                return []
            }
            let modifiedAt = (try? transcriptURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ?? .distantPast
            return [CandidateTranscript(sessionID: sessionID, fileURL: transcriptURL, modifiedAt: modifiedAt)]
        }
        return try fileManager.contentsOfDirectory(
            at: sessionsDirectoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        .filter { url in
            var isDirectory: ObjCBool = false
            return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
        .compactMap { sessionDirectory -> CandidateTranscript? in
            let transcriptURL = sessionDirectory.appendingPathComponent("transcript.jsonl", isDirectory: false)
            guard fileManager.fileExists(atPath: transcriptURL.path) else {
                return nil
            }
            let modifiedAt = (try? transcriptURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ?? .distantPast
            return CandidateTranscript(
                sessionID: sessionDirectory.lastPathComponent,
                fileURL: transcriptURL,
                modifiedAt: modifiedAt
            )
        }
        .sorted { lhs, rhs in
            if lhs.modifiedAt != rhs.modifiedAt {
                return lhs.modifiedAt > rhs.modifiedAt
            }
            return lhs.sessionID.localizedCaseInsensitiveCompare(rhs.sessionID) == .orderedAscending
        }
    }

    private func decodeTranscriptLine(from line: String) -> TranscriptLine? {
        guard let data = line.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(TranscriptLine.self, from: data)
    }

    private func extractMessageText(from line: TranscriptLine) -> String {
        let texts = line.message?.content?
            .compactMap { block in
                block.text?.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty } ?? []
        return texts.joined(separator: " ")
    }

    private static func compact(_ raw: String, limit: Int = 240) -> String {
        let normalized = raw
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count > limit else { return normalized }
        let endIndex = normalized.index(normalized.startIndex, offsetBy: limit)
        return String(normalized[..<endIndex]) + "…"
    }
}
