import Foundation

actor AgentMemoryStore {
    enum MemoryType: String, CaseIterable {
        case user
        case feedback
        case project
        case reference
    }

    struct Entry: Equatable {
        let slug: String
        let name: String
        let type: MemoryType
        let description: String
        let content: String
        let fileURL: URL
        let modifiedAt: Date
    }

    struct RecallHit: Equatable {
        let entry: Entry
        let score: Int
    }

    private let runtimeRootURL: URL
    private let fileManager: FileManager

    init(runtimeRootURL: URL, fileManager: FileManager = .default) {
        self.runtimeRootURL = runtimeRootURL.standardizedFileURL
        self.fileManager = fileManager
    }

    func promptContext(maxEntries: Int = 24) throws -> String {
        let entries = try loadEntries()
        guard !entries.isEmpty else { return "" }

        let lines = entries.prefix(maxEntries).map { entry in
            "- [\(entry.name)](\(entry.slug).md) [\(entry.type.rawValue)] — \(entry.description)"
        }
        return (["Indexed agent memories:"] + lines).joined(separator: "\n")
    }

    func recall(query: String, limit: Int = 5) throws -> [RecallHit] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let entries = try loadEntries()
        guard !entries.isEmpty else { return [] }

        let tokens = Self.tokens(from: trimmedQuery)
        let loweredQuery = trimmedQuery.lowercased()

        return entries
            .compactMap { entry in
                let score = Self.score(entry: entry, query: loweredQuery, tokens: tokens)
                guard score > 0 || trimmedQuery.isEmpty else { return nil }
                return RecallHit(entry: entry, score: score)
            }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score {
                    return lhs.score > rhs.score
                }
                return lhs.entry.modifiedAt > rhs.entry.modifiedAt
            }
            .prefix(max(1, limit))
            .map { $0 }
    }

    @discardableResult
    func upsert(
        name: String,
        type: MemoryType,
        description: String,
        content: String,
        slug: String? = nil
    ) throws -> Entry {
        try ensureStorage()

        let normalizedName = Self.normalizeSingleLine(name, fallback: "Untitled Memory")
        let normalizedDescription = Self.normalizeSingleLine(description, fallback: normalizedName)
        let normalizedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedSlug = Self.normalizedSlug(slug, fallback: normalizedName)

        let payload = """
        ---
        name: \(normalizedName)
        type: \(type.rawValue)
        description: \(normalizedDescription)
        ---

        \(normalizedContent)
        """

        let fileURL = memoryDirectoryURL.appendingPathComponent("\(resolvedSlug).md", isDirectory: false)
        try payload.write(to: fileURL, atomically: true, encoding: .utf8)
        return try loadEntry(from: fileURL)
    }

    @discardableResult
    func forget(slug: String) throws -> Bool {
        try ensureStorage()
        let resolvedSlug = Self.normalizedSlug(slug, fallback: slug)
        let fileURL = memoryDirectoryURL.appendingPathComponent("\(resolvedSlug).md", isDirectory: false)
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return false
        }
        try fileManager.removeItem(at: fileURL)
        return true
    }

    func listEntries() throws -> [Entry] {
        try loadEntries()
    }

    private var memoryDirectoryURL: URL {
        runtimeRootURL.appendingPathComponent("memory", isDirectory: true)
    }

    private func ensureStorage() throws {
        try fileManager.createDirectory(at: memoryDirectoryURL, withIntermediateDirectories: true)
    }

    private func loadEntries() throws -> [Entry] {
        guard fileManager.fileExists(atPath: memoryDirectoryURL.path) else {
            return []
        }
        let fileURLs = try fileManager.contentsOfDirectory(
            at: memoryDirectoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        return try fileURLs
            .filter { url in url.pathExtension.lowercased() == "md" }
            .map(loadEntry)
            .sorted { lhs, rhs in
                if lhs.modifiedAt != rhs.modifiedAt {
                    return lhs.modifiedAt > rhs.modifiedAt
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    private func loadEntry(from fileURL: URL) throws -> Entry {
        let raw = try String(contentsOf: fileURL, encoding: .utf8)
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
        let parts = Self.splitFrontmatter(in: normalized)
        let header = Self.parseFrontmatter(parts.header)
        let values = try fileURL.resourceValues(forKeys: [.contentModificationDateKey])
        let modifiedAt = values.contentModificationDate ?? Date()
        let body = parts.body.trimmingCharacters(in: .whitespacesAndNewlines)
        let slug = fileURL.deletingPathExtension().lastPathComponent
        let name = Self.normalizeSingleLine(header["name"], fallback: slug)
        let description = Self.normalizeSingleLine(
            header["description"],
            fallback: body.components(separatedBy: .newlines).first ?? name
        )
        let type = MemoryType(rawValue: (header["type"] ?? "").lowercased()) ?? .project
        return Entry(
            slug: slug,
            name: name,
            type: type,
            description: description,
            content: body,
            fileURL: fileURL,
            modifiedAt: modifiedAt
        )
    }

    private static func splitFrontmatter(in raw: String) -> (header: String, body: String) {
        guard raw.hasPrefix("---\n") else {
            return (header: "", body: raw)
        }
        let remainder = raw.dropFirst(4)
        guard let closingRange = remainder.range(of: "\n---\n") else {
            return (header: "", body: raw)
        }
        let header = String(remainder[..<closingRange.lowerBound])
        let bodyStart = closingRange.upperBound
        return (header: header, body: String(remainder[bodyStart...]))
    }

    private static func parseFrontmatter(_ raw: String) -> [String: String] {
        raw
            .components(separatedBy: .newlines)
            .reduce(into: [String: String]()) { result, line in
                guard let separator = line.firstIndex(of: ":") else { return }
                let key = String(line[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
                let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !key.isEmpty else { return }
                result[key] = value
            }
    }

    private static func normalizeSingleLine(_ raw: String?, fallback: String) -> String {
        let candidate = raw?
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return candidate?.isEmpty == false ? candidate! : fallback
    }

    private static func normalizedSlug(_ raw: String?, fallback: String) -> String {
        let source = normalizeSingleLine(raw, fallback: fallback).lowercased()
        let mapped = source.map { character -> Character in
            if character.isLetter || character.isNumber {
                return character
            }
            return "-"
        }
        let slug = String(mapped)
            .replacingOccurrences(of: "--+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return slug.isEmpty ? "memory" : slug
    }

    private static func tokens(from raw: String) -> [String] {
        raw.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 }
    }

    private static func score(entry: Entry, query: String, tokens: [String]) -> Int {
        let haystackName = entry.name.lowercased()
        let haystackDescription = entry.description.lowercased()
        let haystackContent = entry.content.lowercased()
        var score = 0

        if !query.isEmpty {
            if haystackName.contains(query) {
                score += 18
            }
            if haystackDescription.contains(query) {
                score += 12
            }
            if haystackContent.contains(query) {
                score += 5
            }
            if entry.type.rawValue == query {
                score += 10
            }
        }

        for token in tokens {
            if haystackName.contains(token) {
                score += 6
            }
            if haystackDescription.contains(token) {
                score += 4
            }
            if haystackContent.contains(token) {
                score += 1
            }
            if entry.type.rawValue.contains(token) {
                score += 2
            }
        }

        return score
    }
}
