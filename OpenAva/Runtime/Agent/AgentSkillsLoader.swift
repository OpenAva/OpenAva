import Foundation

/// Loads workspace and built-in skills using nanobot-style conventions.
enum AgentSkillsLoader {
    struct SkillRecord: Equatable {
        let name: String
        let displayName: String
        let path: String
        let source: String
        let available: Bool
        let description: String
        let emoji: String?
        let requires: String?

        init(
            name: String,
            displayName: String,
            path: String,
            source: String,
            available: Bool = true,
            description: String = "",
            emoji: String? = nil,
            requires: String? = nil
        ) {
            self.name = name
            self.displayName = displayName
            self.path = path
            self.source = source
            self.available = available
            self.description = description
            self.emoji = Self.normalizedEmoji(emoji)
            self.requires = requires
        }

        private static func normalizedEmoji(_ value: String?) -> String? {
            AppConfig.nonEmpty(value)
        }
    }

    private static let workspaceSkillsFolderName = "skills"
    private static let skillFileName = "SKILL.md"

    static func builtInSkillsRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        bundle: Bundle = .main
    ) -> URL? {
        builtInSkillsDirectory(environment: environment, fileManager: fileManager, bundle: bundle)
    }

    static func listSkills(
        filterUnavailable: Bool = true,
        includeDisabled: Bool = false,
        workspaceRootURL: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        bundle: Bundle = .main
    ) -> [SkillRecord] {
        var skills: [SkillRecord] = []

        if let workspaceDirectory = workspaceSkillsDirectory(
            workspaceRootURL: workspaceRootURL,
            environment: environment,
            fileManager: fileManager
        ) {
            skills.append(contentsOf: collectSkills(from: workspaceDirectory, source: "workspace", fileManager: fileManager))
        }

        if let builtInDirectory = builtInSkillsDirectory(environment: environment, fileManager: fileManager, bundle: bundle) {
            for skill in collectSkills(from: builtInDirectory, source: "builtin", fileManager: fileManager) {
                if skills.contains(where: { $0.name == skill.name }) {
                    continue
                }
                skills.append(skill)
            }
        }

        if !includeDisabled {
            skills = skills.filter { skill in
                AgentSkillToggleStore.isEnabled(
                    skill,
                    workspaceRootURL: workspaceRootURL,
                    environment: environment,
                    fileManager: fileManager
                )
            }
        }

        guard filterUnavailable else {
            return skills
        }

        return skills.filter { skill in
            let metadata = skillMetadata(for: skill)
            return checkRequirements(skillMetadata: metadata.skillMetadata, environment: environment, fileManager: fileManager)
        }
    }

    static func loadSkill(
        named name: String,
        workspaceRootURL: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        bundle: Bundle = .main
    ) -> String? {
        let allSkills = listSkills(
            filterUnavailable: false,
            includeDisabled: false,
            workspaceRootURL: workspaceRootURL,
            environment: environment,
            fileManager: fileManager,
            bundle: bundle
        )
        guard let match = resolveSkill(named: name, from: allSkills) else {
            return nil
        }
        return readText(atPath: match.path)
    }

    static func loadSkill(
        id: String,
        workspaceRootURL: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        bundle: Bundle = .main
    ) -> String? {
        let normalizedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedID.isEmpty else {
            return nil
        }

        let allSkills = listSkills(
            filterUnavailable: false,
            includeDisabled: false,
            workspaceRootURL: workspaceRootURL,
            environment: environment,
            fileManager: fileManager,
            bundle: bundle
        )
        guard let match = allSkills.first(where: { $0.name == normalizedID }) else {
            return nil
        }
        return readText(atPath: match.path)
    }

    static func buildSkillsSummary(
        workspaceRootURL: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        bundle: Bundle = .main
    ) -> String {
        let catalog = buildSkillCatalog(
            workspaceRootURL: workspaceRootURL,
            environment: environment,
            fileManager: fileManager,
            bundle: bundle
        )
        guard !catalog.isEmpty else {
            return ""
        }

        var lines = ["<skills>"]
        for entry in catalog {
            let availabilityText = entry.available ? "true" : "false"
            lines.append("  <skill available=\"\(availabilityText)\">")
            lines.append("    <id>\(escapeXML(entry.name))</id>")
            lines.append("    <display_name>\(escapeXML(entry.displayName))</display_name>")
            lines.append("    <description>\(escapeXML(entry.description))</description>")

            if let emoji = entry.emoji {
                lines.append("    <emoji>\(escapeXML(emoji))</emoji>")
            }

            if let requires = AppConfig.nonEmpty(entry.requires) {
                lines.append("    <requires>\(escapeXML(requires))</requires>")
            }

            lines.append("  </skill>")
        }
        lines.append("</skills>")
        return lines.joined(separator: "\n")
    }

    static func buildSkillCatalog(
        workspaceRootURL: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        bundle: Bundle = .main
    ) -> [SkillRecord] {
        let allSkills = listSkills(
            filterUnavailable: false,
            includeDisabled: false,
            workspaceRootURL: workspaceRootURL,
            environment: environment,
            fileManager: fileManager,
            bundle: bundle
        )
        return allSkills.map { skill in
            let metadata = skillMetadata(for: skill)
            let description = skillDescription(name: skill.name, metadata: metadata.frontmatter)
            let available = checkRequirements(
                skillMetadata: metadata.skillMetadata,
                environment: environment,
                fileManager: fileManager
            )

            let requires = available
                ? nil
                : AppConfig.nonEmpty(
                    missingRequirements(
                        skillMetadata: metadata.skillMetadata,
                        environment: environment,
                        fileManager: fileManager
                    )
                )

            return SkillRecord(
                name: skill.name,
                displayName: skill.displayName,
                path: skill.path,
                source: skill.source,
                available: available,
                description: description,
                emoji: skill.emoji,
                requires: requires
            )
        }
    }

    private struct ParsedSkillMetadata {
        let frontmatter: [String: String]
        let skillMetadata: [String: Any]
    }

    private static func skillMetadata(for skill: SkillRecord) -> ParsedSkillMetadata {
        guard let content = readText(atPath: skill.path) else {
            return ParsedSkillMetadata(frontmatter: [:], skillMetadata: [:])
        }
        let frontmatter = parseFrontmatter(content)
        let metadataJSON = frontmatter["metadata"]
        let parsedMetadata = parseSkillMetadataJSON(metadataJSON)
        return ParsedSkillMetadata(frontmatter: frontmatter, skillMetadata: parsedMetadata)
    }

    private static func parseSkillMetadataJSON(_ raw: String?) -> [String: Any] {
        guard let raw,
              let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return [:]
        }

        if let nanobotMeta = object["nanobot"] as? [String: Any] {
            return nanobotMeta
        }
        if let openClawMeta = object["openava"] as? [String: Any] {
            return openClawMeta
        }
        return object
    }

    private static func checkRequirements(
        skillMetadata: [String: Any],
        environment: [String: String],
        fileManager: FileManager
    ) -> Bool {
        guard let requires = skillMetadata["requires"] as? [String: Any] else {
            return true
        }

        let binaries = stringArray(from: requires["bins"])
        for binary in binaries where !commandExists(binary, environment: environment, fileManager: fileManager) {
            return false
        }

        let envKeys = stringArray(from: requires["env"])
        for key in envKeys where AppConfig.nonEmpty(environment[key]) == nil {
            return false
        }

        return true
    }

    private static func missingRequirements(
        skillMetadata: [String: Any],
        environment: [String: String],
        fileManager: FileManager
    ) -> String {
        guard let requires = skillMetadata["requires"] as? [String: Any] else {
            return ""
        }

        var missing: [String] = []

        for binary in stringArray(from: requires["bins"]) {
            if !commandExists(binary, environment: environment, fileManager: fileManager) {
                missing.append("CLI: \(binary)")
            }
        }

        for key in stringArray(from: requires["env"]) {
            if AppConfig.nonEmpty(environment[key]) == nil {
                missing.append("ENV: \(key)")
            }
        }

        return missing.joined(separator: ", ")
    }

    private static func skillDescription(name: String, metadata: [String: String]) -> String {
        AppConfig.nonEmpty(metadata["description"]) ?? skillDisplayName(identifier: name, metadata: metadata)
    }

    private static func skillEmoji(metadata: [String: String], skillMetadata: [String: Any]) -> String? {
        if let metadataEmoji = metadataString(anyOf: ["emoji"], in: skillMetadata) {
            return metadataEmoji
        }
        return AppConfig.nonEmpty(metadata["emoji"])
    }

    private static func skillDisplayName(
        identifier: String,
        metadata: [String: String],
        skillMetadata: [String: Any] = [:]
    ) -> String {
        if let displayName = metadataString(anyOf: ["display_name", "displayName", "title", "name"], in: skillMetadata) {
            return displayName
        }

        if let frontmatterName = AppConfig.nonEmpty(metadata["name"]),
           frontmatterName.localizedCaseInsensitiveCompare(identifier) != .orderedSame
        {
            return frontmatterName
        }

        return prettifiedSkillIdentifier(identifier)
    }

    private static func metadataString(anyOf keys: [String], in skillMetadata: [String: Any]) -> String? {
        for key in keys {
            if let value = skillMetadata[key] as? String,
               let normalized = AppConfig.nonEmpty(value)
            {
                return normalized
            }
        }
        return nil
    }

    private static func parseFrontmatter(_ content: String) -> [String: String] {
        let normalized = normalizedNewlines(content)
        guard let range = frontmatterRange(in: normalized) else {
            return [:]
        }

        var metadata: [String: String] = [:]
        let lines = String(normalized[range]).components(separatedBy: "\n")
        var index = 0

        while index < lines.count {
            let rawLine = lines[index]
            let trimmedLine = rawLine.trimmingCharacters(in: .whitespaces)
            guard !trimmedLine.isEmpty, !trimmedLine.hasPrefix("#") else {
                index += 1
                continue
            }

            guard let separatorIndex = rawLine.firstIndex(of: ":") else {
                index += 1
                continue
            }

            let key = String(rawLine[..<separatorIndex])
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
            guard !key.isEmpty else {
                index += 1
                continue
            }

            let valueStart = rawLine.index(after: separatorIndex)
            let rawValue = String(rawLine[valueStart...]).trimmingCharacters(in: .whitespaces)
            let value = rawValue.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))

            if key == "metadata", value.isEmpty {
                let metadataIndent = leadingWhitespaceCount(in: rawLine)
                var blockLines: [String] = []
                var scanIndex = index + 1

                while scanIndex < lines.count {
                    let candidate = lines[scanIndex]
                    let trimmedCandidate = candidate.trimmingCharacters(in: .whitespaces)

                    if trimmedCandidate.isEmpty {
                        blockLines.append(candidate)
                        scanIndex += 1
                        continue
                    }

                    if leadingWhitespaceCount(in: candidate) <= metadataIndent {
                        break
                    }

                    blockLines.append(candidate)
                    scanIndex += 1
                }

                let metadataBlock = parseMetadataBlock(blockLines)
                if !metadataBlock.isEmpty {
                    if let metadataJSONString = metadataJSONString(from: metadataBlock) {
                        metadata["metadata"] = metadataJSONString
                    }

                    for (nestedKey, nestedValue) in metadataBlock {
                        metadata["metadata.\(nestedKey)"] = nestedValue
                    }
                }

                index = scanIndex
                continue
            }

            metadata[key] = value
            index += 1
        }

        return metadata
    }

    private static func parseMetadataBlock(_ lines: [String]) -> [String: String] {
        let nonEmptyLines = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !nonEmptyLines.isEmpty else {
            return [:]
        }

        guard let baseIndent = nonEmptyLines.map({ leadingWhitespaceCount(in: $0) }).min() else {
            return [:]
        }

        var parsed: [String: String] = [:]

        for line in lines {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            guard !trimmedLine.isEmpty else {
                continue
            }

            guard leadingWhitespaceCount(in: line) == baseIndent,
                  let separatorIndex = trimmedLine.firstIndex(of: ":")
            else {
                continue
            }

            let key = String(trimmedLine[..<separatorIndex]).trimmingCharacters(in: .whitespaces).lowercased()
            let valueStart = trimmedLine.index(after: separatorIndex)
            let value = String(trimmedLine[valueStart...])
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))

            guard !key.isEmpty, !value.isEmpty else {
                continue
            }

            parsed[key] = value
        }

        return parsed
    }

    private static func metadataJSONString(from values: [String: String]) -> String? {
        guard !values.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: values, options: []),
              let text = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return text
    }

    private static func leadingWhitespaceCount(in line: String) -> Int {
        line.prefix { $0 == " " || $0 == "\t" }.count
    }

    private static func stripFrontmatter(_ content: String) -> String {
        let normalized = normalizedNewlines(content)
        guard let contentStart = frontmatterContentStart(in: normalized) else {
            return content
        }
        return String(normalized[contentStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func frontmatterRange(in rawContent: String) -> Range<String.Index>? {
        guard rawContent.hasPrefix("---\n") else {
            return nil
        }

        let headerStart = rawContent.index(rawContent.startIndex, offsetBy: 4)
        guard let markerRange = frontmatterMarkerRange(in: rawContent, searchStart: headerStart) else {
            return nil
        }
        return headerStart ..< markerRange.lowerBound
    }

    private static func frontmatterContentStart(in content: String) -> String.Index? {
        guard content.hasPrefix("---\n") else {
            return nil
        }

        let headerStart = content.index(content.startIndex, offsetBy: 4)
        guard let markerRange = frontmatterMarkerRange(in: content, searchStart: headerStart) else {
            return nil
        }
        return markerRange.upperBound
    }

    private static func frontmatterMarkerRange(
        in content: String,
        searchStart: String.Index
    ) -> Range<String.Index>? {
        if let standardRange = content.range(of: "\n---\n", range: searchStart ..< content.endIndex) {
            return standardRange
        }
        return content.range(of: "\n---", range: searchStart ..< content.endIndex)
    }

    private static func normalizedNewlines(_ content: String) -> String {
        content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    private static func escapeXML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func workspaceSkillsDirectory(
        workspaceRootURL: URL?,
        environment: [String: String],
        fileManager: FileManager
    ) -> URL? {
        guard let rootDirectory = AgentContextLoader.resolvedRootDirectory(
            workspaceRootURL: workspaceRootURL,
            environment: environment,
            fileManager: fileManager
        )
        else {
            return nil
        }
        let directory = rootDirectory.appendingPathComponent(workspaceSkillsFolderName, isDirectory: true)
        return existingDirectory(at: directory, fileManager: fileManager)
    }

    private static func builtInSkillsDirectory(
        environment _: [String: String],
        fileManager: FileManager,
        bundle: Bundle
    ) -> URL? {
        // Support both flattened resources and source-like bundle layouts.
        let candidates: [URL?] = [
            // Folder reference copied to bundle root (e.g., "Skills" from explicitFolders)
            bundle.resourceURL?.appendingPathComponent("Skills", isDirectory: true),
            // Legacy path for subdirectory layouts
            bundle.resourceURL?
                .appendingPathComponent("Runtime", isDirectory: true)
                .appendingPathComponent("Agent", isDirectory: true)
                .appendingPathComponent("Skills", isDirectory: true),
            bundle.bundleURL
                .appendingPathComponent("Runtime", isDirectory: true)
                .appendingPathComponent("Agent", isDirectory: true)
                .appendingPathComponent("Skills", isDirectory: true),
            // Development path relative to source file
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .appendingPathComponent("Skills", isDirectory: true),
        ]

        for candidate in candidates {
            guard let candidate else { continue }
            if let directory = existingDirectory(at: candidate, fileManager: fileManager) {
                return directory
            }
        }
        return nil
    }

    private static func collectSkills(from directory: URL, source: String, fileManager: FileManager) -> [SkillRecord] {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        else {
            return []
        }

        var skills: [SkillRecord] = []

        for entry in entries {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: entry.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                continue
            }

            let skillPath = entry.appendingPathComponent(skillFileName, isDirectory: false)
            guard fileManager.fileExists(atPath: skillPath.path) else {
                continue
            }

            let identifier = entry.lastPathComponent
            let frontmatter = readText(atPath: skillPath.path).map(parseFrontmatter) ?? [:]
            let parsedMetadata = parseSkillMetadataJSON(frontmatter["metadata"])
            let displayName = skillDisplayName(
                identifier: identifier,
                metadata: frontmatter,
                skillMetadata: parsedMetadata
            )

            let description = skillDescription(name: identifier, metadata: frontmatter)
            let emoji = skillEmoji(metadata: frontmatter, skillMetadata: parsedMetadata)

            skills.append(SkillRecord(
                name: identifier,
                displayName: displayName,
                path: skillPath.path,
                source: source,
                description: description,
                emoji: emoji
            ))
        }

        return skills.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private static func resolveSkill(named requestedName: String, from skills: [SkillRecord]) -> SkillRecord? {
        if let directMatch = skills.first(where: { $0.name == requestedName }) {
            return directMatch
        }

        let normalizedRequest = requestedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedRequest.isEmpty else {
            return nil
        }

        let matches = skills.filter {
            $0.displayName.localizedCaseInsensitiveCompare(normalizedRequest) == .orderedSame
        }
        guard matches.count == 1 else {
            return nil
        }
        return matches[0]
    }

    private static func prettifiedSkillIdentifier(_ identifier: String) -> String {
        identifier
            .split(whereSeparator: { $0 == "-" || $0 == "_" })
            .map { token in
                let lowercased = token.lowercased()
                switch lowercased {
                case "ai":
                    return "AI"
                case "api":
                    return "API"
                case "ios":
                    return "iOS"
                case "llm":
                    return "LLM"
                case "pdf":
                    return "PDF"
                case "ppt":
                    return "PPT"
                case "ui":
                    return "UI"
                case "ux":
                    return "UX"
                default:
                    return lowercased.prefix(1).uppercased() + lowercased.dropFirst()
                }
            }
            .joined(separator: " ")
    }

    private static func readText(atPath path: String) -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let text = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return text
    }

    private static func existingDirectory(at url: URL, fileManager: FileManager) -> URL? {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        return url
    }

    private static func stringArray(from value: Any?) -> [String] {
        if let array = value as? [String] {
            return array
        }
        if let array = value as? [Any] {
            return array.compactMap { item in
                if let text = item as? String {
                    return AppConfig.nonEmpty(text)
                }
                return nil
            }
        }
        return []
    }

    private static func commandExists(
        _ command: String,
        environment: [String: String],
        fileManager: FileManager
    ) -> Bool {
        let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCommand.isEmpty else {
            return false
        }

        if trimmedCommand.contains("/") {
            return fileManager.isExecutableFile(atPath: trimmedCommand)
        }

        let pathValue = AppConfig.nonEmpty(environment["PATH"]) ?? ""
        let pathEntries = pathValue.split(separator: ":").map(String.init)
        for entry in pathEntries {
            let candidate = URL(fileURLWithPath: entry, isDirectory: true)
                .appendingPathComponent(trimmedCommand, isDirectory: false)
            if fileManager.isExecutableFile(atPath: candidate.path) {
                return true
            }
        }
        return false
    }
}
