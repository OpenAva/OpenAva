import Foundation

enum AgentContextDocumentKind: CaseIterable, Identifiable {
    case agents
    case heartbeat
    case soul
    case tools
    case identity
    case user

    /// Documents that are editable from the per-agent settings sheet.
    /// `AGENTS.md` is intentionally excluded because it belongs to the project workspace root.
    static let agentSettingsCases: [AgentContextDocumentKind] = [
        .heartbeat,
        .soul,
        .tools,
        .identity,
        .user,
    ]

    var id: String {
        fileName
    }

    var fileName: String {
        switch self {
        case .agents:
            return "AGENTS.md"
        case .heartbeat:
            return "HEARTBEAT.md"
        case .soul:
            return "SOUL.md"
        case .tools:
            return "TOOLS.md"
        case .identity:
            return "IDENTITY.md"
        case .user:
            return "USER.md"
        }
    }

    var purpose: String {
        switch self {
        case .agents:
            return "Defines workspace rules, guardrails, and operating conventions."
        case .heartbeat:
            return "Defines heartbeat schedule, active hours, and autonomous check instructions."
        case .soul:
            return "Defines the agent's core personality and behavioral principles."
        case .tools:
            return "Stores environment-specific tool notes and operational shortcuts."
        case .identity:
            return "Defines the agent's self-description, vibe, and avatar metadata."
        case .user:
            return "Defines user preferences, habits, and background information."
        }
    }

    var localizedPurpose: String {
        switch self {
        case .agents:
            return L10n.tr("settings.context.filePurpose.agents")
        case .heartbeat:
            return L10n.tr("settings.context.filePurpose.heartbeat")
        case .soul:
            return L10n.tr("settings.context.filePurpose.soul")
        case .tools:
            return L10n.tr("settings.context.filePurpose.tools")
        case .identity:
            return L10n.tr("settings.context.filePurpose.identity")
        case .user:
            return L10n.tr("settings.context.filePurpose.user")
        }
    }

    var supportsTemplate: Bool {
        true
    }
}

/// Loads and manages agent context documents from the workspace.
enum AgentContextLoader {
    struct LoadedContext: Equatable {
        let documents: [LoadedDocument]
    }

    struct LoadedDocument: Equatable {
        let fileName: String
        let content: String
        let sourcePath: String?

        init(fileName: String, content: String, sourcePath: String? = nil) {
            self.fileName = fileName
            self.content = content
            self.sourcePath = sourcePath
        }
    }

    /// Bootstrap order aligned with workspace prompt assembly.
    /// Each nested array is a priority group where the first existing file wins.
    private static let bootstrapDocumentFileGroups: [[String]] = [
        ["HEARTBEAT.md"],
        ["SOUL.md"],
        ["TOOLS.md"],
        ["IDENTITY.md"],
        ["USER.md"],
    ]

    private static let workspaceAgentsFileName = AgentContextDocumentKind.agents.fileName
    private static let localWorkspaceAgentsFileName = "AGENTS.local.md"
    private static let hiddenAgentsDirectoryName = ".agents"
    private static let rulesDirectoryName = ".rules"
    private static let maxWorkspaceAgentsIncludeDepth = 5

    private static let allowedWorkspaceAgentsIncludeExtensions: Set<String> = [
        "md", "markdown", "mdown", "mkd", "txt", "text", "rst", "adoc", "asciidoc",
        "json", "jsonc", "yaml", "yml", "toml", "xml", "csv", "tsv",
        "swift", "js", "jsx", "ts", "tsx", "mjs", "cjs", "py", "rb", "go", "rs", "java", "kt", "kts",
        "c", "cc", "cpp", "cxx", "h", "hpp", "m", "mm", "cs", "php", "sh", "bash", "zsh", "fish",
        "html", "htm", "css", "scss", "less", "sql", "graphql", "gql",
    ]

    private struct WorkspaceAgentsCacheKey: Hashable {
        let rootPath: String
        let projectPath: String?
        let homePath: String?
        let includeExternal: Bool
    }

    private static let workspaceAgentsCacheLock = NSLock()
    private static var workspaceAgentsCache: [WorkspaceAgentsCacheKey: [LoadedDocument]] = [:]

    private static let rootEnvironmentKeys = [
        "OPENAVA_AGENT_CONTEXT_DIR",
        "OPENAVA_WORKSPACE_DIR",
        "PWD",
    ]

    /// Compose system prompt by loading context and delegating to AgentPromptBuilder.
    static func composeSystemPrompt(
        baseSystemPrompt: String?,
        workspaceRootURL: URL? = nil,
        agentCount: Int = 1,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> String? {
        let basePrompt = AppConfig.nonEmpty(baseSystemPrompt)
        let context = load(
            workspaceRootURL: workspaceRootURL,
            environment: environment,
            fileManager: fileManager
        )
        let rootDirectory = promptRootDirectory(
            workspaceRootURL: workspaceRootURL,
            environment: environment
        )
        let projectRootDirectory = rootDirectory.flatMap(projectRootForAgentContextDirectory) ?? rootDirectory

        // Build skills context from workspace and built-in skill directories.
        let skillCatalog = AgentSkillsLoader.buildSkillCatalog(
            visibility: .modelInvocable,
            workspaceRootURL: projectRootDirectory,
            environment: environment,
            fileManager: fileManager
        )

        let prompt = AgentPromptBuilder.composeSystemPrompt(
            baseSystemPrompt: basePrompt,
            context: context,
            skillCatalog: skillCatalog,
            rootDirectory: projectRootDirectory,
            agentCount: agentCount
        )
        return AppConfig.nonEmpty(prompt)
    }

    /// Load context documents from resolved root directory.
    static func load(
        workspaceRootURL: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> LoadedContext? {
        guard let rootDirectory = resolvedRootDirectory(
            workspaceRootURL: workspaceRootURL,
            environment: environment,
            fileManager: fileManager
        )
        else {
            return nil
        }
        return load(from: rootDirectory, environment: environment, fileManager: fileManager)
    }

    /// Load context documents from specified root directory.
    static func load(
        from rootDirectory: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> LoadedContext? {
        let projectRootURL = projectRootForAgentContextDirectory(rootDirectory)
        var documents = loadWorkspaceAgentsDocuments(
            rootDirectory: rootDirectory,
            projectRootURL: projectRootURL,
            environment: environment,
            fileManager: fileManager
        )

        if let projectRootURL {
            documents += bootstrapDocumentFileGroups.compactMap { fileNames in
                loadFirstAvailableDocument(
                    fileNames: fileNames,
                    from: preferredRoots(for: fileNames, projectRootURL: projectRootURL, agentContextURL: rootDirectory),
                    fileManager: fileManager
                )
            }
        } else {
            documents += bootstrapDocumentFileGroups.compactMap { fileNames in
                loadFirstAvailableDocument(fileNames: fileNames, from: rootDirectory, fileManager: fileManager)
            }
        }

        guard !documents.isEmpty else {
            return nil
        }
        return LoadedContext(documents: documents)
    }

    static func clearWorkspaceAgentsCache() {
        workspaceAgentsCacheLock.lock()
        workspaceAgentsCache.removeAll()
        workspaceAgentsCacheLock.unlock()
    }

    /// Resolve root directory from environment or override only (no fallback).
    static func resolvedRootDirectory(
        workspaceRootURL: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL? {
        if let workspaceRootURL {
            return workspaceRootURL
        }
        return existingConfiguredRootDirectory(environment: environment, fileManager: fileManager)
    }

    /// Get or create editable root directory.
    static func editableRootDirectory(
        workspaceRootURL: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) throws -> URL {
        if let workspaceRootURL {
            try fileManager.createDirectory(at: workspaceRootURL, withIntermediateDirectories: true)
            return workspaceRootURL
        }

        if let configuredRoot = configuredRootCandidate(environment: environment) {
            let directoryURL = URL(fileURLWithPath: configuredRoot.path, isDirectory: true)
            do {
                try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
                return directoryURL
            } catch {
                // iOS real devices often expose a read-only PWD (for example "/").
                // Fall back to Application Support so Context settings always stay writable.
                if configuredRoot.key == "PWD" {
                    return try defaultEditableRootDirectory(fileManager: fileManager)
                }
                throw error
            }
        }

        return try defaultEditableRootDirectory(fileManager: fileManager)
    }

    /// Get file URL for a specific document kind.
    static func fileURL(
        for kind: AgentContextDocumentKind,
        workspaceRootURL: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) throws -> URL {
        try editableRootDirectory(
            workspaceRootURL: workspaceRootURL,
            environment: environment,
            fileManager: fileManager
        )
        .appendingPathComponent(kind.fileName, isDirectory: false)
    }

    /// Load editable content for a document kind.
    static func loadEditableContent(
        for kind: AgentContextDocumentKind,
        workspaceRootURL: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) throws -> String {
        let fileURL = try fileURL(
            for: kind,
            workspaceRootURL: workspaceRootURL,
            environment: environment,
            fileManager: fileManager
        )
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return ""
        }

        let data = try Data(contentsOf: fileURL)
        guard let text = String(data: data, encoding: .utf8) else {
            throw NSError(
                domain: "AgentContextLoader",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "File is not valid UTF-8: \(kind.fileName)"]
            )
        }
        return text
    }

    /// Save editable content for a document kind.
    static func saveEditableContent(
        _ content: String,
        for kind: AgentContextDocumentKind,
        workspaceRootURL: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) throws {
        let fileURL = try fileURL(
            for: kind,
            workspaceRootURL: workspaceRootURL,
            environment: environment,
            fileManager: fileManager
        )
        try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    /// Load template content for a document kind.
    static func templateContent(
        for kind: AgentContextDocumentKind,
        bundle: Bundle = .main,
        fileManager: FileManager = .default
    ) -> String? {
        guard kind.supportsTemplate,
              let templateURL = templateURL(for: kind, bundle: bundle, fileManager: fileManager),
              let data = try? Data(contentsOf: templateURL),
              let text = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return text
    }

    // MARK: - Private Helpers

    private static func templateURL(
        for kind: AgentContextDocumentKind,
        bundle: Bundle,
        fileManager: FileManager
    ) -> URL? {
        if let bundledURL = bundle.url(forResource: kind.fileName, withExtension: nil, subdirectory: "Templates") {
            return bundledURL
        }

        if let bundledRootURL = bundle.url(forResource: kind.fileName, withExtension: nil) {
            // File-system-synced projects may copy markdown resources to bundle root.
            return bundledRootURL
        }

        let candidateDirectories = [
            bundle.resourceURL,
            bundle.bundleURL,
        ].compactMap { $0 }

        for directory in candidateDirectories {
            let rootCandidateURL = directory
                .appendingPathComponent(kind.fileName, isDirectory: false)
            if fileManager.fileExists(atPath: rootCandidateURL.path) {
                return rootCandidateURL
            }

            let candidateURL = directory
                .appendingPathComponent("Runtime", isDirectory: true)
                .appendingPathComponent("Context", isDirectory: true)
                .appendingPathComponent("Templates", isDirectory: true)
                .appendingPathComponent(kind.fileName, isDirectory: false)
            if fileManager.fileExists(atPath: candidateURL.path) {
                return candidateURL
            }
        }

        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Templates", isDirectory: true)
            .appendingPathComponent(kind.fileName, isDirectory: false)
        if fileManager.fileExists(atPath: sourceRoot.path) {
            return sourceRoot
        }

        return nil
    }

    private static func configuredRootPath(environment: [String: String]) -> String? {
        configuredRootCandidate(environment: environment)?.path
    }

    private static func configuredRootCandidate(environment: [String: String]) -> (key: String, path: String)? {
        rootEnvironmentKeys.lazy.compactMap { key in
            AppConfig.nonEmpty(environment[key])
                .map { (key: key, path: $0) }
        }.first
    }

    private static func defaultEditableRootDirectory(fileManager: FileManager) throws -> URL {
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw NSError(
                domain: "AgentContextLoader",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Application Support directory unavailable"]
            )
        }
        let directoryURL = appSupport
            .appendingPathComponent("OpenAva", isDirectory: true)
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return directoryURL
    }

    private static func existingConfiguredRootDirectory(
        environment: [String: String],
        fileManager: FileManager
    ) -> URL? {
        guard let configuredPath = configuredRootPath(environment: environment) else {
            return nil
        }

        let directoryURL = URL(fileURLWithPath: configuredPath, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        return directoryURL
    }

    private static func loadWorkspaceAgentsDocuments(
        rootDirectory: URL,
        projectRootURL: URL?,
        environment: [String: String],
        fileManager: FileManager
    ) -> [LoadedDocument] {
        let effectiveProjectRootURL = (projectRootURL ?? rootDirectory).standardizedFileURL
        let homeURL = homeDirectoryURL(environment: environment, fileManager: fileManager)
        let includeExternal = parseBoolean(environment["OPENAVA_AGENTS_INCLUDE_EXTERNAL"]) ?? false
        let cacheKey = WorkspaceAgentsCacheKey(
            rootPath: rootDirectory.standardizedFileURL.path,
            projectPath: projectRootURL?.standardizedFileURL.path,
            homePath: homeURL?.standardizedFileURL.path,
            includeExternal: includeExternal
        )

        workspaceAgentsCacheLock.lock()
        if let cached = workspaceAgentsCache[cacheKey] {
            workspaceAgentsCacheLock.unlock()
            return cached
        }
        workspaceAgentsCacheLock.unlock()

        var processedPaths = Set<String>()
        var documents: [LoadedDocument] = []

        for managedURL in managedWorkspaceAgentsFileURLs(environment: environment) {
            documents += processWorkspaceAgentsFile(
                at: managedURL,
                projectRootURL: effectiveProjectRootURL,
                homeURL: homeURL,
                processedPaths: &processedPaths,
                includeExternal: includeExternal,
                depth: 0,
                fileManager: fileManager
            )
        }

        if let homeURL {
            let userURL = homeURL
                .appendingPathComponent(hiddenAgentsDirectoryName, isDirectory: true)
                .appendingPathComponent(workspaceAgentsFileName, isDirectory: false)
            documents += processWorkspaceAgentsFile(
                at: userURL,
                projectRootURL: effectiveProjectRootURL,
                homeURL: homeURL,
                processedPaths: &processedPaths,
                includeExternal: includeExternal,
                depth: 0,
                fileManager: fileManager
            )
        }

        for directoryURL in ancestorDirectories(from: effectiveProjectRootURL).reversed() {
            documents += processWorkspaceAgentsCandidates(
                in: directoryURL,
                projectRootURL: effectiveProjectRootURL,
                homeURL: homeURL,
                processedPaths: &processedPaths,
                includeExternal: includeExternal,
                fileManager: fileManager
            )
            documents += processWorkspaceRulesDirectories(
                in: directoryURL,
                projectRootURL: effectiveProjectRootURL,
                homeURL: homeURL,
                processedPaths: &processedPaths,
                includeExternal: includeExternal,
                fileManager: fileManager
            )
        }

        workspaceAgentsCacheLock.lock()
        workspaceAgentsCache[cacheKey] = documents
        workspaceAgentsCacheLock.unlock()
        return documents
    }

    private static func managedWorkspaceAgentsFileURLs(environment: [String: String]) -> [URL] {
        ["OPENAVA_MANAGED_AGENTS_MD", "OPENAVA_MANAGED_AGENTS_FILE", "OPENAVA_SYSTEM_AGENTS_MD"]
            .compactMap { key in
                AppConfig.nonEmpty(environment[key]).map { URL(fileURLWithPath: $0, isDirectory: false).standardizedFileURL }
            }
    }

    private static func processWorkspaceAgentsCandidates(
        in directoryURL: URL,
        projectRootURL: URL,
        homeURL: URL?,
        processedPaths: inout Set<String>,
        includeExternal: Bool,
        fileManager: FileManager
    ) -> [LoadedDocument] {
        let visibleAgentsURL = directoryURL.appendingPathComponent(workspaceAgentsFileName, isDirectory: false)
        let hiddenAgentsURL = directoryURL
            .appendingPathComponent(hiddenAgentsDirectoryName, isDirectory: true)
            .appendingPathComponent(workspaceAgentsFileName, isDirectory: false)
        let visibleLocalURL = directoryURL.appendingPathComponent(localWorkspaceAgentsFileName, isDirectory: false)
        let hiddenLocalURL = directoryURL
            .appendingPathComponent(hiddenAgentsDirectoryName, isDirectory: true)
            .appendingPathComponent(localWorkspaceAgentsFileName, isDirectory: false)

        return [visibleAgentsURL, hiddenAgentsURL, visibleLocalURL, hiddenLocalURL].flatMap { fileURL in
            processWorkspaceAgentsFile(
                at: fileURL,
                projectRootURL: projectRootURL,
                homeURL: homeURL,
                processedPaths: &processedPaths,
                includeExternal: includeExternal,
                depth: 0,
                fileManager: fileManager
            )
        }
    }

    private static func processWorkspaceRulesDirectories(
        in directoryURL: URL,
        projectRootURL: URL,
        homeURL: URL?,
        processedPaths: inout Set<String>,
        includeExternal: Bool,
        fileManager: FileManager
    ) -> [LoadedDocument] {
        let rulesDirectories = [
            directoryURL.appendingPathComponent(rulesDirectoryName, isDirectory: true),
            directoryURL
                .appendingPathComponent(hiddenAgentsDirectoryName, isDirectory: true)
                .appendingPathComponent(rulesDirectoryName, isDirectory: true),
        ]

        var documents: [LoadedDocument] = []
        for rulesDirectoryURL in rulesDirectories {
            guard let children = try? fileManager.contentsOfDirectory(
                at: rulesDirectoryURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            let ruleFiles = children
                .filter { $0.pathExtension.lowercased() == "md" }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            for fileURL in ruleFiles {
                documents += processWorkspaceAgentsFile(
                    at: fileURL,
                    projectRootURL: projectRootURL,
                    homeURL: homeURL,
                    processedPaths: &processedPaths,
                    includeExternal: includeExternal,
                    depth: 0,
                    fileManager: fileManager
                )
            }
        }

        return documents
    }

    static func loadNestedWorkspaceAgentsDocuments(
        for targetURL: URL,
        workspaceRootURL: URL,
        alreadyLoadedSourcePaths: Set<String> = [],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> [LoadedDocument] {
        let rootURL = workspaceRootURL.standardizedFileURL
        let targetDirectoryURL = workspaceAgentsTargetDirectoryURL(for: targetURL, fileManager: fileManager)
        guard isDescendantOrSame(targetDirectoryURL, of: rootURL), targetDirectoryURL.path != rootURL.path else {
            return []
        }

        let homeURL = homeDirectoryURL(environment: environment, fileManager: fileManager)
        let includeExternal = parseBoolean(environment["OPENAVA_AGENTS_INCLUDE_EXTERNAL"]) ?? false
        var processedPaths = alreadyLoadedSourcePaths
        var documents: [LoadedDocument] = []

        for directoryURL in directoriesBetween(ancestorURL: rootURL, descendantURL: targetDirectoryURL) {
            documents += processWorkspaceAgentsCandidates(
                in: directoryURL,
                projectRootURL: rootURL,
                homeURL: homeURL,
                processedPaths: &processedPaths,
                includeExternal: includeExternal,
                fileManager: fileManager
            )
            documents += processWorkspaceRulesDirectories(
                in: directoryURL,
                projectRootURL: rootURL,
                homeURL: homeURL,
                processedPaths: &processedPaths,
                includeExternal: includeExternal,
                fileManager: fileManager
            )
        }

        return documents
    }

    private static func workspaceAgentsTargetDirectoryURL(for targetURL: URL, fileManager: FileManager) -> URL {
        let standardizedURL = targetURL.standardizedFileURL
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: standardizedURL.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return standardizedURL
        }
        return standardizedURL.deletingLastPathComponent().standardizedFileURL
    }

    private static func directoriesBetween(ancestorURL: URL, descendantURL: URL) -> [URL] {
        let ancestorPath = ancestorURL.standardizedFileURL.path
        var directories: [URL] = []
        var currentURL = descendantURL.standardizedFileURL

        while currentURL.path != ancestorPath, currentURL.path != "/" {
            directories.append(currentURL)
            currentURL = currentURL.deletingLastPathComponent().standardizedFileURL
        }

        return directories.reversed()
    }

    private static func processWorkspaceAgentsFile(
        at fileURL: URL,
        projectRootURL: URL,
        homeURL: URL?,
        processedPaths: inout Set<String>,
        includeExternal: Bool,
        depth: Int,
        fileManager: FileManager
    ) -> [LoadedDocument] {
        guard depth <= maxWorkspaceAgentsIncludeDepth,
              isReadableTextIncludeURL(fileURL),
              fileManager.fileExists(atPath: fileURL.path),
              let rawText = readRawText(at: fileURL)
        else {
            return []
        }

        let standardizedURL = fileURL.standardizedFileURL
        let standardizedPath = standardizedURL.path
        guard !processedPaths.contains(standardizedPath) else {
            return []
        }
        processedPaths.insert(standardizedPath)

        let commentStripped = stripBlockHTMLComments(from: rawText)
        let parsed = parseMarkdownFrontmatter(commentStripped)
        guard pathsFrontmatterMatches(parsed.frontmatter["paths"], projectRootURL: projectRootURL, fileManager: fileManager) else {
            return []
        }

        var documents: [LoadedDocument] = []
        if let content = AppConfig.nonEmpty(parsed.body) {
            documents.append(
                LoadedDocument(
                    fileName: displayName(for: standardizedURL, projectRootURL: projectRootURL, homeURL: homeURL),
                    content: content,
                    sourcePath: standardizedPath
                )
            )
        }

        let includeURLs = extractWorkspaceAgentsIncludeURLs(
            from: parsed.body,
            parentFileURL: standardizedURL,
            projectRootURL: projectRootURL,
            homeURL: homeURL,
            includeExternal: includeExternal
        )

        for includeURL in includeURLs {
            documents += processWorkspaceAgentsFile(
                at: includeURL,
                projectRootURL: projectRootURL,
                homeURL: homeURL,
                processedPaths: &processedPaths,
                includeExternal: includeExternal,
                depth: depth + 1,
                fileManager: fileManager
            )
        }

        return documents
    }

    private static func isDescendantOrSame(_ url: URL, of ancestorURL: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let ancestorPath = ancestorURL.standardizedFileURL.path
        if path == ancestorPath {
            return true
        }
        if ancestorPath == "/" {
            return path.hasPrefix("/")
        }
        return path.hasPrefix(ancestorPath + "/")
    }

    private static func ancestorDirectories(from directoryURL: URL) -> [URL] {
        var directories: [URL] = []
        var currentURL = directoryURL.standardizedFileURL

        while true {
            directories.append(currentURL)
            let parentURL = currentURL.deletingLastPathComponent().standardizedFileURL
            if parentURL.path == currentURL.path {
                break
            }
            currentURL = parentURL
        }

        return directories
    }

    private static func homeDirectoryURL(environment: [String: String], fileManager: FileManager) -> URL? {
        _ = fileManager
        if let homePath = AppConfig.nonEmpty(environment["HOME"]) {
            return URL(fileURLWithPath: homePath, isDirectory: true).standardizedFileURL
        }
        guard let homePath = AppConfig.nonEmpty(NSHomeDirectory()) else {
            return nil
        }
        return URL(fileURLWithPath: homePath, isDirectory: true).standardizedFileURL
    }

    private static func readRawText(at fileURL: URL) -> String? {
        guard let data = try? Data(contentsOf: fileURL),
              let rawText = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return rawText
    }

    private static func stripBlockHTMLComments(from rawText: String) -> String {
        let lines = rawText.components(separatedBy: .newlines)
        var output: [String] = []
        var skippingBlockComment = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if skippingBlockComment {
                if trimmed.contains("-->") {
                    skippingBlockComment = false
                }
                continue
            }

            if trimmed.hasPrefix("<!--") {
                if !trimmed.contains("-->") {
                    skippingBlockComment = true
                }
                continue
            }

            output.append(line)
        }

        return output.joined(separator: "\n")
    }

    private static func parseMarkdownFrontmatter(_ rawText: String) -> (frontmatter: [String: String], body: String) {
        let normalized = rawText.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        guard normalized.hasPrefix("---\n") else {
            return ([:], normalized)
        }

        let bodyStart = normalized.index(normalized.startIndex, offsetBy: 4)
        guard let markerRange = normalized.range(of: "\n---", range: bodyStart ..< normalized.endIndex) else {
            return ([:], normalized)
        }

        let frontmatterText = String(normalized[bodyStart ..< markerRange.lowerBound])
        var bodyIndex = markerRange.upperBound
        if bodyIndex < normalized.endIndex, normalized[bodyIndex] == "\n" {
            bodyIndex = normalized.index(after: bodyIndex)
        }

        return (parseSimpleFrontmatter(frontmatterText), String(normalized[bodyIndex...]))
    }

    private static func parseSimpleFrontmatter(_ rawFrontmatter: String) -> [String: String] {
        let lines = rawFrontmatter.components(separatedBy: "\n")
        var metadata: [String: String] = [:]
        var index = 0

        while index < lines.count {
            let rawLine = lines[index]
            let trimmedLine = rawLine.trimmingCharacters(in: .whitespaces)
            guard !trimmedLine.isEmpty, !trimmedLine.hasPrefix("#"), let separatorIndex = rawLine.firstIndex(of: ":") else {
                index += 1
                continue
            }

            let key = String(rawLine[..<separatorIndex]).trimmingCharacters(in: .whitespaces).lowercased()
            let valueStart = rawLine.index(after: separatorIndex)
            let rawValue = String(rawLine[valueStart...]).trimmingCharacters(in: .whitespaces)
            if rawValue.isEmpty {
                let parentIndent = leadingWhitespaceCount(in: rawLine)
                var values: [String] = []
                index += 1
                while index < lines.count {
                    let candidate = lines[index]
                    let trimmedCandidate = candidate.trimmingCharacters(in: .whitespaces)
                    if trimmedCandidate.isEmpty {
                        index += 1
                        continue
                    }
                    if leadingWhitespaceCount(in: candidate) <= parentIndent {
                        break
                    }
                    if trimmedCandidate.hasPrefix("- ") {
                        values.append(String(trimmedCandidate.dropFirst(2)))
                    } else {
                        values.append(trimmedCandidate)
                    }
                    index += 1
                }
                if !values.isEmpty {
                    metadata[key] = values.joined(separator: "\n")
                }
                continue
            }

            metadata[key] = rawValue.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            index += 1
        }

        return metadata
    }

    private static func leadingWhitespaceCount(in value: String) -> Int {
        value.prefix { $0 == " " || $0 == "\t" }.count
    }

    private static func pathsFrontmatterMatches(_ rawPaths: String?, projectRootURL: URL, fileManager: FileManager) -> Bool {
        let paths = frontmatterStringArray(from: rawPaths)
        guard !paths.isEmpty else {
            return true
        }

        let regexes = paths.compactMap(globPatternToRegex)
        guard !regexes.isEmpty,
              let enumerator = fileManager.enumerator(
                  at: projectRootURL,
                  includingPropertiesForKeys: [.isRegularFileKey],
                  options: [.skipsHiddenFiles]
              )
        else {
            return false
        }

        while let candidate = enumerator.nextObject() as? URL {
            guard let values = try? candidate.resourceValues(forKeys: [.isRegularFileKey]), values.isRegularFile == true else {
                continue
            }
            let relativePath = relativePath(for: candidate, rootURL: projectRootURL) ?? candidate.lastPathComponent
            if regexes.contains(where: { regexMatches($0, value: relativePath) }) {
                return true
            }
        }

        return false
    }

    private static func frontmatterStringArray(from rawValue: String?) -> [String] {
        guard let rawValue = AppConfig.nonEmpty(rawValue) else {
            return []
        }
        let normalized = rawValue.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        if normalized.contains("\n") {
            return normalized.components(separatedBy: "\n").compactMap { line in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                return trimmed.hasPrefix("- ") ? AppConfig.nonEmpty(String(trimmed.dropFirst(2))) : trimmed
            }
        }
        if normalized.contains(",") {
            return normalized.split(separator: ",").compactMap { AppConfig.nonEmpty(String($0).trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
        return [normalized]
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
                    let slashIndex = index + 2
                    if slashIndex < characters.count, characters[slashIndex] == "/" {
                        regex += "(?:.*/)?"
                        index += 3
                    } else {
                        regex += ".*"
                        index += 2
                    }
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
                    regex += "(?:" + buffer.split(separator: ",").map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: "|") + ")"
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

    private static func regexMatches(_ regex: NSRegularExpression, value: String) -> Bool {
        let range = NSRange(value.startIndex ..< value.endIndex, in: value)
        return regex.firstMatch(in: value, options: [], range: range) != nil
    }

    private static func extractWorkspaceAgentsIncludeURLs(
        from content: String,
        parentFileURL: URL,
        projectRootURL: URL,
        homeURL: URL?,
        includeExternal: Bool
    ) -> [URL] {
        let pattern = #"(?m)(^|[\s(])@([^\s<>()\[\]{}'\"]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }

        let nsRange = NSRange(content.startIndex ..< content.endIndex, in: content)
        let matches = regex.matches(in: content, options: [], range: nsRange)
        var includeURLs: [URL] = []
        var seenPaths = Set<String>()

        for match in matches {
            guard match.numberOfRanges >= 3,
                  let tokenRange = Range(match.range(at: 2), in: content)
            else {
                continue
            }

            let token = sanitizedIncludeToken(String(content[tokenRange]))
            guard isPotentialIncludeToken(token),
                  let includeURL = resolveIncludeURL(token, parentFileURL: parentFileURL, homeURL: homeURL),
                  isReadableTextIncludeURL(includeURL),
                  includeExternal || isWorkspaceAgentsIncludeURLAllowed(includeURL, projectRootURL: projectRootURL, homeURL: homeURL)
            else {
                continue
            }

            let path = includeURL.standardizedFileURL.path
            if seenPaths.insert(path).inserted {
                includeURLs.append(includeURL.standardizedFileURL)
            }
        }

        return includeURLs
    }

    private static func sanitizedIncludeToken(_ rawToken: String) -> String {
        var token = rawToken
        let trailingPunctuation = CharacterSet(charactersIn: ".,;:!?")
        while let lastScalar = token.unicodeScalars.last, trailingPunctuation.contains(lastScalar) {
            token.removeLast()
        }
        return token
    }

    private static func isPotentialIncludeToken(_ token: String) -> Bool {
        guard !token.isEmpty, !token.contains("@") else {
            return false
        }
        return token.hasPrefix("/")
            || token.hasPrefix("~/")
            || token.hasPrefix("./")
            || token.hasPrefix("../")
            || token.contains("/")
            || allowedWorkspaceAgentsIncludeExtensions.contains(URL(fileURLWithPath: token).pathExtension.lowercased())
    }

    private static func resolveIncludeURL(_ token: String, parentFileURL: URL, homeURL: URL?) -> URL? {
        if token.hasPrefix("~/") {
            return homeURL?.appendingPathComponent(String(token.dropFirst(2)), isDirectory: false).standardizedFileURL
        }
        if token.hasPrefix("/") {
            return URL(fileURLWithPath: token, isDirectory: false).standardizedFileURL
        }
        return parentFileURL.deletingLastPathComponent().appendingPathComponent(token, isDirectory: false).standardizedFileURL
    }

    private static func isReadableTextIncludeURL(_ fileURL: URL) -> Bool {
        let fileName = fileURL.lastPathComponent
        if fileName == workspaceAgentsFileName || fileName == localWorkspaceAgentsFileName {
            return true
        }
        let pathExtension = fileURL.pathExtension.lowercased()
        return !pathExtension.isEmpty && allowedWorkspaceAgentsIncludeExtensions.contains(pathExtension)
    }

    private static func isWorkspaceAgentsIncludeURLAllowed(_ fileURL: URL, projectRootURL: URL, homeURL: URL?) -> Bool {
        isPath(fileURL, inside: projectRootURL) || homeURL.map { isPath(fileURL, inside: $0) } == true
    }

    private static func displayName(for fileURL: URL, projectRootURL: URL, homeURL: URL?) -> String {
        if let relativeProjectPath = relativePath(for: fileURL, rootURL: projectRootURL) {
            return relativeProjectPath
        }
        if let homeURL, let relativeHomePath = relativePath(for: fileURL, rootURL: homeURL) {
            return "~/" + relativeHomePath
        }
        return fileURL.path
    }

    private static func relativePath(for fileURL: URL, rootURL: URL) -> String? {
        let filePath = fileURL.standardizedFileURL.path
        let rootPath = rootURL.standardizedFileURL.path
        guard filePath == rootPath || filePath.hasPrefix(rootPath + "/") else {
            return nil
        }
        if filePath == rootPath {
            return fileURL.lastPathComponent
        }
        return String(filePath.dropFirst(rootPath.count + 1))
    }

    private static func isPath(_ fileURL: URL, inside rootURL: URL) -> Bool {
        let filePath = fileURL.standardizedFileURL.path
        let rootPath = rootURL.standardizedFileURL.path
        return filePath == rootPath || filePath.hasPrefix(rootPath + "/")
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

    private static func loadDocument(
        fileName: String,
        from rootDirectory: URL,
        fileManager: FileManager
    ) -> LoadedDocument? {
        let fileURL = rootDirectory.appendingPathComponent(fileName, isDirectory: false)
        guard fileManager.fileExists(atPath: fileURL.path),
              let content = readTrimmedText(at: fileURL)
        else {
            return nil
        }

        return LoadedDocument(fileName: fileName, content: content, sourcePath: fileURL.standardizedFileURL.path)
    }

    private static func loadFirstAvailableDocument(
        fileNames: [String],
        from rootDirectory: URL,
        fileManager: FileManager
    ) -> LoadedDocument? {
        loadFirstAvailableDocument(fileNames: fileNames, from: [rootDirectory], fileManager: fileManager)
    }

    private static func loadFirstAvailableDocument(
        fileNames: [String],
        from rootDirectories: [URL],
        fileManager: FileManager
    ) -> LoadedDocument? {
        for rootDirectory in rootDirectories {
            for fileName in fileNames {
                if let document = loadDocument(fileName: fileName, from: rootDirectory, fileManager: fileManager) {
                    return document
                }
            }
        }
        return nil
    }

    private static func preferredRoots(for fileNames: [String], projectRootURL: URL, agentContextURL: URL) -> [URL] {
        let projectScopedFiles: Set<String> = [
            AgentContextDocumentKind.agents.fileName,
            AgentContextDocumentKind.heartbeat.fileName,
            AgentContextDocumentKind.tools.fileName,
        ]
        if fileNames.contains(where: { projectScopedFiles.contains($0) }) {
            return [projectRootURL, agentContextURL]
        }
        return [agentContextURL, projectRootURL]
    }

    private static func projectRootForAgentContextDirectory(_ rootDirectory: URL) -> URL? {
        let standardized = rootDirectory.standardizedFileURL
        guard standardized.deletingLastPathComponent().lastPathComponent == "agents",
              standardized.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == AgentStore.openAvaDirectoryName
        else {
            return nil
        }
        return standardized
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static func promptRootDirectory(workspaceRootURL: URL?, environment: [String: String]) -> URL? {
        if let workspaceRootURL {
            return workspaceRootURL
        }
        if let configuredPath = configuredRootPath(environment: environment) {
            return URL(fileURLWithPath: configuredPath, isDirectory: true)
        }
        return nil
    }

    private static func readTrimmedText(at fileURL: URL) -> String? {
        guard let data = try? Data(contentsOf: fileURL),
              let rawText = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return AppConfig.nonEmpty(rawText)
    }
}
