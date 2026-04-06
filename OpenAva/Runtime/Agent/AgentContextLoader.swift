import Foundation

enum AgentContextDocumentKind: CaseIterable, Identifiable {
    case agents
    case heartbeat
    case soul
    case tools
    case identity
    case user

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
    }

    /// Bootstrap order aligned with workspace prompt assembly.
    /// Each nested array is a priority group where the first existing file wins.
    private static let bootstrapDocumentFileGroups: [[String]] = [
        ["AGENTS.md"],
        ["HEARTBEAT.md"],
        ["SOUL.md"],
        ["TOOLS.md"],
        ["IDENTITY.md"],
        ["USER.md"],
    ]

    private static let rootEnvironmentKeys = [
        "ICLAW_AGENT_CONTEXT_DIR",
        "ICLAW_WORKSPACE_DIR",
        "PWD",
    ]

    /// Compose system prompt by loading context and delegating to AgentPromptBuilder.
    static func composeSystemPrompt(
        baseSystemPrompt: String?,
        memoryContext: String? = nil,
        workspaceRootURL: URL? = nil,
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

        // Build skills context from workspace and built-in skill directories.
        let skillCatalog = AgentSkillsLoader.buildSkillCatalog(
            visibility: .modelInvocable,
            workspaceRootURL: rootDirectory,
            environment: environment,
            fileManager: fileManager
        )

        let prompt = AgentPromptBuilder.composeSystemPrompt(
            baseSystemPrompt: basePrompt,
            context: context,
            skillCatalog: skillCatalog,
            memoryContext: memoryContext,
            rootDirectory: rootDirectory
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
        return load(from: rootDirectory, fileManager: fileManager)
    }

    /// Load context documents from specified root directory.
    static func load(from rootDirectory: URL, fileManager: FileManager = .default) -> LoadedContext? {
        let documents = bootstrapDocumentFileGroups.compactMap { fileNames in
            loadFirstAvailableDocument(fileNames: fileNames, from: rootDirectory, fileManager: fileManager)
        }

        guard !documents.isEmpty else {
            return nil
        }
        return LoadedContext(documents: documents)
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

        return LoadedDocument(fileName: fileName, content: content)
    }

    private static func loadFirstAvailableDocument(
        fileNames: [String],
        from rootDirectory: URL,
        fileManager: FileManager
    ) -> LoadedDocument? {
        for fileName in fileNames {
            if let document = loadDocument(fileName: fileName, from: rootDirectory, fileManager: fileManager) {
                return document
            }
        }
        return nil
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
