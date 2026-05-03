import Foundation

/// Loads workspace, global, and built-in skills using nanobot-style conventions.
enum AgentSkillsLoader {
    enum SkillVisibility {
        case all
        case modelInvocable
        case userInvocable
    }

    enum SkillExecutionContext: String {
        case inline
        case fork
    }

    struct SkillDefinition: Equatable {
        let name: String
        let displayName: String
        let path: String
        let source: String
        let available: Bool
        let description: String
        let emoji: String?
        let requires: String?
        let whenToUse: String?
        let userInvocable: Bool
        let disableModelInvocation: Bool
        let executionContext: SkillExecutionContext
        let agent: String?
        let effort: String?
        let allowedTools: [String]
        let paths: [String]
        let maturity: String?
        let origin: String?
        let usageCount: Int
        let supportingFiles: [String]

        init(
            name: String,
            displayName: String,
            path: String,
            source: String,
            available: Bool = true,
            description: String = "",
            emoji: String? = nil,
            requires: String? = nil,
            whenToUse: String? = nil,
            userInvocable: Bool = true,
            disableModelInvocation: Bool = false,
            executionContext: SkillExecutionContext = .inline,
            agent: String? = nil,
            effort: String? = nil,
            allowedTools: [String] = [],
            paths: [String] = [],
            maturity: String? = nil,
            origin: String? = nil,
            usageCount: Int = 0,
            supportingFiles: [String] = []
        ) {
            self.name = name
            self.displayName = displayName
            self.path = path
            self.source = source
            self.available = available
            self.description = description
            self.emoji = Self.normalizedEmoji(emoji)
            self.requires = requires
            self.whenToUse = AppConfig.nonEmpty(whenToUse)
            self.userInvocable = userInvocable
            self.disableModelInvocation = disableModelInvocation
            self.executionContext = executionContext
            self.agent = AppConfig.nonEmpty(agent)
            self.effort = AppConfig.nonEmpty(effort)
            self.allowedTools = allowedTools
            self.paths = paths
            self.maturity = AppConfig.nonEmpty(maturity)
            self.origin = AppConfig.nonEmpty(origin)
            self.usageCount = max(0, usageCount)
            self.supportingFiles = supportingFiles
        }

        private static func normalizedEmoji(_ value: String?) -> String? {
            AppConfig.nonEmpty(value)
        }
    }

    private static let workspaceSkillsFolderName = "skills"
    private static let globalSkillsRootFolderName = ".agents"
    private static let skillFileName = "SKILL.md"

    static func globalSkillsRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager _: FileManager = .default
    ) -> URL {
        let homeDirectory = AppConfig.nonEmpty(environment["HOME"])
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        return homeDirectory
            .appendingPathComponent(globalSkillsRootFolderName, isDirectory: true)
            .appendingPathComponent(workspaceSkillsFolderName, isDirectory: true)
    }

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
        visibility: SkillVisibility = .all,
        workspaceRootURL: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        bundle: Bundle = .main
    ) -> [SkillDefinition] {
        var skills: [SkillDefinition] = []
        let resolvedWorkspaceRoot = AgentContextLoader.resolvedRootDirectory(
            workspaceRootURL: workspaceRootURL,
            environment: environment,
            fileManager: fileManager
        )

        if let workspaceDirectory = workspaceSkillsDirectory(
            workspaceRootURL: workspaceRootURL,
            environment: environment,
            fileManager: fileManager
        ) {
            skills.append(contentsOf: collectSkills(from: workspaceDirectory, source: "workspace", fileManager: fileManager))
        }

        if let globalDirectory = globalSkillsDirectory(environment: environment, fileManager: fileManager) {
            for skill in collectSkills(from: globalDirectory, source: "global", fileManager: fileManager) {
                if skills.contains(where: { $0.name == skill.name }) {
                    continue
                }
                skills.append(skill)
            }
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

        skills = skills.filter { shouldInclude($0, visibility: visibility) }

        guard filterUnavailable else {
            return skills
        }

        return skills.filter { skill in
            isSkillAvailable(
                skill,
                workspaceRootURL: resolvedWorkspaceRoot,
                environment: environment,
                fileManager: fileManager
            )
        }
    }

    static func resolveSkill(
        named requestedName: String,
        visibility: SkillVisibility = .all,
        filterUnavailable: Bool = true,
        workspaceRootURL: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        bundle: Bundle = .main
    ) -> SkillDefinition? {
        let allSkills = listSkills(
            filterUnavailable: filterUnavailable,
            includeDisabled: false,
            visibility: visibility,
            workspaceRootURL: workspaceRootURL,
            environment: environment,
            fileManager: fileManager,
            bundle: bundle
        )
        return resolveSkillDefinition(named: requestedName, from: allSkills)
    }

    static func rawSkillContent(for skill: SkillDefinition) -> String? {
        readText(atPath: skill.path)
    }

    static func skillBody(for skill: SkillDefinition) -> String? {
        guard let content = rawSkillContent(for: skill) else {
            return nil
        }
        return stripFrontmatter(content)
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
        visibility: SkillVisibility = .all,
        workspaceRootURL: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        bundle: Bundle = .main
    ) -> [SkillDefinition] {
        let allSkills = listSkills(
            filterUnavailable: false,
            includeDisabled: false,
            visibility: visibility,
            workspaceRootURL: workspaceRootURL,
            environment: environment,
            fileManager: fileManager,
            bundle: bundle
        )
        let resolvedWorkspaceRoot = AgentContextLoader.resolvedRootDirectory(
            workspaceRootURL: workspaceRootURL,
            environment: environment,
            fileManager: fileManager
        )
        return allSkills.map { skill in
            let metadata = skillMetadata(for: skill)
            let description = skillDescription(name: skill.name, metadata: metadata.frontmatter)
            let available = isSkillAvailable(
                skill,
                workspaceRootURL: resolvedWorkspaceRoot,
                environment: environment,
                fileManager: fileManager
            )

            let requires = available
                ? nil
                : AppConfig.nonEmpty(
                    missingRequirements(
                        skillMetadata: metadata.skillMetadata,
                        skillPaths: skill.paths,
                        workspaceRootURL: resolvedWorkspaceRoot,
                        environment: environment,
                        fileManager: fileManager
                    )
                )

            return SkillDefinition(
                name: skill.name,
                displayName: skill.displayName,
                path: skill.path,
                source: skill.source,
                available: available,
                description: description,
                emoji: skill.emoji,
                requires: requires,
                whenToUse: skill.whenToUse,
                userInvocable: skill.userInvocable,
                disableModelInvocation: skill.disableModelInvocation,
                executionContext: skill.executionContext,
                agent: skill.agent,
                effort: skill.effort,
                allowedTools: skill.allowedTools,
                paths: skill.paths,
                maturity: skill.maturity,
                origin: skill.origin,
                usageCount: skill.usageCount,
                supportingFiles: skill.supportingFiles
            )
        }
    }

    private struct ParsedSkillMetadata {
        let frontmatter: [String: String]
        let skillMetadata: [String: Any]
    }

    private static func skillMetadata(for skill: SkillDefinition) -> ParsedSkillMetadata {
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
        skillPaths: [String],
        workspaceRootURL: URL?,
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

        if !skillPaths.isEmpty,
           !matchesPathRequirements(skillPaths, workspaceRootURL: workspaceRootURL, fileManager: fileManager)
        {
            let joined = skillPaths.joined(separator: ", ")
            missing.append("PATHS: \(joined)")
        }

        return missing.joined(separator: ", ")
    }

    private static func skillDescription(name: String, metadata: [String: String]) -> String {
        AppConfig.nonEmpty(metadata["description"]) ?? skillDisplayName(identifier: name, metadata: metadata)
    }

    private static func skillWhenToUse(metadata: [String: String], skillMetadata: [String: Any]) -> String? {
        if let value = metadataString(anyOf: ["when_to_use", "whenToUse"], in: skillMetadata) {
            return value
        }
        return AppConfig.nonEmpty(metadata["when_to_use"])
    }

    private static func skillUserInvocable(metadata: [String: String], skillMetadata: [String: Any]) -> Bool {
        if let bool = metadataBool(anyOf: ["user-invocable", "user_invocable", "userInvocable"], in: skillMetadata) {
            return bool
        }
        return parseBoolean(metadata["user-invocable"]) ?? true
    }

    private static func skillDisableModelInvocation(metadata: [String: String], skillMetadata: [String: Any]) -> Bool {
        if let bool = metadataBool(anyOf: ["disable-model-invocation", "disable_model_invocation", "disableModelInvocation"], in: skillMetadata) {
            return bool
        }
        return parseBoolean(metadata["disable-model-invocation"]) ?? false
    }

    private static func skillExecutionContext(metadata: [String: String], skillMetadata: [String: Any]) -> SkillExecutionContext {
        let rawValue = metadataString(anyOf: ["context"], in: skillMetadata) ?? metadata["context"]
        switch AppConfig.nonEmpty(rawValue)?.lowercased() {
        case SkillExecutionContext.fork.rawValue:
            return .fork
        default:
            return .inline
        }
    }

    private static func skillAgent(metadata: [String: String], skillMetadata: [String: Any]) -> String? {
        metadataString(anyOf: ["agent", "agent_type", "agentType"], in: skillMetadata) ?? AppConfig.nonEmpty(metadata["agent"])
    }

    private static func skillEffort(metadata: [String: String], skillMetadata: [String: Any]) -> String? {
        metadataString(anyOf: ["effort"], in: skillMetadata) ?? AppConfig.nonEmpty(metadata["effort"])
    }

    private static func skillAllowedTools(metadata: [String: String], skillMetadata: [String: Any]) -> [String] {
        let metadataValues = metadataArray(anyOf: ["allowed-tools", "allowed_tools", "allowedTools"], in: skillMetadata)
        if !metadataValues.isEmpty {
            return metadataValues
        }
        return frontmatterStringArray(from: metadata["allowed-tools"])
    }

    private static func skillPaths(metadata: [String: String], skillMetadata: [String: Any]) -> [String] {
        let metadataValues = metadataArray(anyOf: ["paths"], in: skillMetadata)
        if !metadataValues.isEmpty {
            return metadataValues
        }
        return frontmatterStringArray(from: metadata["paths"])
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

    private static func metadataBool(anyOf keys: [String], in skillMetadata: [String: Any]) -> Bool? {
        for key in keys {
            if let value = skillMetadata[key] as? Bool {
                return value
            }
            if let value = skillMetadata[key] as? String,
               let parsed = parseBoolean(value)
            {
                return parsed
            }
        }
        return nil
    }

    private static func metadataArray(anyOf keys: [String], in skillMetadata: [String: Any]) -> [String] {
        for key in keys {
            let values = stringArray(from: skillMetadata[key])
            if !values.isEmpty {
                return values
            }
            if let value = skillMetadata[key] as? String {
                let parsed = frontmatterStringArray(from: value)
                if !parsed.isEmpty {
                    return parsed
                }
            }
        }
        return []
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

            if value.isEmpty {
                let metadataIndent = leadingWhitespaceCount(in: rawLine)
                let (blockLines, scanIndex) = collectIndentedBlock(lines: lines, startIndex: index + 1, parentIndent: metadataIndent)

                if key == "metadata" {
                    let metadataBlock = parseMetadataBlock(blockLines)
                    if !metadataBlock.isEmpty {
                        if let metadataJSONString = metadataJSONString(from: metadataBlock) {
                            metadata["metadata"] = metadataJSONString
                        }

                        for (nestedKey, nestedValue) in metadataBlock {
                            metadata["metadata.\(nestedKey)"] = nestedValue
                        }
                    }

                } else if let blockValue = structuredFrontmatterValue(from: blockLines) {
                    metadata[key] = blockValue
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

    private static func collectIndentedBlock(lines: [String], startIndex: Int, parentIndent: Int) -> ([String], Int) {
        var blockLines: [String] = []
        var scanIndex = startIndex

        while scanIndex < lines.count {
            let candidate = lines[scanIndex]
            let trimmedCandidate = candidate.trimmingCharacters(in: .whitespaces)

            if trimmedCandidate.isEmpty {
                blockLines.append(candidate)
                scanIndex += 1
                continue
            }

            if leadingWhitespaceCount(in: candidate) <= parentIndent {
                break
            }

            blockLines.append(candidate)
            scanIndex += 1
        }

        return (blockLines, scanIndex)
    }

    private static func structuredFrontmatterValue(from lines: [String]) -> String? {
        let values = lines.compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }
            if trimmed.hasPrefix("- ") {
                return AppConfig.nonEmpty(String(trimmed.dropFirst(2)))
            }
            return AppConfig.nonEmpty(trimmed)
        }
        guard !values.isEmpty else {
            return nil
        }
        return values.joined(separator: "\n")
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

    private static func globalSkillsDirectory(environment: [String: String], fileManager: FileManager) -> URL? {
        existingDirectory(at: globalSkillsRoot(environment: environment, fileManager: fileManager), fileManager: fileManager)
    }

    private static func collectSkills(from directory: URL, source: String, fileManager: FileManager) -> [SkillDefinition] {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        else {
            return []
        }

        var skills: [SkillDefinition] = []

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
            let whenToUse = skillWhenToUse(metadata: frontmatter, skillMetadata: parsedMetadata)
            let userInvocable = skillUserInvocable(metadata: frontmatter, skillMetadata: parsedMetadata)
            let disableModelInvocation = skillDisableModelInvocation(metadata: frontmatter, skillMetadata: parsedMetadata)
            let executionContext = skillExecutionContext(metadata: frontmatter, skillMetadata: parsedMetadata)
            let agent = skillAgent(metadata: frontmatter, skillMetadata: parsedMetadata)
            let effort = skillEffort(metadata: frontmatter, skillMetadata: parsedMetadata)
            let allowedTools = skillAllowedTools(metadata: frontmatter, skillMetadata: parsedMetadata)
            let paths = skillPaths(metadata: frontmatter, skillMetadata: parsedMetadata)
            let maturity = AppConfig.nonEmpty(frontmatter["maturity"])
            let origin = AppConfig.nonEmpty(frontmatter["origin"])
            let usageCount = Int(frontmatter["usage_count"] ?? "") ?? 0
            let supportingFiles = collectSupportingFiles(in: entry, fileManager: fileManager)

            skills.append(SkillDefinition(
                name: identifier,
                displayName: displayName,
                path: skillPath.path,
                source: source,
                description: description,
                emoji: emoji,
                whenToUse: whenToUse,
                userInvocable: userInvocable,
                disableModelInvocation: disableModelInvocation,
                executionContext: executionContext,
                agent: agent,
                effort: effort,
                allowedTools: allowedTools,
                paths: paths,
                maturity: maturity,
                origin: origin,
                usageCount: usageCount,
                supportingFiles: supportingFiles
            ))
        }

        return skills.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private static func resolveSkillDefinition(named requestedName: String, from skills: [SkillDefinition]) -> SkillDefinition? {
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

    private static func collectSupportingFiles(in directory: URL, fileManager: FileManager) -> [String] {
        let allowedDirectories = ["references", "templates", "scripts"]
        var collected: [String] = []
        for directoryName in allowedDirectories {
            let subdirectory = directory.appendingPathComponent(directoryName, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: subdirectory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                continue
            }
            guard let enumerator = fileManager.enumerator(at: subdirectory, includingPropertiesForKeys: [.isRegularFileKey]) else {
                continue
            }
            for case let fileURL as URL in enumerator {
                let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey])
                guard values?.isRegularFile == true else { continue }
                collected.append(fileURL.path.replacingOccurrences(of: directory.path + "/", with: ""))
            }
        }
        return collected.sorted()
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

    private static func shouldInclude(_ skill: SkillDefinition, visibility: SkillVisibility) -> Bool {
        switch visibility {
        case .all:
            return true
        case .modelInvocable:
            return !skill.disableModelInvocation
        case .userInvocable:
            return skill.userInvocable
        }
    }

    private static func isSkillAvailable(
        _ skill: SkillDefinition,
        workspaceRootURL: URL?,
        environment: [String: String],
        fileManager: FileManager
    ) -> Bool {
        let metadata = skillMetadata(for: skill)
        guard checkRequirements(skillMetadata: metadata.skillMetadata, environment: environment, fileManager: fileManager) else {
            return false
        }
        return matchesPathRequirements(skill.paths, workspaceRootURL: workspaceRootURL, fileManager: fileManager)
    }

    private static func frontmatterStringArray(from rawValue: String?) -> [String] {
        guard let rawValue = AppConfig.nonEmpty(rawValue) else {
            return []
        }

        let normalized = normalizedNewlines(rawValue)
        if normalized.contains("\n") {
            return normalized
                .components(separatedBy: "\n")
                .compactMap { line in
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return nil }
                    if trimmed.hasPrefix("- ") {
                        return AppConfig.nonEmpty(String(trimmed.dropFirst(2)))
                    }
                    return AppConfig.nonEmpty(trimmed)
                }
        }

        if rawValue.contains(",") {
            return rawValue
                .split(separator: ",")
                .compactMap { part in
                    AppConfig.nonEmpty(String(part).trimmingCharacters(in: .whitespacesAndNewlines))
                }
        }

        return [rawValue]
    }

    private static func parseBoolean(_ rawValue: String?) -> Bool? {
        guard let normalized = AppConfig.nonEmpty(rawValue)?.lowercased() else {
            return nil
        }

        switch normalized {
        case "true", "1", "yes", "y", "on":
            return true
        case "false", "0", "no", "n", "off":
            return false
        default:
            return nil
        }
    }

    private static func matchesPathRequirements(
        _ skillPaths: [String],
        workspaceRootURL: URL?,
        fileManager: FileManager
    ) -> Bool {
        guard !skillPaths.isEmpty else {
            return true
        }
        guard let workspaceRootURL else {
            return false
        }

        let patterns = skillPaths.compactMap(globPatternToRegex)
        guard !patterns.isEmpty else {
            return false
        }

        guard let enumerator = fileManager.enumerator(
            at: workspaceRootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return false
        }

        while let candidate = enumerator.nextObject() as? URL {
            guard let values = try? candidate.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey]),
                  values.isRegularFile == true
            else {
                continue
            }

            let relativePath = candidate.path.replacingOccurrences(of: workspaceRootURL.path + "/", with: "")
            if patterns.contains(where: { regex in
                let range = NSRange(relativePath.startIndex ..< relativePath.endIndex, in: relativePath)
                return regex.firstMatch(in: relativePath, options: [], range: range) != nil
            }) {
                return true
            }
        }

        return false
    }

    private static func globPatternToRegex(_ pattern: String) -> NSRegularExpression? {
        let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        var regex = "^"
        let characters = Array(trimmed)
        var index = 0

        while index < characters.count {
            let character = characters[index]

            if character == "*" {
                let nextIndex = index + 1
                if nextIndex < characters.count, characters[nextIndex] == "*" {
                    regex += ".*"
                    index += 2
                } else {
                    regex += "[^/]*"
                    index += 1
                }
                continue
            }

            if character == "?" {
                regex += "."
                index += 1
                continue
            }

            if character == "{" {
                var cursor = index + 1
                var buffer = ""
                while cursor < characters.count, characters[cursor] != "}" {
                    buffer.append(characters[cursor])
                    cursor += 1
                }
                if cursor < characters.count, !buffer.isEmpty {
                    let alternatives = buffer
                        .split(separator: ",")
                        .map { NSRegularExpression.escapedPattern(for: String($0)) }
                        .joined(separator: "|")
                    regex += "(?:\(alternatives))"
                    index = cursor + 1
                    continue
                }
            }

            regex += NSRegularExpression.escapedPattern(for: String(character))
            index += 1
        }

        regex += "$"
        return try? NSRegularExpression(pattern: regex)
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
