import Foundation

struct TeamStateSnapshot: Equatable {
    var teams: [TeamProfile]
}

enum TeamStore {
    static let allAgentsTeamID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    private enum Storage {
        static let directoryName = "teams"
    }

    static func load(fileManager: FileManager = .default, workspaceRootURL: URL? = nil) -> TeamStateSnapshot {
        let teams = OpenAvaProjectFile.load(fileManager: fileManager, workspaceRootURL: workspaceRootURL)?.teams ?? []
        let resolvedTeams = teams.map { team in
            applyMetadata(to: team, fileManager: fileManager, workspaceRootURL: workspaceRootURL)
        }
        return TeamStateSnapshot(teams: resolvedTeams.sorted { $0.createdAtMs < $1.createdAtMs })
    }

    static func team(id teamID: UUID, fileManager: FileManager = .default, workspaceRootURL: URL? = nil) -> TeamProfile? {
        load(fileManager: fileManager, workspaceRootURL: workspaceRootURL).teams.first { $0.id == teamID }
    }

    @discardableResult
    static func createTeam(
        name: String,
        emoji: String = "👥",
        description: String? = nil,
        agentPoolIDs: [UUID] = [],
        defaultTopology: TeamTopologyKind = .automatic,
        fileManager: FileManager = .default,
        workspaceRootURL: URL? = nil
    ) -> TeamProfile? {
        var state = load(fileManager: fileManager, workspaceRootURL: workspaceRootURL)
        let assignedIDs = Set(state.teams.flatMap(\.agentPoolIDs))
        let normalizedAgentPoolIDs = agentPoolIDs.reduce(into: [UUID]()) { partialResult, id in
            if !partialResult.contains(id), !assignedIDs.contains(id) {
                partialResult.append(id)
            }
        }
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedEmoji = EmojiPickerCatalog.normalized(emoji)
        guard !normalizedName.isEmpty else {
            return nil
        }
        let uniqueName = nextUniqueName(baseName: normalizedName, existingNames: state.teams.map(\.name))
        let team = TeamProfile(
            name: uniqueName,
            emoji: normalizedEmoji,
            description: description,
            agentPoolIDs: normalizedAgentPoolIDs,
            defaultTopology: defaultTopology
        )
        persistMetadata(
            ChatContextMetadata(
                selectedModelID: team.selectedModelID,
                thinkingStrength: team.thinkingStrength,
                createdAtMs: team.createdAtMs,
                autoCompactEnabled: team.autoCompactEnabled
            ),
            for: .team(team.id),
            fileManager: fileManager,
            workspaceRootURL: workspaceRootURL
        )
        state.teams.append(team)
        persist(state: state, fileManager: fileManager, workspaceRootURL: workspaceRootURL)
        return team
    }

    static func deleteTeam(_ teamID: UUID, fileManager: FileManager = .default, workspaceRootURL: URL? = nil) {
        var state = load(fileManager: fileManager, workspaceRootURL: workspaceRootURL)
        state.teams.removeAll { $0.id == teamID }
        persist(state: state, fileManager: fileManager, workspaceRootURL: workspaceRootURL)
        if let directoryURL = contextDirectoryURL(for: .team(teamID), fileManager: fileManager, workspaceRootURL: workspaceRootURL) {
            try? fileManager.removeItem(at: directoryURL)
        }
    }

    static func teams(containing agentID: UUID, fileManager: FileManager = .default, workspaceRootURL: URL? = nil) -> [TeamProfile] {
        load(fileManager: fileManager, workspaceRootURL: workspaceRootURL).teams.filter { $0.agentPoolIDs.contains(agentID) }
    }

    @discardableResult
    static func updateTeamProfile(
        _ profile: TeamProfile,
        fileManager: FileManager = .default,
        workspaceRootURL: URL? = nil
    ) -> TeamProfile? {
        return mutateTeam(profile.id, fileManager: fileManager, workspaceRootURL: workspaceRootURL) { team in
            team.name = profile.name
            team.emoji = profile.emoji
            team.description = profile.description
            team.agentPoolIDs = profile.agentPoolIDs
        }
    }

    @discardableResult
    static func updateTeam(
        _ teamID: UUID,
        name: String,
        emoji: String,
        description: String?,
        fileManager: FileManager = .default,
        workspaceRootURL: URL? = nil
    ) -> TeamProfile? {
        var state = load(fileManager: fileManager, workspaceRootURL: workspaceRootURL)
        guard let index = state.teams.firstIndex(where: { $0.id == teamID }) else {
            return nil
        }

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedEmoji = EmojiPickerCatalog.normalized(emoji)
        guard !trimmedName.isEmpty else {
            return nil
        }

        let existingNames = state.teams.enumerated().compactMap { offset, team in
            offset == index ? nil : team.name
        }

        var team = state.teams[index]
        team.name = nextUniqueName(baseName: trimmedName, existingNames: existingNames)
        team.emoji = trimmedEmoji.isEmpty ? "👥" : trimmedEmoji
        team.description = description?.trimmingCharacters(in: .whitespacesAndNewlines)
        team.updatedAt = Date()
        state.teams[index] = team
        persist(state: state, fileManager: fileManager, workspaceRootURL: workspaceRootURL)
        return team
    }

    @discardableResult
    static func addAgents(
        _ agentIDs: [UUID],
        to teamID: UUID,
        fileManager: FileManager = .default,
        workspaceRootURL: URL? = nil
    ) -> TeamProfile? {
        let state = load(fileManager: fileManager, workspaceRootURL: workspaceRootURL)
        let assignedIDs = Set(
            state.teams
                .filter { $0.id != teamID }
                .flatMap(\.agentPoolIDs)
        )
        let eligible = agentIDs.filter { !assignedIDs.contains($0) }
        return mutateTeam(teamID, fileManager: fileManager, workspaceRootURL: workspaceRootURL) { team in
            for agentID in eligible where !team.agentPoolIDs.contains(agentID) {
                team.agentPoolIDs.append(agentID)
            }
        }
    }

    @discardableResult
    static func removeAgent(
        _ agentID: UUID,
        from teamID: UUID,
        fileManager: FileManager = .default,
        workspaceRootURL: URL? = nil
    ) -> TeamProfile? {
        mutateTeam(teamID, fileManager: fileManager, workspaceRootURL: workspaceRootURL) { team in
            team.agentPoolIDs.removeAll { $0 == agentID }
        }
    }

    static func removeAgentReferences(_ agentID: UUID, fileManager: FileManager = .default, workspaceRootURL: URL? = nil) {
        var state = load(fileManager: fileManager, workspaceRootURL: workspaceRootURL)
        state.teams = state.teams.map { team in
            var team = team
            team.agentPoolIDs.removeAll { $0 == agentID }
            team.updatedAt = Date()
            return team
        }
        persist(state: state, fileManager: fileManager, workspaceRootURL: workspaceRootURL)
    }

    @discardableResult
    private static func mutateTeam(
        _ teamID: UUID,
        fileManager: FileManager,
        workspaceRootURL: URL?,
        mutate: (inout TeamProfile) -> Void
    ) -> TeamProfile? {
        var state = load(fileManager: fileManager, workspaceRootURL: workspaceRootURL)
        guard let index = state.teams.firstIndex(where: { $0.id == teamID }) else {
            return nil
        }

        var team = state.teams[index]
        mutate(&team)
        team.updatedAt = Date()
        state.teams[index] = team
        persist(state: state, fileManager: fileManager, workspaceRootURL: workspaceRootURL)
        return team
    }

    private static func persist(state: TeamStateSnapshot, fileManager: FileManager, workspaceRootURL: URL?) {
        var payload = OpenAvaProjectFile.load(fileManager: fileManager, workspaceRootURL: workspaceRootURL) ?? OpenAvaProjectState()
        payload.teams = state.teams
        OpenAvaProjectFile.persist(payload, fileManager: fileManager, workspaceRootURL: workspaceRootURL)
    }

    static func loadMetadata(
        for context: ActiveSessionContext,
        fileManager: FileManager = .default,
        workspaceRootURL: URL? = nil
    ) -> ChatContextMetadata? {
        guard let directoryURL = contextDirectoryURL(
            for: context,
            fileManager: fileManager,
            workspaceRootURL: workspaceRootURL
        ) else {
            return nil
        }
        return ChatContextMetadata.load(from: directoryURL)
    }

    @discardableResult
    static func setSelectedModel(
        _ selectedModelID: UUID?,
        for context: ActiveSessionContext,
        fileManager: FileManager = .default,
        workspaceRootURL: URL? = nil
    ) -> Bool {
        guard var metadata = editableMetadata(
            for: context,
            fileManager: fileManager,
            workspaceRootURL: workspaceRootURL
        ) else {
            return false
        }
        metadata.selectedModelID = selectedModelID
        persistMetadata(metadata, for: context, fileManager: fileManager, workspaceRootURL: workspaceRootURL)
        return true
    }

    @discardableResult
    static func setThinkingStrength(
        _ thinkingStrength: ChatThinkingStrength,
        for context: ActiveSessionContext,
        fileManager: FileManager = .default,
        workspaceRootURL: URL? = nil
    ) -> Bool {
        guard var metadata = editableMetadata(
            for: context,
            fileManager: fileManager,
            workspaceRootURL: workspaceRootURL
        ) else {
            return false
        }
        metadata.thinkingStrength = thinkingStrength
        persistMetadata(metadata, for: context, fileManager: fileManager, workspaceRootURL: workspaceRootURL)
        return true
    }

    @discardableResult
    static func setAutoCompact(
        _ enabled: Bool,
        for context: ActiveSessionContext,
        fileManager: FileManager = .default,
        workspaceRootURL: URL? = nil
    ) -> Bool {
        guard var metadata = editableMetadata(
            for: context,
            fileManager: fileManager,
            workspaceRootURL: workspaceRootURL
        ) else {
            return false
        }
        metadata.autoCompactEnabled = enabled
        persistMetadata(metadata, for: context, fileManager: fileManager, workspaceRootURL: workspaceRootURL)
        return true
    }

    static func repairSelectedModel(
        afterDeleting deletedModelID: UUID,
        replacement: UUID?,
        fileManager: FileManager = .default,
        workspaceRootURL: URL? = nil
    ) {
        var contexts: [ActiveSessionContext] = [.allAgentsTeam]
        contexts.append(contentsOf: load(fileManager: fileManager, workspaceRootURL: workspaceRootURL).teams.map { .team($0.id) })

        for context in contexts {
            guard var metadata = loadMetadata(for: context, fileManager: fileManager, workspaceRootURL: workspaceRootURL),
                  metadata.selectedModelID == deletedModelID
            else {
                continue
            }
            metadata.selectedModelID = replacement
            persistMetadata(metadata, for: context, fileManager: fileManager, workspaceRootURL: workspaceRootURL)
        }
    }

    static func storageDirectoryURL(
        fileManager: FileManager = .default,
        workspaceRootURL: URL? = nil,
        createDirectoryIfNeeded: Bool = false
    ) -> URL? {
        let rootURL: URL
        if let workspaceRootURL {
            rootURL = workspaceRootURL.standardizedFileURL
            if createDirectoryIfNeeded {
                try? fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
            }
        } else {
            guard let resolvedRootURL = try? AgentStore.workspaceRootDirectory(fileManager: fileManager) else {
                return nil
            }
            rootURL = resolvedRootURL
        }

        let supportURL = AgentStore.supportDirectoryURL(workspaceRootURL: rootURL)
        let directoryURL = supportURL.appendingPathComponent(Storage.directoryName, isDirectory: true)
        if createDirectoryIfNeeded {
            try? fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        }
        return directoryURL
    }

    static func contextDirectoryURL(
        for context: ActiveSessionContext,
        fileManager: FileManager = .default,
        workspaceRootURL: URL? = nil,
        createDirectoryIfNeeded: Bool = false
    ) -> URL? {
        switch context {
        case .allAgentsTeam:
            return storageDirectoryURL(
                fileManager: fileManager,
                workspaceRootURL: workspaceRootURL,
                createDirectoryIfNeeded: createDirectoryIfNeeded
            )?
                .appendingPathComponent(allAgentsTeamID.uuidString, isDirectory: true)
        case let .team(teamID):
            return storageDirectoryURL(
                fileManager: fileManager,
                workspaceRootURL: workspaceRootURL,
                createDirectoryIfNeeded: createDirectoryIfNeeded
            )?
                .appendingPathComponent(teamID.uuidString, isDirectory: true)
        case .agent:
            return nil
        }
    }

    private static func editableMetadata(
        for context: ActiveSessionContext,
        fileManager: FileManager,
        workspaceRootURL: URL?
    ) -> ChatContextMetadata? {
        if case .agent = context {
            return nil
        }
        guard let directoryURL = contextDirectoryURL(
            for: context,
            fileManager: fileManager,
            workspaceRootURL: workspaceRootURL,
            createDirectoryIfNeeded: true
        ) else {
            return nil
        }
        return ChatContextMetadata.load(from: directoryURL) ?? ChatContextMetadata(selectedModelID: nil)
    }

    private static func persistMetadata(
        _ metadata: ChatContextMetadata,
        for context: ActiveSessionContext,
        fileManager: FileManager,
        workspaceRootURL: URL?
    ) {
        guard let directoryURL = contextDirectoryURL(
            for: context,
            fileManager: fileManager,
            workspaceRootURL: workspaceRootURL,
            createDirectoryIfNeeded: true
        ) else {
            return
        }
        ChatContextMetadata.persist(metadata, to: directoryURL, fileManager: fileManager)
    }

    private static func applyMetadata(
        to team: TeamProfile,
        fileManager: FileManager,
        workspaceRootURL: URL?
    ) -> TeamProfile {
        var team = team
        let metadata = loadMetadata(for: .team(team.id), fileManager: fileManager, workspaceRootURL: workspaceRootURL)
        team.selectedModelID = metadata?.selectedModelID
        team.thinkingStrength = metadata?.thinkingStrength ?? .medium
        team.createdAtMs = metadata?.createdAtMs ?? Int64(team.createdAt.timeIntervalSince1970 * 1000)
        team.autoCompactEnabled = metadata?.autoCompactEnabled ?? true
        return team
    }

    private static func nextUniqueName(baseName: String, existingNames: [String]) -> String {
        let trimmed = baseName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !existingNames.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) else {
            var index = 2
            while true {
                let candidate = "\(trimmed) \(index)"
                if !existingNames.contains(where: { $0.caseInsensitiveCompare(candidate) == .orderedSame }) {
                    return candidate
                }
                index += 1
            }
        }
        return trimmed
    }
}
