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

        var isActive: Bool {
            status == .active
        }
    }

    typealias RecallHit = Entry

    private let supportRootURL: URL
    private let fileManager: FileManager

    private static let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    init(supportRootURL: URL, fileManager: FileManager = .default) {
        self.supportRootURL = supportRootURL.standardizedFileURL
        self.fileManager = fileManager
    }

    func recall(query: String, limit: Int = 5) throws -> [RecallHit] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let entries = try loadEntries()
        guard !entries.isEmpty else { return [] }

        guard !trimmedQuery.isEmpty else {
            return Array(entries.prefix(max(1, limit)))
        }

        let normalizedQuery = Self.normalizedSearchText(trimmedQuery)
        guard !normalizedQuery.isEmpty else {
            return Array(entries.prefix(max(1, limit)))
        }

        return entries
            .filter { entry in
                Self.matchesRecallQuery(entry: entry, normalizedQuery: normalizedQuery)
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
        let allEntries = try loadEntries(includeInactive: true)
        let resolvedSlug: String
        if let slug {
            resolvedSlug = Self.normalizedSlug(slug, fallback: normalizedName)
        } else {
            resolvedSlug = Self.uniqueSlug(fallback: normalizedName, existingEntries: allEntries)
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
           Self.sameDate(existingEntry.expiresAt, normalizedExpiresAt)
        {
            try deactivateConflictingEntries(resolvedSlug: resolvedSlug, explicitConflictSlugs: normalizedConflictSlugs)
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
            expiresAt: normalizedExpiresAt
        )

        try deactivateConflictingEntries(resolvedSlug: resolvedSlug, explicitConflictSlugs: normalizedConflictSlugs)
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
        supportRootURL.appendingPathComponent("memory", isDirectory: true)
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
            expiresAt: expiresAt
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
        expiresAt: Date?
    ) throws {
        var headerLines = [
            "name: \(name)",
            "type: \(type.rawValue)",
            "description: \(description)",
            "version: \(version)",
            "status: \(status.rawValue)",
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

    private func deactivateConflictingEntries(resolvedSlug: String, explicitConflictSlugs: Set<String>) throws {
        let allEntries = try loadEntries(includeInactive: true)
        for entry in allEntries where entry.slug != resolvedSlug && entry.isActive {
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
            expiresAt: entry.expiresAt
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

    private static func uniqueSlug(fallback: String, existingEntries: [Entry]) -> String {
        let base = normalizedSlug(nil, fallback: fallback)
        let existingSlugs = Set(existingEntries.map(\.slug))
        guard existingSlugs.contains(base) else {
            return base
        }

        var suffix = 2
        while true {
            let candidate = "\(base)-\(suffix)"
            if !existingSlugs.contains(candidate) {
                return candidate
            }
            suffix += 1
        }
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

    private static func normalizedSearchText(_ raw: String) -> String {
        raw.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func matchesRecallQuery(entry: Entry, normalizedQuery: String) -> Bool {
        let fields = [
            normalizedSearchText(entry.name),
            normalizedSearchText(entry.description),
            normalizedSearchText(entry.slug),
            normalizedSearchText(entry.type.rawValue),
        ]
        return fields.contains { !$0.isEmpty && $0.contains(normalizedQuery) }
    }
}

actor AgentSkillStore {
    enum Maturity: String {
        case draft
        case validated
        case stable
    }

    enum Origin: String {
        case extractor
        case agent
    }

    struct Entry: Equatable {
        let slug: String
        let name: String
        let description: String
        let whenToUse: String?
        let content: String
        let fileURL: URL
        let modifiedAt: Date
        let version: Int
        let userInvocable: Bool
        let maturity: Maturity
        let origin: Origin
        let usageCount: Int

        var skillDirectoryURL: URL {
            fileURL.deletingLastPathComponent()
        }

        var supportingFiles: [String] {
            let root = skillDirectoryURL
            let fileManager = FileManager.default
            let allowedDirectories = ["references", "templates", "scripts"]
            var collected: [String] = []
            for directoryName in allowedDirectories {
                let directoryURL = root.appendingPathComponent(directoryName, isDirectory: true)
                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                    continue
                }
                guard let enumerator = fileManager.enumerator(at: directoryURL, includingPropertiesForKeys: [.isRegularFileKey]) else {
                    continue
                }
                for case let candidate as URL in enumerator {
                    let values = try? candidate.resourceValues(forKeys: [.isRegularFileKey])
                    guard values?.isRegularFile == true else { continue }
                    collected.append(candidate.path.replacingOccurrences(of: root.path + "/", with: ""))
                }
            }
            return collected.sorted()
        }
    }

    private let workspaceRootURL: URL
    private let fileManager: FileManager

    init(workspaceRootURL: URL, fileManager: FileManager = .default) {
        self.workspaceRootURL = workspaceRootURL.standardizedFileURL
        self.fileManager = fileManager
    }

    func listEntries() throws -> [Entry] {
        try loadEntries()
    }

    @discardableResult
    func upsert(
        name: String,
        description: String,
        whenToUse: String,
        content: String,
        slug: String? = nil,
        userInvocable: Bool = false,
        maturity: Maturity = .draft,
        origin: Origin = .extractor
    ) throws -> Entry {
        try ensureStorage()

        let normalizedName = Self.normalizeSingleLine(name, fallback: "Untitled Skill")
        let normalizedDescription = Self.normalizeSingleLine(description, fallback: normalizedName)
        let normalizedWhenToUse = Self.normalizeSingleLine(whenToUse, fallback: normalizedDescription)
        let normalizedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let allEntries = try loadEntries()
        let resolvedSlug: String
        if let slug {
            resolvedSlug = Self.normalizedSlug(slug, fallback: normalizedName)
        } else {
            resolvedSlug = Self.uniqueSlug(fallback: normalizedName, existingEntries: allEntries)
        }

        let fileURL = skillFileURL(for: resolvedSlug)
        let existingEntry = allEntries.first(where: { $0.slug == resolvedSlug })
        if let existingEntry,
           existingEntry.name == normalizedName,
           existingEntry.description == normalizedDescription,
           existingEntry.whenToUse == normalizedWhenToUse,
           existingEntry.content == normalizedContent,
           existingEntry.userInvocable == userInvocable,
           existingEntry.maturity == maturity,
           existingEntry.origin == origin
        {
            return existingEntry
        }

        let nextVersion = max((existingEntry?.version ?? 0) + 1, 1)
        if let existingEntry {
            try archiveSnapshot(of: existingEntry)
        }

        try fileManager.createDirectory(at: skillDirectoryURL(for: resolvedSlug), withIntermediateDirectories: true)
        try writeEntry(
            to: fileURL,
            slug: resolvedSlug,
            name: normalizedName,
            description: normalizedDescription,
            whenToUse: normalizedWhenToUse,
            content: normalizedContent,
            version: nextVersion,
            userInvocable: userInvocable,
            maturity: maturity,
            origin: origin,
            usageCount: existingEntry?.usageCount ?? 0
        )
        return try loadEntry(from: fileURL)
    }

    @discardableResult
    func recordInvocation(slug: String, succeeded: Bool = true) throws -> Entry? {
        let resolvedSlug = Self.normalizedSlug(slug, fallback: slug)
        let fileURL = skillFileURL(for: resolvedSlug)
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return nil
        }
        let existing = try loadEntry(from: fileURL)
        let nextUsageCount = existing.usageCount + 1
        let nextMaturity = evolvedMaturity(for: existing, nextUsageCount: nextUsageCount, succeeded: succeeded)
        try writeEntry(
            to: fileURL,
            slug: existing.slug,
            name: existing.name,
            description: existing.description,
            whenToUse: existing.whenToUse ?? existing.description,
            content: existing.content,
            version: existing.version,
            userInvocable: existing.userInvocable,
            maturity: nextMaturity,
            origin: existing.origin,
            usageCount: nextUsageCount
        )
        return try loadEntry(from: fileURL)
    }

    @discardableResult
    func writeSupportingFile(slug: String, relativePath: String, content: String) throws -> URL {
        let resolvedSlug = Self.normalizedSlug(slug, fallback: slug)
        let skillDirectory = skillDirectoryURL(for: resolvedSlug)
        let normalizedPath = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isAllowedSupportingPath(normalizedPath) else {
            throw NSError(domain: "AgentSkillStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "INVALID_REQUEST: supporting files must be under references/, templates/, or scripts/"])
        }
        try fileManager.createDirectory(at: skillDirectory, withIntermediateDirectories: true)
        let targetURL = skillDirectory.appendingPathComponent(normalizedPath, isDirectory: false)
        let standardizedTarget = targetURL.standardizedFileURL
        guard standardizedTarget.path.hasPrefix(skillDirectory.standardizedFileURL.path + "/") else {
            throw NSError(domain: "AgentSkillStore", code: 2, userInfo: [NSLocalizedDescriptionKey: "INVALID_REQUEST: supporting file path escapes skill directory"])
        }
        try fileManager.createDirectory(at: standardizedTarget.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: standardizedTarget, atomically: true, encoding: .utf8)
        return standardizedTarget
    }

    private var skillsDirectoryURL: URL {
        workspaceRootURL.appendingPathComponent("skills", isDirectory: true)
    }

    private func skillDirectoryURL(for slug: String) -> URL {
        skillsDirectoryURL.appendingPathComponent(slug, isDirectory: true)
    }

    private func skillFileURL(for slug: String) -> URL {
        skillDirectoryURL(for: slug).appendingPathComponent("SKILL.md", isDirectory: false)
    }

    private func versionsRootDirectoryURL() -> URL {
        skillsDirectoryURL.appendingPathComponent(".versions", isDirectory: true)
    }

    private func versionsDirectoryURL(for slug: String) -> URL {
        versionsRootDirectoryURL().appendingPathComponent(slug, isDirectory: true)
    }

    private func ensureStorage() throws {
        try fileManager.createDirectory(at: skillsDirectoryURL, withIntermediateDirectories: true)
    }

    private func loadEntries() throws -> [Entry] {
        guard fileManager.fileExists(atPath: skillsDirectoryURL.path) else {
            return []
        }
        let directoryURLs = try fileManager.contentsOfDirectory(
            at: skillsDirectoryURL,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        let entries = try directoryURLs.compactMap { directoryURL -> Entry? in
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                return nil
            }
            let fileURL = directoryURL.appendingPathComponent("SKILL.md", isDirectory: false)
            guard fileManager.fileExists(atPath: fileURL.path) else {
                return nil
            }
            return try loadEntry(from: fileURL)
        }
        return entries.sorted { lhs, rhs in
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
        let slug = fileURL.deletingLastPathComponent().lastPathComponent
        let name = Self.normalizeSingleLine(
            header["metadata.display_name"] ?? header["display_name"] ?? header["name"],
            fallback: slug
        )
        let description = Self.normalizeSingleLine(
            header["description"],
            fallback: parts.body.components(separatedBy: .newlines).first ?? name
        )
        let whenToUse = Self.nonEmpty(header["when_to_use"])
        let version = Int(header["version"] ?? "") ?? 1
        let userInvocable = Self.parseBool(header["user-invocable"]) ?? true
        let maturity = Maturity(rawValue: (header["maturity"] ?? "draft").lowercased()) ?? .draft
        let origin = Origin(rawValue: (header["origin"] ?? "extractor").lowercased()) ?? .extractor
        let usageCount = Int(header["usage_count"] ?? "") ?? 0
        return Entry(
            slug: slug,
            name: name,
            description: description,
            whenToUse: whenToUse,
            content: parts.body.trimmingCharacters(in: .whitespacesAndNewlines),
            fileURL: fileURL,
            modifiedAt: modifiedAt,
            version: version,
            userInvocable: userInvocable,
            maturity: maturity,
            origin: origin,
            usageCount: usageCount
        )
    }

    private func writeEntry(
        to fileURL: URL,
        slug: String,
        name: String,
        description: String,
        whenToUse: String,
        content: String,
        version: Int,
        userInvocable: Bool,
        maturity: Maturity,
        origin: Origin,
        usageCount: Int
    ) throws {
        let payload = """
        ---
        name: \(slug)
        description: \(description)
        when_to_use: \(whenToUse)
        user-invocable: \(userInvocable ? "true" : "false")
        maturity: \(maturity.rawValue)
        origin: \(origin.rawValue)
        usage_count: \(usageCount)
        context: inline
        version: \(version)
        metadata:
          display_name: \(name)
        ---

        \(content)
        """

        try payload.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    private func archiveSnapshot(of entry: Entry) throws {
        let sourceURL = skillFileURL(for: entry.slug)
        guard fileManager.fileExists(atPath: sourceURL.path) else { return }
        let directoryURL = versionsDirectoryURL(for: entry.slug)
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let snapshotURL = directoryURL.appendingPathComponent("v\(entry.version).md", isDirectory: false)
        guard !fileManager.fileExists(atPath: snapshotURL.path) else { return }
        let raw = try String(contentsOf: sourceURL, encoding: .utf8)
        try raw.write(to: snapshotURL, atomically: true, encoding: .utf8)
    }

    private func evolvedMaturity(for entry: Entry, nextUsageCount: Int, succeeded: Bool) -> Maturity {
        guard succeeded else { return entry.maturity }
        switch entry.maturity {
        case .draft where nextUsageCount >= 1:
            return .validated
        case .validated where nextUsageCount >= 3:
            return .stable
        default:
            return entry.maturity
        }
    }

    private static func isAllowedSupportingPath(_ relativePath: String) -> Bool {
        let normalized = relativePath.replacingOccurrences(of: "\\", with: "/")
        guard !normalized.isEmpty, !normalized.contains("..") else { return false }
        return normalized.hasPrefix("references/") || normalized.hasPrefix("templates/") || normalized.hasPrefix("scripts/")
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
        let lines = raw.components(separatedBy: .newlines)
        var values: [String: String] = [:]
        var index = 0

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let separator = line.firstIndex(of: ":") else {
                index += 1
                continue
            }

            let key = String(line[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                values[key] = value
                index += 1
                continue
            }

            let parentIndent = leadingWhitespaceCount(in: line)
            let (blockLines, nextIndex) = collectIndentedBlock(lines: lines, startIndex: index + 1, parentIndent: parentIndent)
            if key == "metadata" {
                for nestedLine in blockLines {
                    let nestedTrimmed = nestedLine.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !nestedTrimmed.isEmpty, let nestedSeparator = nestedTrimmed.firstIndex(of: ":") else {
                        continue
                    }
                    let nestedKey = String(nestedTrimmed[..<nestedSeparator]).trimmingCharacters(in: .whitespacesAndNewlines)
                    let nestedValue = String(nestedTrimmed[nestedTrimmed.index(after: nestedSeparator)...])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    values["metadata.\(nestedKey)"] = nestedValue
                }
            }
            index = nextIndex
        }

        return values
    }

    private static func collectIndentedBlock(lines: [String], startIndex: Int, parentIndent: Int) -> ([String], Int) {
        var block: [String] = []
        var index = startIndex

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                block.append(line)
                index += 1
                continue
            }

            let indent = leadingWhitespaceCount(in: line)
            if indent <= parentIndent {
                break
            }

            block.append(line)
            index += 1
        }

        return (block, index)
    }

    private static func leadingWhitespaceCount(in line: String) -> Int {
        line.prefix { $0 == " " || $0 == "\t" }.count
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

    private static func parseBool(_ raw: String?) -> Bool? {
        guard let value = nonEmpty(raw)?.lowercased() else { return nil }
        switch value {
        case "true", "yes", "1":
            return true
        case "false", "no", "0":
            return false
        default:
            return nil
        }
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
        return slug.isEmpty ? "skill" : slug
    }

    private static func uniqueSlug(fallback: String, existingEntries: [Entry]) -> String {
        let base = normalizedSlug(nil, fallback: fallback)
        let existingSlugs = Set(existingEntries.map(\.slug))
        guard existingSlugs.contains(base) else {
            return base
        }

        var suffix = 2
        while true {
            let candidate = "\(base)-\(suffix)"
            if !existingSlugs.contains(candidate) {
                return candidate
            }
            suffix += 1
        }
    }
}
