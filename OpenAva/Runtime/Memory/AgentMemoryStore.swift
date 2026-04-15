import Foundation

actor AgentMemoryStore {
    enum MemoryType: String, CaseIterable {
        case user
        case feedback
        case project
        case reference
    }

    enum EntryStatus: String, Equatable {
        case active
        case superseded
        case conflicted
        case expired
    }

    struct Entry: Equatable {
        let slug: String
        let name: String
        let type: MemoryType
        let description: String
        let content: String
        let fileURL: URL
        let modifiedAt: Date
        let version: Int
        let status: EntryStatus
        let resolvedBySlug: String?
        let expiresAt: Date?
        let topicKey: String

        var isActive: Bool {
            status == .active
        }
    }

    struct RecallHit: Equatable {
        let entry: Entry
        let score: Int
    }

    private let runtimeRootURL: URL
    private let fileManager: FileManager

    private static let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    init(runtimeRootURL: URL, fileManager: FileManager = .default) {
        self.runtimeRootURL = runtimeRootURL.standardizedFileURL
        self.fileManager = fileManager
    }

    func promptContext(maxEntries: Int = 24) throws -> String {
        let entries = try loadEntries()
        guard !entries.isEmpty else { return "" }

        let lines = entries.prefix(maxEntries).map { entry in
            let versionSuffix = entry.version > 1 ? " v\(entry.version)" : ""
            return "- [\(entry.name)](\(entry.slug).md) [\(entry.type.rawValue)\(versionSuffix)] — \(entry.description)"
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
        slug: String? = nil,
        expiresAt: String? = nil,
        conflictsWith: [String] = []
    ) throws -> Entry {
        try ensureStorage()

        let normalizedName = Self.normalizeSingleLine(name, fallback: "Untitled Memory")
        let normalizedDescription = Self.normalizeSingleLine(description, fallback: normalizedName)
        let normalizedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedExpiresAt = Self.parseDate(expiresAt)
        let topicKey = Self.normalizedTopicKey(type: type, name: normalizedName)
        let allEntries = try loadEntries(includeInactive: true)
        let resolvedSlug: String
        if let slug {
            resolvedSlug = Self.normalizedSlug(slug, fallback: normalizedName)
        } else if let dedupeEntry = Self.dedupeCandidate(
            for: type,
            name: normalizedName,
            description: normalizedDescription,
            content: normalizedContent,
            entries: allEntries
        ) {
            resolvedSlug = dedupeEntry.slug
        } else {
            resolvedSlug = Self.normalizedSlug(nil, fallback: normalizedName)
        }

        let fileURL = memoryFileURL(for: resolvedSlug)
        let existingEntry = allEntries.first(where: { $0.slug == resolvedSlug })
        let normalizedConflictSlugs = Set(
            conflictsWith.map { Self.normalizedSlug($0, fallback: $0) }
        ).subtracting([resolvedSlug])

        if let existingEntry,
           existingEntry.isActive,
           existingEntry.type == type,
           existingEntry.name == normalizedName,
           existingEntry.description == normalizedDescription,
           existingEntry.content == normalizedContent,
           existingEntry.topicKey == topicKey,
           Self.sameDate(existingEntry.expiresAt, normalizedExpiresAt)
        {
            try deactivateEntriesResolvedBy(
                slug: resolvedSlug,
                topicKey: topicKey,
                type: type,
                explicitConflictSlugs: normalizedConflictSlugs
            )
            return existingEntry
        }

        let nextVersion = max((existingEntry?.version ?? 0) + 1, 1)
        if let existingEntry {
            try archiveSnapshot(of: existingEntry)
        }

        try writeEntry(
            to: fileURL,
            slug: resolvedSlug,
            name: normalizedName,
            type: type,
            description: normalizedDescription,
            content: normalizedContent,
            version: nextVersion,
            status: Self.status(for: .active, expiresAt: normalizedExpiresAt),
            resolvedBySlug: nil,
            expiresAt: normalizedExpiresAt,
            topicKey: topicKey
        )

        try deactivateEntriesResolvedBy(
            slug: resolvedSlug,
            topicKey: topicKey,
            type: type,
            explicitConflictSlugs: normalizedConflictSlugs
        )
        return try loadEntry(from: fileURL)
    }

    @discardableResult
    func forget(slug: String) throws -> Bool {
        try ensureStorage()
        let resolvedSlug = Self.normalizedSlug(slug, fallback: slug)
        let fileURL = memoryFileURL(for: resolvedSlug)
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return false
        }
        try fileManager.removeItem(at: fileURL)
        let versionsDirectoryURL = versionsDirectoryURL(for: resolvedSlug)
        if fileManager.fileExists(atPath: versionsDirectoryURL.path) {
            try? fileManager.removeItem(at: versionsDirectoryURL)
        }
        return true
    }

    func listEntries() throws -> [Entry] {
        try loadEntries()
    }

    private var memoryDirectoryURL: URL {
        runtimeRootURL.appendingPathComponent("memory", isDirectory: true)
    }

    private func memoryFileURL(for slug: String) -> URL {
        memoryDirectoryURL.appendingPathComponent("\(slug).md", isDirectory: false)
    }

    private func versionsRootDirectoryURL() -> URL {
        memoryDirectoryURL.appendingPathComponent(".versions", isDirectory: true)
    }

    private func versionsDirectoryURL(for slug: String) -> URL {
        versionsRootDirectoryURL().appendingPathComponent(slug, isDirectory: true)
    }

    private func ensureStorage() throws {
        try fileManager.createDirectory(at: memoryDirectoryURL, withIntermediateDirectories: true)
    }

    private func loadEntries(includeInactive: Bool = false) throws -> [Entry] {
        guard fileManager.fileExists(atPath: memoryDirectoryURL.path) else {
            return []
        }
        let fileURLs = try fileManager.contentsOfDirectory(
            at: memoryDirectoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        let entries = try fileURLs
            .filter { url in url.pathExtension.lowercased() == "md" }
            .map(loadEntry)
        let filtered = includeInactive ? entries : entries.filter(\.isActive)
        return filtered.sorted { lhs, rhs in
            if lhs.isActive != rhs.isActive {
                return lhs.isActive && !rhs.isActive
            }
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
        let version = Int(header["version"] ?? "") ?? 1
        let rawStatus = EntryStatus(rawValue: (header["status"] ?? EntryStatus.active.rawValue).lowercased()) ?? .active
        let expiresAt = Self.parseDate(header["expires_at"])
        let status = Self.status(for: rawStatus, expiresAt: expiresAt)
        let resolvedBySlug = Self.nonEmpty(header["resolved_by"])
        let topicKey = Self.normalizeSingleLine(header["topic_key"], fallback: Self.normalizedTopicKey(type: type, name: name))
        return Entry(
            slug: slug,
            name: name,
            type: type,
            description: description,
            content: body,
            fileURL: fileURL,
            modifiedAt: modifiedAt,
            version: version,
            status: status,
            resolvedBySlug: resolvedBySlug,
            expiresAt: expiresAt,
            topicKey: topicKey
        )
    }

    private func writeEntry(
        to fileURL: URL,
        slug _: String,
        name: String,
        type: MemoryType,
        description: String,
        content: String,
        version: Int,
        status: EntryStatus,
        resolvedBySlug: String?,
        expiresAt: Date?,
        topicKey: String
    ) throws {
        var headerLines = [
            "name: \(name)",
            "type: \(type.rawValue)",
            "description: \(description)",
            "version: \(version)",
            "status: \(status.rawValue)",
            "topic_key: \(topicKey)",
        ]
        if let resolvedBySlug = Self.nonEmpty(resolvedBySlug) {
            headerLines.append("resolved_by: \(resolvedBySlug)")
        }
        if let expiresAt {
            headerLines.append("expires_at: \(Self.iso8601Formatter.string(from: expiresAt))")
        }

        let payload = """
        ---
        \(headerLines.joined(separator: "\n"))
        ---

        \(content)
        """

        try payload.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    private func archiveSnapshot(of entry: Entry) throws {
        let sourceURL = memoryFileURL(for: entry.slug)
        guard fileManager.fileExists(atPath: sourceURL.path) else { return }
        let directoryURL = versionsDirectoryURL(for: entry.slug)
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let snapshotURL = directoryURL.appendingPathComponent("v\(entry.version).md", isDirectory: false)
        guard !fileManager.fileExists(atPath: snapshotURL.path) else { return }
        let raw = try String(contentsOf: sourceURL, encoding: .utf8)
        try raw.write(to: snapshotURL, atomically: true, encoding: .utf8)
    }

    private func deactivateEntriesResolvedBy(
        slug resolvedSlug: String,
        topicKey: String,
        type: MemoryType,
        explicitConflictSlugs: Set<String>
    ) throws {
        let allEntries = try loadEntries(includeInactive: true)
        for entry in allEntries where entry.slug != resolvedSlug && entry.isActive {
            if entry.type == type, entry.topicKey == topicKey {
                try markEntryInactive(entry, status: .superseded, resolvedBySlug: resolvedSlug)
                continue
            }
            if explicitConflictSlugs.contains(entry.slug) {
                try markEntryInactive(entry, status: .conflicted, resolvedBySlug: resolvedSlug)
            }
        }
    }

    private func markEntryInactive(_ entry: Entry, status: EntryStatus, resolvedBySlug: String) throws {
        guard entry.isActive else { return }
        try archiveSnapshot(of: entry)
        try writeEntry(
            to: entry.fileURL,
            slug: entry.slug,
            name: entry.name,
            type: entry.type,
            description: entry.description,
            content: entry.content,
            version: entry.version,
            status: status,
            resolvedBySlug: resolvedBySlug,
            expiresAt: entry.expiresAt,
            topicKey: entry.topicKey
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

    private static func nonEmpty(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func normalizedTopicKey(type: MemoryType, name: String) -> String {
        "\(type.rawValue)::\(normalizedComparableText(name))"
    }

    private static func normalizedComparableText(_ raw: String) -> String {
        raw.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func contentSignature(description: String, content: String) -> String {
        [description, content]
            .map(normalizedComparableText)
            .joined(separator: " | ")
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

    private static func parseDate(_ raw: String?) -> Date? {
        guard let raw = nonEmpty(raw) else { return nil }
        if let exact = iso8601Formatter.date(from: raw) {
            return exact
        }
        let fallbackFormatter = ISO8601DateFormatter()
        fallbackFormatter.formatOptions = [.withInternetDateTime]
        return fallbackFormatter.date(from: raw)
    }

    private static func status(for rawStatus: EntryStatus, expiresAt: Date?) -> EntryStatus {
        guard rawStatus == .active, let expiresAt, expiresAt <= Date() else {
            return rawStatus
        }
        return .expired
    }

    private static func sameDate(_ lhs: Date?, _ rhs: Date?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case let (lhs?, rhs?):
            return abs(lhs.timeIntervalSince1970 - rhs.timeIntervalSince1970) < 0.001
        default:
            return false
        }
    }

    private static func dedupeCandidate(
        for type: MemoryType,
        name: String,
        description: String,
        content: String,
        entries: [Entry]
    ) -> Entry? {
        let topicKey = normalizedTopicKey(type: type, name: name)
        let signature = contentSignature(description: description, content: content)
        let candidates = entries
            .filter { $0.type == type }
            .sorted { lhs, rhs in
                if lhs.isActive != rhs.isActive {
                    return lhs.isActive && !rhs.isActive
                }
                if lhs.modifiedAt != rhs.modifiedAt {
                    return lhs.modifiedAt > rhs.modifiedAt
                }
                return lhs.version > rhs.version
            }

        if let topicMatch = candidates.first(where: { $0.topicKey == topicKey }) {
            return topicMatch
        }
        return candidates.first {
            contentSignature(description: $0.description, content: $0.content) == signature
        }
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
