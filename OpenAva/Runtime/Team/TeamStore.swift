import Foundation

struct TeamStateSnapshot: Equatable {
    var teams: [TeamProfile]
}

enum TeamStore {
    private enum Storage {
        static let directoryName = "teams"
    }

    static func load(fileManager: FileManager = .default, workspaceRootURL: URL? = nil) -> TeamStateSnapshot {
        let teams = OpenAvaProjectFile.load(fileManager: fileManager, workspaceRootURL: workspaceRootURL)?.teams ?? []
        return TeamStateSnapshot(teams: teams.sorted { $0.createdAt < $1.createdAt })
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
        state.teams.append(team)
        persist(state: state, fileManager: fileManager, workspaceRootURL: workspaceRootURL)
        return team
    }

    static func deleteTeam(_ teamID: UUID, fileManager: FileManager = .default, workspaceRootURL: URL? = nil) {
        var state = load(fileManager: fileManager, workspaceRootURL: workspaceRootURL)
        state.teams.removeAll { $0.id == teamID }
        persist(state: state, fileManager: fileManager, workspaceRootURL: workspaceRootURL)
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

        let directoryURL = rootURL.appendingPathComponent(Storage.directoryName, isDirectory: true)
        if createDirectoryIfNeeded {
            try? fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        }
        return directoryURL
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
