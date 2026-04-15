import Foundation

struct TeamStateSnapshot: Equatable {
    var teams: [TeamProfile]
}

enum TeamStore {
    private enum Storage {
        static let directoryName = "teams"
        static let runtimeDirectoryName = ".runtime"
    }

    static func load(fileManager: FileManager = .default) -> TeamStateSnapshot {
        let teams = OpenAvaStateFile.load(fileManager: fileManager)?.teams ?? []
        return TeamStateSnapshot(teams: teams.sorted { $0.createdAt < $1.createdAt })
    }

    static func team(id teamID: UUID, fileManager: FileManager = .default) -> TeamProfile? {
        load(fileManager: fileManager).teams.first { $0.id == teamID }
    }

    @discardableResult
    static func createTeam(
        name: String,
        emoji: String = "👥",
        description: String? = nil,
        agentPoolIDs: [UUID] = [],
        defaultTopology: TeamTopologyKind = .automatic,
        fileManager: FileManager = .default
    ) -> TeamProfile? {
        var state = load(fileManager: fileManager)
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
        state.teams.append(team)
        persist(state: state, fileManager: fileManager)
        return team
    }

    static func deleteTeam(_ teamID: UUID, fileManager: FileManager = .default) {
        var state = load(fileManager: fileManager)
        let removedTeamName = state.teams.first { $0.id == teamID }?.name
        state.teams.removeAll { $0.id == teamID }
        persist(state: state, fileManager: fileManager)

        guard let removedTeamName,
              let runtimeDirectoryURL = teamRuntimeDirectoryURL(for: removedTeamName, fileManager: fileManager)
        else {
            return
        }

        if fileManager.fileExists(atPath: runtimeDirectoryURL.path) {
            try? fileManager.removeItem(at: runtimeDirectoryURL)
        }
    }

    static func teams(containing agentID: UUID, fileManager: FileManager = .default) -> [TeamProfile] {
        load(fileManager: fileManager).teams.filter { $0.agentPoolIDs.contains(agentID) }
    }

    @discardableResult
    static func updateTeamProfile(
        _ profile: TeamProfile,
        fileManager: FileManager = .default
    ) -> TeamProfile? {
        return mutateTeam(profile.id, fileManager: fileManager) { team in
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
        fileManager: FileManager = .default
    ) -> TeamProfile? {
        var state = load(fileManager: fileManager)
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
        persist(state: state, fileManager: fileManager)
        return team
    }

    @discardableResult
    static func addAgents(
        _ agentIDs: [UUID],
        to teamID: UUID,
        fileManager: FileManager = .default
    ) -> TeamProfile? {
        let state = load(fileManager: fileManager)
        let assignedIDs = Set(
            state.teams
                .filter { $0.id != teamID }
                .flatMap(\.agentPoolIDs)
        )
        let eligible = agentIDs.filter { !assignedIDs.contains($0) }
        return mutateTeam(teamID, fileManager: fileManager) { team in
            for agentID in eligible where !team.agentPoolIDs.contains(agentID) {
                team.agentPoolIDs.append(agentID)
            }
        }
    }

    @discardableResult
    static func removeAgent(
        _ agentID: UUID,
        from teamID: UUID,
        fileManager: FileManager = .default
    ) -> TeamProfile? {
        mutateTeam(teamID, fileManager: fileManager) { team in
            team.agentPoolIDs.removeAll { $0 == agentID }
        }
    }

    static func removeAgentReferences(_ agentID: UUID, fileManager: FileManager = .default) {
        var state = load(fileManager: fileManager)
        state.teams = state.teams.map { team in
            var team = team
            team.agentPoolIDs.removeAll { $0 == agentID }
            team.updatedAt = Date()
            return team
        }
        persist(state: state, fileManager: fileManager)
    }

    @discardableResult
    private static func mutateTeam(
        _ teamID: UUID,
        fileManager: FileManager,
        mutate: (inout TeamProfile) -> Void
    ) -> TeamProfile? {
        var state = load(fileManager: fileManager)
        guard let index = state.teams.firstIndex(where: { $0.id == teamID }) else {
            return nil
        }

        var team = state.teams[index]
        mutate(&team)
        team.updatedAt = Date()
        state.teams[index] = team
        persist(state: state, fileManager: fileManager)
        return team
    }

    private static func persist(state: TeamStateSnapshot, fileManager: FileManager) {
        var payload = OpenAvaStateFile.load(fileManager: fileManager) ?? OpenAvaPersistedState()
        payload.teams = state.teams
        OpenAvaStateFile.persist(payload, fileManager: fileManager)
    }

    static func storageDirectoryURL(fileManager: FileManager = .default, createDirectoryIfNeeded: Bool = false) -> URL? {
        guard let rootURL = try? AgentStore.workspaceRootDirectory(fileManager: fileManager) else {
            return nil
        }
        let directoryURL = rootURL.appendingPathComponent(Storage.directoryName, isDirectory: true)
        if createDirectoryIfNeeded {
            try? fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        }
        return directoryURL
    }

    static func runtimeDirectoryURL(fileManager: FileManager = .default, createDirectoryIfNeeded: Bool = false) -> URL? {
        guard let storageURL = storageDirectoryURL(fileManager: fileManager, createDirectoryIfNeeded: createDirectoryIfNeeded) else {
            return nil
        }
        let runtimeURL = storageURL.appendingPathComponent(Storage.runtimeDirectoryName, isDirectory: true)
        if createDirectoryIfNeeded {
            try? fileManager.createDirectory(at: runtimeURL, withIntermediateDirectories: true)
        }
        return runtimeURL
    }

    private static func teamRuntimeDirectoryURL(for teamName: String, fileManager: FileManager) -> URL? {
        return runtimeDirectoryURL(fileManager: fileManager, createDirectoryIfNeeded: false)?
            .appendingPathComponent(teamName, isDirectory: true)
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
