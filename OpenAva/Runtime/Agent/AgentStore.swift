import Foundation

struct AgentProfile: Equatable, Identifiable {
    var id: UUID
    var name: String
    var emoji: String
    var workspacePath: String
    var localRuntimePath: String
    /// Per-agent selected LLM model identifier.
    var selectedModelID: UUID?
    /// Per-agent selected chat session key.
    var selectedSessionKey: String?
    var createdAtMs: Int64
    /// Whether to automatically compact context when nearing the context window limit.
    var autoCompactEnabled: Bool

    var workspaceURL: URL {
        URL(fileURLWithPath: workspacePath, isDirectory: true)
    }

    var runtimeURL: URL {
        URL(fileURLWithPath: localRuntimePath, isDirectory: true)
    }

    init(
        id: UUID = UUID(),
        name: String,
        emoji: String,
        workspacePath: String,
        localRuntimePath: String,
        selectedModelID: UUID? = nil,
        selectedSessionKey: String? = nil,
        createdAtMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
        autoCompactEnabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.emoji = emoji
        self.workspacePath = workspacePath
        self.localRuntimePath = localRuntimePath
        self.selectedModelID = selectedModelID
        self.selectedSessionKey = selectedSessionKey
        self.createdAtMs = createdAtMs
        self.autoCompactEnabled = autoCompactEnabled
    }
}

extension AgentProfile: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, name, emoji, workspacePath, localRuntimePath
        case selectedModelID, selectedSessionKey, createdAtMs
        case autoCompactEnabled
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        emoji = try c.decode(String.self, forKey: .emoji)
        workspacePath = try c.decode(String.self, forKey: .workspacePath)
        localRuntimePath = try c.decode(String.self, forKey: .localRuntimePath)
        selectedModelID = try c.decodeIfPresent(UUID.self, forKey: .selectedModelID)
        selectedSessionKey = try c.decodeIfPresent(String.self, forKey: .selectedSessionKey)
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

enum AgentStore {
    private struct PersistedState: Codable {
        var version: Int
        var agents: [AgentProfile]
        var activeAgentID: UUID?
    }

    private enum DefaultsKey {
        static let state = "agent.state.v1"
    }

    static func load(
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) -> AgentStateSnapshot {
        guard let data = defaults.data(forKey: DefaultsKey.state),
              let decoded = try? JSONDecoder().decode(PersistedState.self, from: data),
              decoded.version == 1
        else {
            return AgentStateSnapshot(agents: [], activeAgentID: nil)
        }

        // Keep paths canonical so each agent always maps to
        // Documents/<agent-name> for workspace and
        // Documents/<agent-name>/.runtime for runtime state.
        var agents = decoded.agents
        var didNormalizePaths = false
        var usedWorkspacePaths: Set<String> = []
        for index in agents.indices {
            let normalized = normalizedStoragePaths(
                for: agents[index],
                usedWorkspacePaths: &usedWorkspacePaths,
                fileManager: fileManager
            )
            if normalized.workspacePath != agents[index].workspacePath ||
                normalized.localRuntimePath != agents[index].localRuntimePath
            {
                didNormalizePaths = true
            }
            agents[index] = normalized
        }

        var activeAgentID = decoded.activeAgentID
        if let selectedActiveAgentID = activeAgentID,
           !agents.contains(where: { $0.id == selectedActiveAgentID })
        {
            activeAgentID = agents.first?.id
        }

        if didNormalizePaths || activeAgentID != decoded.activeAgentID {
            persist(
                state: AgentStateSnapshot(
                    agents: agents,
                    activeAgentID: activeAgentID
                ),
                defaults: defaults
            )
        }

        // Remove legacy Documents/OpenAva container after migration if it is empty.
        cleanupLegacyWorkspaceRootIfEmpty(fileManager: fileManager)

        return AgentStateSnapshot(
            agents: agents,
            activeAgentID: activeAgentID
        )
    }

    static func createAgent(
        name: String,
        emoji: String,
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) throws -> AgentProfile {
        var state = load(defaults: defaults)
        let agentID = UUID()
        let normalizedAgentName = normalizedName(name)
        var usedWorkspacePaths = Set(state.agents.map { $0.workspaceURL.standardizedFileURL.path })
        let workspaceURL = try nextWorkspaceDirectory(
            for: normalizedAgentName,
            usedWorkspacePaths: &usedWorkspacePaths,
            fileManager: fileManager
        )

        let runtimeURL = workspaceURL.appendingPathComponent(".runtime", isDirectory: true)

        try fileManager.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: runtimeURL, withIntermediateDirectories: true)

        let profile = AgentProfile(
            id: agentID,
            name: normalizedAgentName,
            emoji: normalizedEmoji(emoji),
            workspacePath: workspaceURL.path,
            localRuntimePath: runtimeURL.path
        )

        state.agents.append(profile)
        if state.activeAgentID == nil {
            state.activeAgentID = profile.id
        }
        persist(state: state, defaults: defaults)
        return profile
    }

    static func updateAgent(
        agentID: UUID,
        name: String,
        emoji: String,
        defaults: UserDefaults = .standard
    ) -> AgentProfile? {
        var state = load(defaults: defaults)
        guard let index = state.agents.firstIndex(where: { $0.id == agentID }) else {
            return nil
        }

        state.agents[index].name = normalizedName(name)
        state.agents[index].emoji = normalizedEmoji(emoji)
        let profile = state.agents[index]
        persist(state: state, defaults: defaults)
        return profile
    }

    static func renameAgent(
        agentID: UUID,
        name: String,
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) -> AgentProfile? {
        var state = load(defaults: defaults, fileManager: fileManager)
        guard let index = state.agents.firstIndex(where: { $0.id == agentID }) else {
            return nil
        }

        let normalizedAgentName = normalizedName(name)
        let currentProfile = state.agents[index]
        let oldWorkspaceURL = currentProfile.workspaceURL.standardizedFileURL

        var usedWorkspacePaths = Set(
            state.agents.enumerated().compactMap { offset, profile in
                offset == index ? nil : profile.workspaceURL.standardizedFileURL.path
            }
        )

        guard let workspaceURL = try? nextWorkspaceDirectory(
            for: normalizedAgentName,
            usedWorkspacePaths: &usedWorkspacePaths,
            fileManager: fileManager
        ) else {
            return nil
        }

        if oldWorkspaceURL.path != workspaceURL.path,
           fileManager.fileExists(atPath: oldWorkspaceURL.path)
        {
            do {
                try fileManager.moveItem(at: oldWorkspaceURL, to: workspaceURL)
            } catch {
                return nil
            }
        }

        let runtimeURL = workspaceURL.appendingPathComponent(".runtime", isDirectory: true)
        // Keep workspace/runtime paths always valid after rename.
        try? fileManager.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: runtimeURL, withIntermediateDirectories: true)

        state.agents[index].name = normalizedAgentName
        state.agents[index].workspacePath = workspaceURL.path
        state.agents[index].localRuntimePath = runtimeURL.path

        let profile = state.agents[index]
        persist(state: state, defaults: defaults)
        return profile
    }

    @discardableResult
    static func setActiveAgent(
        _ agentID: UUID,
        defaults: UserDefaults = .standard
    ) -> Bool {
        var state = load(defaults: defaults)
        guard state.agents.contains(where: { $0.id == agentID }) else {
            return false
        }

        state.activeAgentID = agentID
        persist(state: state, defaults: defaults)
        return true
    }

    @discardableResult
    static func deleteAgent(
        _ agentID: UUID,
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) -> Bool {
        var state = load(defaults: defaults)
        guard let index = state.agents.firstIndex(where: { $0.id == agentID }) else {
            return false
        }

        let removed = state.agents.remove(at: index)

        // Keep active agent valid after deletion.
        if state.activeAgentID == agentID || !state.agents.contains(where: { $0.id == state.activeAgentID }) {
            state.activeAgentID = state.agents.first?.id
        }

        persist(state: state, defaults: defaults)

        // Best-effort cleanup for deleted agent workspace directory.
        let workspaceURL = removed.workspaceURL
        if fileManager.fileExists(atPath: workspaceURL.path) {
            try? fileManager.removeItem(at: workspaceURL)
        }

        return true
    }

    @discardableResult
    static func setSelectedModel(
        _ selectedModelID: UUID?,
        for agentID: UUID,
        defaults: UserDefaults = .standard
    ) -> Bool {
        var state = load(defaults: defaults)
        guard let index = state.agents.firstIndex(where: { $0.id == agentID }) else {
            return false
        }

        state.agents[index].selectedModelID = selectedModelID
        persist(state: state, defaults: defaults)
        return true
    }

    @discardableResult
    static func setAutoCompact(
        _ enabled: Bool,
        for agentID: UUID,
        defaults: UserDefaults = .standard
    ) -> Bool {
        var state = load(defaults: defaults)
        guard let index = state.agents.firstIndex(where: { $0.id == agentID }) else {
            return false
        }

        state.agents[index].autoCompactEnabled = enabled
        persist(state: state, defaults: defaults)
        return true
    }

    @discardableResult
    static func setSelectedSession(
        _ selectedSessionKey: String?,
        for agentID: UUID,
        defaults: UserDefaults = .standard
    ) -> Bool {
        var state = load(defaults: defaults)
        guard let index = state.agents.firstIndex(where: { $0.id == agentID }) else {
            return false
        }

        state.agents[index].selectedSessionKey = nonEmpty(selectedSessionKey)
        persist(state: state, defaults: defaults)
        return true
    }

    /// Repair per-agent selections after a model is deleted.
    static func repairSelectedModel(afterDeleting deletedModelID: UUID, replacement: UUID?, defaults: UserDefaults = .standard) {
        var state = load(defaults: defaults)
        var didChange = false

        for index in state.agents.indices where state.agents[index].selectedModelID == deletedModelID {
            state.agents[index].selectedModelID = replacement
            didChange = true
        }

        if didChange {
            persist(state: state, defaults: defaults)
        }
    }

    private static func persist(state: AgentStateSnapshot, defaults: UserDefaults) {
        let payload = PersistedState(
            version: 1,
            agents: state.agents,
            activeAgentID: state.activeAgentID
        )
        if let data = try? JSONEncoder().encode(payload) {
            defaults.set(data, forKey: DefaultsKey.state)
        }
    }

    private static func workspaceRootDirectory(fileManager: FileManager) throws -> URL {
        guard let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw NSError(
                domain: "AgentStore",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Documents directory unavailable"]
            )
        }
        let rootURL = documentsURL
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        return rootURL
    }

    private static func cleanupLegacyWorkspaceRootIfEmpty(fileManager: FileManager) {
        guard let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return
        }

        let legacyRootURL = documentsURL.appendingPathComponent("OpenAva", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: legacyRootURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return
        }

        guard let contents = try? fileManager.contentsOfDirectory(
            at: legacyRootURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ), contents.isEmpty else {
            return
        }

        try? fileManager.removeItem(at: legacyRootURL)
    }

    private static func nextWorkspaceDirectory(
        for agentName: String,
        usedWorkspacePaths: inout Set<String>,
        fileManager: FileManager
    ) throws -> URL {
        let rootURL = try workspaceRootDirectory(fileManager: fileManager)
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

    private static func normalizedStoragePaths(
        for profile: AgentProfile,
        usedWorkspacePaths: inout Set<String>,
        fileManager: FileManager
    ) -> AgentProfile {
        guard let workspaceURL = try? nextWorkspaceDirectory(
            for: normalizedName(profile.name),
            usedWorkspacePaths: &usedWorkspacePaths,
            fileManager: fileManager
        )
        else {
            return profile
        }

        let oldWorkspaceURL = profile.workspaceURL.standardizedFileURL
        if oldWorkspaceURL.path != workspaceURL.path,
           fileManager.fileExists(atPath: oldWorkspaceURL.path),
           !fileManager.fileExists(atPath: workspaceURL.path)
        {
            try? fileManager.moveItem(at: oldWorkspaceURL, to: workspaceURL)
        }

        let runtimeURL = workspaceURL.appendingPathComponent(".runtime", isDirectory: true)
        // Ensure canonical directories exist before exposing the profile.
        try? fileManager.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: runtimeURL, withIntermediateDirectories: true)

        var normalized = profile
        normalized.workspacePath = workspaceURL.path
        normalized.localRuntimePath = runtimeURL.path
        return normalized
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
