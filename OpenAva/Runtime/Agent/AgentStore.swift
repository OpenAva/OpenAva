import Foundation

struct AgentProfile: Equatable, Identifiable {
    static let avatarFileName = ".avatar"

    var id: UUID
    var name: String
    var emoji: String
    /// Shared project workspace used as the tool cwd.
    var workspacePath: String
    /// Agent-owned context root under `<workspace>/.openava/agents/<id>`.
    var localContextPath: String
    /// Per-agent selected LLM model identifier.
    var selectedModelID: UUID?
    var createdAtMs: Int64
    /// Whether to automatically compact context when nearing the context window limit.
    var autoCompactEnabled: Bool

    var workspaceURL: URL {
        AgentProfile.resolveSandboxPath(workspacePath, isDirectory: true)
    }

    /// Agent-specific context and metadata directory. User-visible project files stay in `workspaceURL`.
    var contextURL: URL {
        AgentProfile.resolveSandboxPath(localContextPath, isDirectory: true)
    }

    var avatarURL: URL {
        contextURL.appendingPathComponent(Self.avatarFileName, isDirectory: false)
    }

    /// Rebases a persisted sandbox-absolute path onto the current iOS app container.
    ///
    /// iOS may change the Data container UUID in `/var/mobile/Containers/Data/Application/<UUID>/`
    /// across reinstalls or upgrades, which leaves previously-stored absolute paths pointing
    /// outside the sandbox. In that case, the stored path is rewritten by replacing the tail
    /// after `Documents/` onto the current Documents directory, so reads and writes succeed.
    /// Paths that already exist (or are not recognizable sandbox paths) are returned unchanged.
    static func resolveSandboxPath(_ rawPath: String, isDirectory: Bool) -> URL {
        let originalURL = URL(fileURLWithPath: rawPath, isDirectory: isDirectory)
        #if os(iOS) && !targetEnvironment(macCatalyst)
            let fileManager = FileManager.default
            if fileManager.fileExists(atPath: originalURL.path) {
                return originalURL
            }
            guard let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
                return originalURL
            }
            let marker = "/Documents/"
            if let range = rawPath.range(of: marker) {
                let tail = String(rawPath[range.upperBound...])
                guard !tail.isEmpty else { return originalURL }
                return documentsURL.appendingPathComponent(tail, isDirectory: isDirectory)
            }
            return originalURL
        #else
            return originalURL
        #endif
    }

    init(
        id: UUID = UUID(),
        name: String,
        emoji: String,
        workspacePath: String,
        localContextPath: String,
        selectedModelID: UUID? = nil,
        createdAtMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
        autoCompactEnabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.emoji = emoji
        self.workspacePath = workspacePath
        self.localContextPath = localContextPath
        self.selectedModelID = selectedModelID
        self.createdAtMs = createdAtMs
        self.autoCompactEnabled = autoCompactEnabled
    }
}

extension AgentProfile: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, name, emoji, workspacePath, localContextPath
        case selectedModelID, createdAtMs
        case autoCompactEnabled
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        emoji = try c.decode(String.self, forKey: .emoji)
        workspacePath = try c.decode(String.self, forKey: .workspacePath)
        localContextPath = try c.decode(String.self, forKey: .localContextPath)
        selectedModelID = try c.decodeIfPresent(UUID.self, forKey: .selectedModelID)
        createdAtMs = try c.decode(Int64.self, forKey: .createdAtMs)
        autoCompactEnabled = try c.decodeIfPresent(Bool.self, forKey: .autoCompactEnabled) ?? true
    }
}

struct AgentStateSnapshot: Equatable {
    var agents: [AgentProfile]
    var activeAgentID: UUID?

    var activeAgent: AgentProfile? {
        guard let activeAgentID else { return nil }
        return agents.first(where: { $0.id == activeAgentID })
    }

    var hasAgent: Bool {
        !agents.isEmpty
    }
}

struct OpenAvaUserDefaults: Codable, Equatable {
    var callName: String
    var context: String
}

struct OpenAvaProjectState: Codable {
    private enum CodingKeys: String, CodingKey {
        case activeAgentID
        case user
        case teams
        case toolPermissionRules
    }

    var activeAgentID: UUID?
    var user: OpenAvaUserDefaults?
    var teams: [TeamProfile]
    var toolPermissionRules: [ToolPermissionRule]

    init(
        activeAgentID: UUID? = nil,
        user: OpenAvaUserDefaults? = nil,
        teams: [TeamProfile] = [],
        toolPermissionRules: [ToolPermissionRule] = []
    ) {
        self.activeAgentID = activeAgentID
        self.user = user
        self.teams = teams
        self.toolPermissionRules = toolPermissionRules
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        activeAgentID = try container.decodeIfPresent(UUID.self, forKey: .activeAgentID)
        user = try container.decodeIfPresent(OpenAvaUserDefaults.self, forKey: .user)
        teams = try container.decodeIfPresent([TeamProfile].self, forKey: .teams) ?? []
        toolPermissionRules = try container.decodeIfPresent([ToolPermissionRule].self, forKey: .toolPermissionRules) ?? []
    }
}

enum OpenAvaProjectFile {
    private static let fileName = "project.json"

    private static let iso8601WithFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func load(
        fileManager: FileManager = .default,
        workspaceRootURL: URL? = nil
    ) -> OpenAvaProjectState? {
        guard let url = fileURL(fileManager: fileManager, workspaceRootURL: workspaceRootURL),
              let data = try? Data(contentsOf: url)
        else {
            return nil
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            if let date = iso8601WithFractionalSeconds.date(from: value) {
                return date
            }
            if let date = iso8601.date(from: value) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported team date format"
            )
        }
        return try? decoder.decode(OpenAvaProjectState.self, from: data)
    }

    static func persist(
        _ projectState: OpenAvaProjectState,
        fileManager: FileManager = .default,
        workspaceRootURL: URL? = nil
    ) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(iso8601WithFractionalSeconds.string(from: date))
        }

        guard let url = fileURL(fileManager: fileManager, workspaceRootURL: workspaceRootURL),
              let data = try? encoder.encode(projectState)
        else {
            return
        }

        try? data.write(to: url, options: [.atomic])
    }

    static func fileURL(fileManager: FileManager = .default, workspaceRootURL: URL? = nil) -> URL? {
        let rootURL: URL
        if let workspaceRootURL {
            rootURL = workspaceRootURL.standardizedFileURL
            try? fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        } else {
            guard let resolved = try? AgentStore.workspaceRootDirectory(fileManager: fileManager) else {
                return nil
            }
            rootURL = resolved
        }
        let supportURL = AgentStore.supportDirectoryURL(workspaceRootURL: rootURL)
        try? fileManager.createDirectory(at: supportURL, withIntermediateDirectories: true)
        return supportURL.appendingPathComponent(fileName, isDirectory: false)
    }
}

enum AgentStore {
    static let openAvaDirectoryName = ".openava"
    private static let agentsDirectoryName = "agents"
    private static let agentMetadataFileName = "metadata.json"

    typealias UserDefaults = OpenAvaUserDefaults

    static func load(
        fileManager: FileManager = .default,
        workspaceRootURL: URL? = nil
    ) -> AgentStateSnapshot {
        guard let rootURL = try? resolvedWorkspaceRootDirectory(fileManager: fileManager, workspaceRootURL: workspaceRootURL) else {
            return AgentStateSnapshot(agents: [], activeAgentID: nil)
        }

        var projectState = OpenAvaProjectFile.load(fileManager: fileManager, workspaceRootURL: rootURL) ?? OpenAvaProjectState()
        let agents = scanAgentDirectories(
            workspaceRootURL: rootURL,
            fileManager: fileManager
        )

        var didChange = false
        var activeAgentID = projectState.activeAgentID
        if let selectedActiveAgentID = activeAgentID,
           !agents.contains(where: { $0.id == selectedActiveAgentID })
        {
            activeAgentID = agents.first?.id
        } else if activeAgentID == nil {
            activeAgentID = agents.first?.id
        }

        if activeAgentID != projectState.activeAgentID {
            projectState.activeAgentID = activeAgentID
            didChange = true
        }

        if didChange {
            OpenAvaProjectFile.persist(projectState, fileManager: fileManager, workspaceRootURL: rootURL)
        }

        return AgentStateSnapshot(
            agents: agents,
            activeAgentID: activeAgentID
        )
    }

    static func loadUser(
        fileManager: FileManager = .default,
        workspaceRootURL: URL? = nil
    ) -> UserDefaults? {
        OpenAvaProjectFile.load(fileManager: fileManager, workspaceRootURL: workspaceRootURL)?.user
    }

    static func saveUser(
        callName: String,
        context: String,
        fileManager: FileManager = .default,
        workspaceRootURL: URL? = nil
    ) {
        let normalizedCallName = callName.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedContext = context.trimmingCharacters(in: .whitespacesAndNewlines)

        var payload = OpenAvaProjectFile.load(fileManager: fileManager, workspaceRootURL: workspaceRootURL)
            ?? OpenAvaProjectState()

        if normalizedCallName.isEmpty, normalizedContext.isEmpty {
            payload.user = nil
        } else {
            payload.user = UserDefaults(
                callName: normalizedCallName,
                context: normalizedContext
            )
        }

        OpenAvaProjectFile.persist(payload, fileManager: fileManager, workspaceRootURL: workspaceRootURL)
    }

    static func loadToolPermissionRules(
        fileManager: FileManager = .default,
        workspaceRootURL: URL? = nil
    ) -> [ToolPermissionRule] {
        OpenAvaProjectFile.load(fileManager: fileManager, workspaceRootURL: workspaceRootURL)?.toolPermissionRules.map { rule in
            ToolPermissionRule(
                id: rule.id,
                behavior: rule.behavior,
                scope: .project,
                toolName: rule.toolName,
                matcher: rule.matcher,
                createdAt: rule.createdAt
            )
        } ?? []
    }

    static func saveToolPermissionRules(
        _ rules: [ToolPermissionRule],
        fileManager: FileManager = .default,
        workspaceRootURL: URL? = nil
    ) {
        var payload = OpenAvaProjectFile.load(fileManager: fileManager, workspaceRootURL: workspaceRootURL)
            ?? OpenAvaProjectState()
        payload.toolPermissionRules = normalizedProjectToolPermissionRules(rules)
        OpenAvaProjectFile.persist(payload, fileManager: fileManager, workspaceRootURL: workspaceRootURL)
    }

    private static func normalizedProjectToolPermissionRules(_ rules: [ToolPermissionRule]) -> [ToolPermissionRule] {
        var result: [ToolPermissionRule] = []
        for rule in rules {
            let projectRule = ToolPermissionRule(
                id: rule.id,
                behavior: rule.behavior,
                scope: .project,
                toolName: rule.toolName,
                matcher: rule.matcher,
                createdAt: rule.createdAt
            )
            result.removeAll { existing in
                existing.toolName == projectRule.toolName && existing.matcher == projectRule.matcher
            }
            result.append(projectRule)
        }
        return result
    }

    static func createAgent(
        name: String,
        emoji: String,
        fileManager: FileManager = .default,
        workspaceRootURL: URL? = nil
    ) throws -> AgentProfile {
        let rootURL = try resolvedWorkspaceRootDirectory(fileManager: fileManager, workspaceRootURL: workspaceRootURL)
        var state = load(fileManager: fileManager, workspaceRootURL: rootURL)
        let agentID = UUID()
        let normalizedAgentName = normalizedName(name)
        let workspaceURL = rootURL
        let contextURL = agentContextDirectory(for: agentID, workspaceRootURL: rootURL)

        try fileManager.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: contextURL, withIntermediateDirectories: true)

        let profile = AgentProfile(
            id: agentID,
            name: normalizedAgentName,
            emoji: normalizedEmoji(emoji),
            workspacePath: workspaceURL.path,
            localContextPath: contextURL.path
        )
        persistAgentMetadata(profile, fileManager: fileManager)
        try AgentTemplateWriter.writeAgentFile(
            at: contextURL,
            name: profile.name,
            emoji: profile.emoji,
            fileManager: fileManager
        )

        state.agents.append(profile)
        if state.activeAgentID == nil {
            state.activeAgentID = profile.id
        }
        persist(state: state, fileManager: fileManager, workspaceRootURL: rootURL)
        return profile
    }

    static func updateAgent(
        agentID: UUID,
        name: String,
        emoji: String,
        fileManager: FileManager = .default,
        workspaceRootURL: URL? = nil
    ) -> AgentProfile? {
        var state = load(fileManager: fileManager, workspaceRootURL: workspaceRootURL)
        guard let index = state.agents.firstIndex(where: { $0.id == agentID }) else {
            return nil
        }

        state.agents[index].name = normalizedName(name)
        state.agents[index].emoji = normalizedEmoji(emoji)
        let profile = state.agents[index]
        try? AgentTemplateWriter.syncIdentityProfile(
            at: profile.contextURL,
            name: profile.name,
            emoji: profile.emoji,
            fileManager: fileManager
        )
        persist(state: state, fileManager: fileManager, workspaceRootURL: workspaceRootURL)
        return profile
    }

    static func renameAgent(
        agentID: UUID,
        name: String,
        fileManager: FileManager = .default,
        workspaceRootURL: URL? = nil
    ) -> AgentProfile? {
        guard let rootURL = try? resolvedWorkspaceRootDirectory(fileManager: fileManager, workspaceRootURL: workspaceRootURL) else {
            return nil
        }
        var state = load(fileManager: fileManager, workspaceRootURL: rootURL)
        guard let index = state.agents.firstIndex(where: { $0.id == agentID }) else {
            return nil
        }

        let normalizedAgentName = normalizedName(name)
        let workspaceURL = rootURL
        let contextURL = agentContextDirectory(for: agentID, workspaceRootURL: rootURL)

        // Renaming an agent must not rename or move the shared project workspace.
        try? fileManager.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: contextURL, withIntermediateDirectories: true)

        state.agents[index].name = normalizedAgentName
        state.agents[index].workspacePath = workspaceURL.path
        state.agents[index].localContextPath = contextURL.path

        let profile = state.agents[index]
        try? AgentTemplateWriter.syncIdentityName(
            at: contextURL,
            name: profile.name,
            fileManager: fileManager
        )
        persist(state: state, fileManager: fileManager, workspaceRootURL: rootURL)
        return profile
    }

    @discardableResult
    static func setActiveAgent(
        _ agentID: UUID,
        fileManager: FileManager = .default,
        workspaceRootURL: URL? = nil
    ) -> Bool {
        var state = load(fileManager: fileManager, workspaceRootURL: workspaceRootURL)
        guard state.agents.contains(where: { $0.id == agentID }) else {
            return false
        }

        state.activeAgentID = agentID
        persist(state: state, fileManager: fileManager, workspaceRootURL: workspaceRootURL)
        return true
    }

    @discardableResult
    static func deleteAgent(
        _ agentID: UUID,
        fileManager: FileManager = .default,
        workspaceRootURL: URL? = nil
    ) -> Bool {
        var state = load(fileManager: fileManager, workspaceRootURL: workspaceRootURL)
        guard let index = state.agents.firstIndex(where: { $0.id == agentID }) else {
            return false
        }

        let removed = state.agents.remove(at: index)

        // Keep active agent valid after deletion.
        if state.activeAgentID == agentID || !state.agents.contains(where: { $0.id == state.activeAgentID }) {
            state.activeAgentID = state.agents.first?.id
        }

        persist(state: state, fileManager: fileManager, workspaceRootURL: workspaceRootURL)

        // Best-effort cleanup for the deleted agent-owned support root only.
        // Never delete `workspaceURL`: it is the shared project workspace.
        if fileManager.fileExists(atPath: removed.contextURL.path) {
            try? fileManager.removeItem(at: removed.contextURL)
        }

        return true
    }

    @discardableResult
    static func setSelectedModel(
        _ selectedModelID: UUID?,
        for agentID: UUID,
        fileManager: FileManager = .default,
        workspaceRootURL: URL? = nil
    ) -> Bool {
        var state = load(fileManager: fileManager, workspaceRootURL: workspaceRootURL)
        guard let index = state.agents.firstIndex(where: { $0.id == agentID }) else {
            return false
        }

        state.agents[index].selectedModelID = selectedModelID
        persistAgentMetadata(state.agents[index], fileManager: fileManager)
        return true
    }

    @discardableResult
    static func setAutoCompact(
        _ enabled: Bool,
        for agentID: UUID,
        fileManager: FileManager = .default,
        workspaceRootURL: URL? = nil
    ) -> Bool {
        var state = load(fileManager: fileManager, workspaceRootURL: workspaceRootURL)
        guard let index = state.agents.firstIndex(where: { $0.id == agentID }) else {
            return false
        }

        state.agents[index].autoCompactEnabled = enabled
        persistAgentMetadata(state.agents[index], fileManager: fileManager)
        return true
    }

    /// Repair per-agent selections after a model is deleted.
    static func repairSelectedModel(
        afterDeleting deletedModelID: UUID,
        replacement: UUID?,
        fileManager: FileManager = .default,
        workspaceRootURL: URL? = nil
    ) {
        var state = load(fileManager: fileManager, workspaceRootURL: workspaceRootURL)

        for index in state.agents.indices where state.agents[index].selectedModelID == deletedModelID {
            state.agents[index].selectedModelID = replacement
            persistAgentMetadata(state.agents[index], fileManager: fileManager)
        }
    }

    private static func persist(
        state: AgentStateSnapshot,
        fileManager: FileManager,
        workspaceRootURL: URL?
    ) {
        var payload = OpenAvaProjectFile.load(fileManager: fileManager, workspaceRootURL: workspaceRootURL)
            ?? OpenAvaProjectState()
        payload.activeAgentID = state.activeAgentID
        OpenAvaProjectFile.persist(payload, fileManager: fileManager, workspaceRootURL: workspaceRootURL)
    }

    static func workspaceRootDirectory(fileManager: FileManager) throws -> URL {
        guard let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw NSError(
                domain: "AgentStore",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Documents directory unavailable"]
            )
        }
        let rootURL = documentsURL.appendingPathComponent("OpenAva", isDirectory: true)
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        return rootURL
    }

    /// Returns the project support root used by durable memories.
    /// Durable memories live at `<workspace>/.openava/memory/`.
    static func memorySupportRootURL(fileManager: FileManager = .default, workspaceRootURL: URL? = nil) -> URL {
        let workspaceRoot = (try? resolvedWorkspaceRootDirectory(fileManager: fileManager, workspaceRootURL: workspaceRootURL))
            ?? fileManager.temporaryDirectory.appendingPathComponent("OpenAva", isDirectory: true)
        return supportDirectoryURL(workspaceRootURL: workspaceRoot)
    }

    static func supportDirectoryURL(workspaceRootURL: URL) -> URL {
        workspaceRootURL.appendingPathComponent(openAvaDirectoryName, isDirectory: true)
    }

    private static func agentsRootDirectory(workspaceRootURL: URL) -> URL {
        supportDirectoryURL(workspaceRootURL: workspaceRootURL)
            .appendingPathComponent(agentsDirectoryName, isDirectory: true)
    }

    static func agentContextDirectory(for agentID: UUID, workspaceRootURL: URL) -> URL {
        agentsRootDirectory(workspaceRootURL: workspaceRootURL)
            .appendingPathComponent(agentID.uuidString, isDirectory: true)
    }

    private struct IdentityMetadata {
        var name: String?
        var emoji: String?
    }

    private struct AgentMetadata: Codable {
        var selectedModelID: UUID?
        var createdAtMs: Int64
        var autoCompactEnabled: Bool
    }

    private static func agentMetadataURL(for agentID: UUID, workspaceRootURL: URL) -> URL {
        agentContextDirectory(for: agentID, workspaceRootURL: workspaceRootURL)
            .appendingPathComponent(agentMetadataFileName, isDirectory: false)
    }

    private static func loadAgentMetadata(agentID: UUID, workspaceRootURL: URL) -> AgentMetadata? {
        let url = agentMetadataURL(for: agentID, workspaceRootURL: workspaceRootURL)
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try? JSONDecoder().decode(AgentMetadata.self, from: data)
    }

    private static func persistAgentMetadata(_ profile: AgentProfile, fileManager: FileManager) {
        let metadata = AgentMetadata(
            selectedModelID: profile.selectedModelID,
            createdAtMs: profile.createdAtMs,
            autoCompactEnabled: profile.autoCompactEnabled
        )
        let url = profile.contextURL.appendingPathComponent(agentMetadataFileName, isDirectory: false)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(metadata) else {
            return
        }
        try? fileManager.createDirectory(at: profile.contextURL, withIntermediateDirectories: true)
        try? data.write(to: url, options: [.atomic])
    }

    private static func scanAgentDirectories(
        workspaceRootURL: URL,
        fileManager: FileManager
    ) -> [AgentProfile] {
        let agentsRootURL = agentsRootDirectory(workspaceRootURL: workspaceRootURL)
        guard let directoryURLs = try? fileManager.contentsOfDirectory(
            at: agentsRootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .creationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return directoryURLs.compactMap { directoryURL -> AgentProfile? in
            let resourceValues = try? directoryURL.resourceValues(forKeys: [.isDirectoryKey, .creationDateKey])
            guard resourceValues?.isDirectory == true,
                  let agentID = UUID(uuidString: directoryURL.lastPathComponent)
            else {
                return nil
            }

            let identityURL = directoryURL.appendingPathComponent(AgentContextDocumentKind.identity.fileName, isDirectory: false)
            guard fileManager.fileExists(atPath: identityURL.path) else {
                return nil
            }

            let identityMetadata = identityMetadata(at: identityURL)
            let agentMetadata = loadAgentMetadata(agentID: agentID, workspaceRootURL: workspaceRootURL)
            let createdAtMs = agentMetadata?.createdAtMs
                ?? Int64((resourceValues?.creationDate ?? Date()).timeIntervalSince1970 * 1000)

            return AgentProfile(
                id: agentID,
                name: normalizedName(identityMetadata.name ?? "Agent"),
                emoji: normalizedEmoji(identityMetadata.emoji ?? "🤖"),
                workspacePath: workspaceRootURL.standardizedFileURL.path,
                localContextPath: directoryURL.standardizedFileURL.path,
                selectedModelID: agentMetadata?.selectedModelID,
                createdAtMs: createdAtMs,
                autoCompactEnabled: agentMetadata?.autoCompactEnabled ?? true
            )
        }
        .sorted { lhs, rhs in
            if lhs.createdAtMs != rhs.createdAtMs {
                return lhs.createdAtMs < rhs.createdAtMs
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private static func identityMetadata(at identityURL: URL) -> IdentityMetadata {
        guard let data = try? Data(contentsOf: identityURL),
              let content = String(data: data, encoding: .utf8)
        else {
            return IdentityMetadata()
        }

        return IdentityMetadata(
            name: markdownFieldValue(named: "Name", in: content),
            emoji: markdownFieldValue(named: "Emoji", in: content)
        )
    }

    private static func markdownFieldValue(named fieldName: String, in content: String) -> String? {
        let marker = "- **\(fieldName):**"
        let lines = content.components(separatedBy: "\n")
        guard let markerIndex = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == marker }) else {
            return nil
        }

        var valueLines: [String] = []
        var index = markerIndex + 1
        while index < lines.count {
            let line = lines[index]
            guard line.hasPrefix("  ") else { break }
            valueLines.append(String(line.dropFirst(2)))
            index += 1
        }

        let value = valueLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.hasPrefix("_(") else {
            return nil
        }
        return value
    }

    private static func resolvedWorkspaceRootDirectory(
        fileManager: FileManager,
        workspaceRootURL: URL?
    ) throws -> URL {
        let rootURL: URL
        if let workspaceRootURL {
            rootURL = workspaceRootURL.standardizedFileURL
        } else {
            rootURL = try workspaceRootDirectory(fileManager: fileManager)
        }
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        return rootURL
    }

    private static func nextWorkspaceDirectory(
        for agentName: String,
        rootURL: URL,
        usedWorkspacePaths: inout Set<String>
    ) throws -> URL {
        let baseName = sanitizedWorkspaceDirectoryName(agentName)
        var suffix = 1

        while true {
            let directoryName = suffix == 1 ? baseName : "\(baseName)-\(suffix)"
            let candidateURL = rootURL.appendingPathComponent(directoryName, isDirectory: true)
            let candidatePath = candidateURL.standardizedFileURL.path
            if !usedWorkspacePaths.contains(candidatePath) {
                usedWorkspacePaths.insert(candidatePath)
                return candidateURL
            }
            suffix += 1
        }
    }

    private static func sanitizedWorkspaceDirectoryName(_ rawName: String) -> String {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Agent" }

        let illegalCharacters = CharacterSet(charactersIn: "/:\\?%*|\"<>")
            .union(.controlCharacters)
        let mappedScalars = trimmed.unicodeScalars.map { scalar -> UnicodeScalar in
            illegalCharacters.contains(scalar) ? "_" : scalar
        }
        let sanitized = String(String.UnicodeScalarView(mappedScalars))
            .trimmingCharacters(in: CharacterSet(charactersIn: " ."))

        return sanitized.isEmpty ? "Agent" : sanitized
    }

    private static func normalizedName(_ value: String) -> String {
        nonEmpty(value) ?? "Agent"
    }

    private static func normalizedEmoji(_ value: String) -> String {
        nonEmpty(value) ?? "🤖"
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
