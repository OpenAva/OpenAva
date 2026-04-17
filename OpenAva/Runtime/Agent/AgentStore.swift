import Foundation

struct AgentProfile: Equatable, Identifiable {
    var id: UUID
    var name: String
    var emoji: String
    var workspacePath: String
    var localRuntimePath: String
    /// Per-agent selected LLM model identifier.
    var selectedModelID: UUID?
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
        createdAtMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000),
        autoCompactEnabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.emoji = emoji
        self.workspacePath = workspacePath
        self.localRuntimePath = localRuntimePath
        self.selectedModelID = selectedModelID
        self.createdAtMs = createdAtMs
        self.autoCompactEnabled = autoCompactEnabled
    }
}

extension AgentProfile: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, name, emoji, workspacePath, localRuntimePath
        case selectedModelID, createdAtMs
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

struct OpenAvaPersistedState: Codable {
    private enum CodingKeys: String, CodingKey {
        case agents
        case activeAgentID
        case user
        case teams
    }

    var agents: [AgentProfile]
    var activeAgentID: UUID?
    var user: OpenAvaUserDefaults?
    var teams: [TeamProfile]

    init(
        agents: [AgentProfile] = [],
        activeAgentID: UUID? = nil,
        user: OpenAvaUserDefaults? = nil,
        teams: [TeamProfile] = []
    ) {
        self.agents = agents
        self.activeAgentID = activeAgentID
        self.user = user
        self.teams = teams
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        agents = try container.decodeIfPresent([AgentProfile].self, forKey: .agents) ?? []
        activeAgentID = try container.decodeIfPresent(UUID.self, forKey: .activeAgentID)
        user = try container.decodeIfPresent(OpenAvaUserDefaults.self, forKey: .user)
        teams = try container.decodeIfPresent([TeamProfile].self, forKey: .teams) ?? []
    }
}

enum OpenAvaStateFile {
    private static let fileName = ".openava.json"

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
    ) -> OpenAvaPersistedState? {
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
        return try? decoder.decode(OpenAvaPersistedState.self, from: data)
    }

    static func persist(
        _ state: OpenAvaPersistedState,
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
              let data = try? encoder.encode(state)
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
        return rootURL.appendingPathComponent(fileName, isDirectory: false)
    }
}

enum AgentStore {
    typealias UserDefaults = OpenAvaUserDefaults

    static func load(
        fileManager: FileManager = .default,
        workspaceRootURL: URL? = nil
    ) -> AgentStateSnapshot {
        guard var decoded = OpenAvaStateFile.load(fileManager: fileManager, workspaceRootURL: workspaceRootURL) else {
            return AgentStateSnapshot(agents: [], activeAgentID: nil)
        }

        let agents = decoded.agents
        var activeAgentID = decoded.activeAgentID
        if let selectedActiveAgentID = activeAgentID,
           !agents.contains(where: { $0.id == selectedActiveAgentID })
        {
            activeAgentID = agents.first?.id
        }

        if activeAgentID != decoded.activeAgentID {
            decoded.activeAgentID = activeAgentID
            OpenAvaStateFile.persist(decoded, fileManager: fileManager, workspaceRootURL: workspaceRootURL)
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
        OpenAvaStateFile.load(fileManager: fileManager, workspaceRootURL: workspaceRootURL)?.user
    }

    static func saveUser(
        callName: String,
        context: String,
        fileManager: FileManager = .default,
        workspaceRootURL: URL? = nil
    ) {
        let normalizedCallName = callName.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedContext = context.trimmingCharacters(in: .whitespacesAndNewlines)

        var payload = OpenAvaStateFile.load(fileManager: fileManager, workspaceRootURL: workspaceRootURL)
            ?? OpenAvaPersistedState()

        if normalizedCallName.isEmpty, normalizedContext.isEmpty {
            payload.user = nil
        } else {
            payload.user = UserDefaults(
                callName: normalizedCallName,
                context: normalizedContext
            )
        }

        OpenAvaStateFile.persist(payload, fileManager: fileManager, workspaceRootURL: workspaceRootURL)
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
        var usedWorkspacePaths = Set(state.agents.map { $0.workspaceURL.standardizedFileURL.path })
        let workspaceURL = try nextWorkspaceDirectory(
            for: normalizedAgentName,
            rootURL: rootURL,
            usedWorkspacePaths: &usedWorkspacePaths
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
        let currentProfile = state.agents[index]
        let oldWorkspaceURL = currentProfile.workspaceURL.standardizedFileURL

        var usedWorkspacePaths = Set(
            state.agents.enumerated().compactMap { offset, profile in
                offset == index ? nil : profile.workspaceURL.standardizedFileURL.path
            }
        )

        guard let workspaceURL = try? nextWorkspaceDirectory(
            for: normalizedAgentName,
            rootURL: rootURL,
            usedWorkspacePaths: &usedWorkspacePaths
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
        fileManager: FileManager = .default,
        workspaceRootURL: URL? = nil
    ) -> Bool {
        var state = load(fileManager: fileManager, workspaceRootURL: workspaceRootURL)
        guard let index = state.agents.firstIndex(where: { $0.id == agentID }) else {
            return false
        }

        state.agents[index].selectedModelID = selectedModelID
        persist(state: state, fileManager: fileManager, workspaceRootURL: workspaceRootURL)
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
        persist(state: state, fileManager: fileManager, workspaceRootURL: workspaceRootURL)
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
        var didChange = false

        for index in state.agents.indices where state.agents[index].selectedModelID == deletedModelID {
            state.agents[index].selectedModelID = replacement
            didChange = true
        }

        if didChange {
            persist(state: state, fileManager: fileManager, workspaceRootURL: workspaceRootURL)
        }
    }

    private static func persist(
        state: AgentStateSnapshot,
        fileManager: FileManager,
        workspaceRootURL: URL?
    ) {
        var payload = OpenAvaStateFile.load(fileManager: fileManager, workspaceRootURL: workspaceRootURL)
            ?? OpenAvaPersistedState()
        payload.agents = state.agents
        payload.activeAgentID = state.activeAgentID
        OpenAvaStateFile.persist(payload, fileManager: fileManager, workspaceRootURL: workspaceRootURL)
    }

    static func workspaceRootDirectory(fileManager: FileManager) throws -> URL {
        guard let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw NSError(
                domain: "AgentStore",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Documents directory unavailable"]
            )
        }
        #if os(macOS) || targetEnvironment(macCatalyst)
            let rootURL = documentsURL.appendingPathComponent("OpenAva", isDirectory: true)
        #else
            let rootURL = documentsURL
        #endif
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        return rootURL
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
