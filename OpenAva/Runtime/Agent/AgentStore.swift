import Foundation

enum OpenAvaID {
    enum Kind: String {
        case agent
        case model
        case team
    }

    private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    private static let suffixLength = 26

    static func generate(_ kind: Kind, date: Date = Date()) -> String {
        "\(kind.rawValue)_\(timeComponent(for: date))\(randomComponent(length: 16))"
    }

    static func isValid(_ id: String, kind: Kind) -> Bool {
        let prefix = "\(kind.rawValue)_"
        guard id.hasPrefix(prefix) else { return false }
        let suffix = String(id.dropFirst(prefix.count))
        return suffix.count == suffixLength && suffix.allSatisfy { alphabet.contains($0) }
    }

    private static func timeComponent(for date: Date) -> String {
        var value = UInt64(max(date.timeIntervalSince1970 * 1000, 0))
        var characters = Array(repeating: alphabet[0], count: 10)
        for index in stride(from: characters.count - 1, through: 0, by: -1) {
            characters[index] = alphabet[Int(value % 32)]
            value /= 32
        }
        return String(characters)
    }

    private static func randomComponent(length: Int) -> String {
        String((0 ..< length).map { _ in alphabet[Int.random(in: alphabet.indices)] })
    }
}

struct AgentProfile: Equatable, Identifiable {
    static let avatarFileName = "avatar.png"

    var id: String
    var name: String
    var emoji: String
    /// Shared project workspace used as the tool cwd.
    var workspacePath: String
    /// Agent-owned context root under `<workspace>/.openava/agents/<id>`.
    var localContextPath: String
    /// Per-agent selected LLM model identifier.
    var selectedModelID: String?
    /// Per-agent reasoning/thinking strength preference.
    var thinkingStrength: ChatThinkingStrength
    /// Raw Avatar field from IDENTITY.md. Descriptor details are derived on demand.
    var avatarIdentityValue: String?
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

    var avatarDescriptor: AgentAvatarDescriptor {
        AgentAvatarDefaults.descriptor(
            identityValue: avatarIdentityValue,
            name: name,
            emoji: emoji,
            contextURL: contextURL
        )
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
        id: String = OpenAvaID.generate(.agent),
        name: String,
        emoji: String,
        workspacePath: String,
        localContextPath: String,
        selectedModelID: String? = nil,
        thinkingStrength: ChatThinkingStrength = .medium,
        avatarIdentityValue: String? = nil,
        createdAtMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
        autoCompactEnabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.emoji = emoji
        self.workspacePath = workspacePath
        self.localContextPath = localContextPath
        self.selectedModelID = selectedModelID
        self.thinkingStrength = thinkingStrength
        self.avatarIdentityValue = AgentAvatarDefaults.normalizedIdentityValue(avatarIdentityValue)
        self.createdAtMs = createdAtMs
        self.autoCompactEnabled = autoCompactEnabled
    }
}

extension AgentProfile: Codable {
    private enum CodingKeys: String, CodingKey {
        case id
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = ""
        emoji = "🤖"
        workspacePath = ""
        localContextPath = ""
        selectedModelID = nil
        thinkingStrength = .medium
        avatarIdentityValue = nil
        createdAtMs = Int64(Date().timeIntervalSince1970 * 1000)
        autoCompactEnabled = true
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
    }
}

struct AgentStateSnapshot: Equatable {
    var agents: [AgentProfile]
    var activeAgentID: String?

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

    var activeAgentID: String?
    var user: OpenAvaUserDefaults?
    var teams: [TeamProfile]
    var toolPermissionRules: [ToolPermissionRule]

    init(
        activeAgentID: String? = nil,
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
        activeAgentID = try container.decodeIfPresent(String.self, forKey: .activeAgentID)
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
        avatarIdentityValue: String? = nil,
        vibe: String = "",
        fileManager: FileManager = .default,
        workspaceRootURL: URL? = nil
    ) throws -> AgentProfile {
        let rootURL = try resolvedWorkspaceRootDirectory(fileManager: fileManager, workspaceRootURL: workspaceRootURL)
        let state = load(fileManager: fileManager, workspaceRootURL: rootURL)
        let agentID = OpenAvaID.generate(.agent)
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
            localContextPath: contextURL.path,
            avatarIdentityValue: avatarIdentityValue
        )
        persistAgentMetadata(profile, fileManager: fileManager)
        try AgentTemplateWriter.writeAgentFile(
            at: contextURL,
            name: profile.name,
            emoji: profile.emoji,
            avatar: profile.avatarIdentityValue,
            vibe: vibe,
            fileManager: fileManager
        )

        if state.activeAgentID == nil {
            persistActiveAgentID(profile.id, fileManager: fileManager, workspaceRootURL: rootURL)
        }
        return profile
    }

    static func updateAgent(
        agentID: String,
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
            avatar: profile.avatarIdentityValue,
            fileManager: fileManager
        )
        persistAgentMetadata(profile, fileManager: fileManager)
        return profile
    }

    static func renameAgent(
        agentID: String,
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
        persistAgentMetadata(profile, fileManager: fileManager)
        return profile
    }

    @discardableResult
    static func setActiveAgent(
        _ agentID: String,
        fileManager: FileManager = .default,
        workspaceRootURL: URL? = nil
    ) -> Bool {
        let state = load(fileManager: fileManager, workspaceRootURL: workspaceRootURL)
        guard state.agents.contains(where: { $0.id == agentID }) else {
            return false
        }

        persistActiveAgentID(agentID, fileManager: fileManager, workspaceRootURL: workspaceRootURL)
        return true
    }

    @discardableResult
    static func deleteAgent(
        _ agentID: String,
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

        persistActiveAgentID(state.activeAgentID, fileManager: fileManager, workspaceRootURL: workspaceRootURL)

        // Best-effort cleanup for the deleted agent-owned support root only.
        // Never delete `workspaceURL`: it is the shared project workspace.
        if fileManager.fileExists(atPath: removed.contextURL.path) {
            try? fileManager.removeItem(at: removed.contextURL)
        }

        return true
    }

    @discardableResult
    static func setSelectedModel(
        _ selectedModelID: String?,
        for agentID: String,
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
    static func setThinkingStrength(
        _ thinkingStrength: ChatThinkingStrength,
        for agentID: String,
        fileManager: FileManager = .default,
        workspaceRootURL: URL? = nil
    ) -> Bool {
        var state = load(fileManager: fileManager, workspaceRootURL: workspaceRootURL)
        guard let index = state.agents.firstIndex(where: { $0.id == agentID }) else {
            return false
        }

        state.agents[index].thinkingStrength = thinkingStrength
        persistAgentMetadata(state.agents[index], fileManager: fileManager)
        return true
    }

    @discardableResult
    static func setAutoCompact(
        _ enabled: Bool,
        for agentID: String,
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
        afterDeleting deletedModelID: String,
        replacement: String?,
        fileManager: FileManager = .default,
        workspaceRootURL: URL? = nil
    ) {
        var state = load(fileManager: fileManager, workspaceRootURL: workspaceRootURL)

        for index in state.agents.indices where state.agents[index].selectedModelID == deletedModelID {
            state.agents[index].selectedModelID = replacement
            persistAgentMetadata(state.agents[index], fileManager: fileManager)
        }
    }

    private static func persistActiveAgentID(
        _ activeAgentID: String?,
        fileManager: FileManager,
        workspaceRootURL: URL?
    ) {
        var payload = OpenAvaProjectFile.load(fileManager: fileManager, workspaceRootURL: workspaceRootURL)
            ?? OpenAvaProjectState()
        payload.activeAgentID = activeAgentID
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

    static func agentContextDirectory(for agentID: String, workspaceRootURL: URL) -> URL {
        agentsRootDirectory(workspaceRootURL: workspaceRootURL)
            .appendingPathComponent(agentID, isDirectory: true)
    }

    private static func loadAgentMetadata(agentID: String, workspaceRootURL: URL) -> ChatContextMetadata? {
        ChatContextMetadata.load(from: agentContextDirectory(for: agentID, workspaceRootURL: workspaceRootURL))
    }

    private static func persistAgentMetadata(_ profile: AgentProfile, fileManager: FileManager) {
        let metadata = ChatContextMetadata(
            selectedModelID: profile.selectedModelID,
            thinkingStrength: profile.thinkingStrength,
            createdAt: Date(timeIntervalSince1970: TimeInterval(profile.createdAtMs) / 1000),
            updatedAt: Date(),
            autoCompactEnabled: profile.autoCompactEnabled
        )
        ChatContextMetadata.persist(metadata, to: profile.contextURL, fileManager: fileManager)
    }

    private static func scanAgentDirectories(
        workspaceRootURL: URL,
        fileManager: FileManager
    ) -> [AgentProfile] {
        let agentsRootURL = agentsRootDirectory(workspaceRootURL: workspaceRootURL)
        guard let directoryURLs = try? fileManager.contentsOfDirectory(
            at: agentsRootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return directoryURLs.compactMap { directoryURL -> AgentProfile? in
            let resourceValues = try? directoryURL.resourceValues(forKeys: [.isDirectoryKey])
            guard resourceValues?.isDirectory == true,
                  OpenAvaID.isValid(directoryURL.lastPathComponent, kind: .agent)
            else {
                return nil
            }
            let agentID = directoryURL.lastPathComponent

            let identityURL = directoryURL.appendingPathComponent(AgentContextDocumentKind.identity.fileName, isDirectory: false)
            guard let agentMetadata = loadAgentMetadata(agentID: agentID, workspaceRootURL: workspaceRootURL),
                  let identity = identityMetadata(at: identityURL),
                  let name = identity.name
            else {
                return nil
            }
            let emoji = identity.emoji ?? "🤖"

            return AgentProfile(
                id: agentID,
                name: normalizedName(name),
                emoji: normalizedEmoji(emoji),
                workspacePath: workspaceRootURL.standardizedFileURL.path,
                localContextPath: directoryURL.standardizedFileURL.path,
                selectedModelID: agentMetadata.selectedModelID,
                thinkingStrength: agentMetadata.thinkingStrength,
                avatarIdentityValue: identity.avatar,
                createdAtMs: Int64(agentMetadata.createdAt.timeIntervalSince1970 * 1000),
                autoCompactEnabled: agentMetadata.autoCompactEnabled
            )
        }
        .sorted { lhs, rhs in
            if lhs.createdAtMs != rhs.createdAtMs {
                return lhs.createdAtMs < rhs.createdAtMs
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private struct IdentityMetadata {
        var name: String?
        var emoji: String?
        var avatar: String?
    }

    private static func identityMetadata(at identityURL: URL) -> IdentityMetadata? {
        guard let data = try? Data(contentsOf: identityURL),
              let content = String(data: data, encoding: .utf8)
        else {
            return nil
        }

        return IdentityMetadata(
            name: AgentTemplateWriter.identityFieldValue(named: "Name", in: content),
            emoji: AgentTemplateWriter.identityFieldValue(named: "Emoji", in: content),
            avatar: AgentTemplateWriter.identityFieldValue(named: "Avatar", in: content)
        )
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
