import Foundation

struct TeamStateSnapshot: Equatable {
    var teams: [TeamProfile]
}

enum TeamStore {
    private struct PersistedState: Codable {
        let version: Int
        var teams: [TeamProfile]
    }

    private enum DefaultsKey {
        static let state = "team.profile.state.v1"
    }

    static func load(defaults: UserDefaults = .standard) -> TeamStateSnapshot {
        guard let data = defaults.data(forKey: DefaultsKey.state),
              let decoded = try? JSONDecoder().decode(PersistedState.self, from: data),
              decoded.version == 1
        else {
            return TeamStateSnapshot(teams: [])
        }

        return TeamStateSnapshot(
            teams: decoded.teams.sorted { $0.createdAt < $1.createdAt }
        )
    }

    static func team(id teamID: UUID, defaults: UserDefaults = .standard) -> TeamProfile? {
        load(defaults: defaults).teams.first { $0.id == teamID }
    }

    @discardableResult
    static func createTeam(
        name: String,
        emoji: String = "👥",
        description: String? = nil,
        agentPoolIDs: [UUID] = [],
        leadAgentID: UUID? = nil,
        defaultTopology: TeamTopologyKind = .automatic,
        defaults: UserDefaults = .standard
    ) -> TeamProfile? {
        let normalizedAgentPoolIDs = agentPoolIDs.reduce(into: [UUID]()) { partialResult, id in
            if !partialResult.contains(id) {
                partialResult.append(id)
            }
        }
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedEmoji = EmojiPickerCatalog.normalized(emoji)
        guard !normalizedName.isEmpty else {
            return nil
        }

        let normalizedLeadAgentID: UUID?
        if let leadAgentID, normalizedAgentPoolIDs.contains(leadAgentID) {
            normalizedLeadAgentID = leadAgentID
        } else {
            normalizedLeadAgentID = normalizedAgentPoolIDs.first
        }

        var state = load(defaults: defaults)
        let uniqueName = nextUniqueName(baseName: normalizedName, existingNames: state.teams.map(\.name))
        let team = TeamProfile(
            name: uniqueName,
            emoji: normalizedEmoji,
            description: description,
            agentPoolIDs: normalizedAgentPoolIDs,
            leadAgentID: normalizedLeadAgentID,
            defaultTopology: defaultTopology
        )
        state.teams.append(team)
        persist(state: state, defaults: defaults)
        return team
    }

    static func deleteTeam(_ teamID: UUID, defaults: UserDefaults = .standard) {
        var state = load(defaults: defaults)
        state.teams.removeAll { $0.id == teamID }
        persist(state: state, defaults: defaults)
    }

    static func teams(containing agentID: UUID, defaults: UserDefaults = .standard) -> [TeamProfile] {
        load(defaults: defaults).teams.filter { $0.agentPoolIDs.contains(agentID) }
    }

    @discardableResult
    static func updateTeam(
        _ teamID: UUID,
        name: String,
        emoji: String,
        description: String?,
        defaults: UserDefaults = .standard
    ) -> TeamProfile? {
        var state = load(defaults: defaults)
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
        persist(state: state, defaults: defaults)
        return team
    }

    @discardableResult
    static func addAgents(
        _ agentIDs: [UUID],
        to teamID: UUID,
        defaults: UserDefaults = .standard
    ) -> TeamProfile? {
        mutateTeam(teamID, defaults: defaults) { team in
            for agentID in agentIDs where !team.agentPoolIDs.contains(agentID) {
                team.agentPoolIDs.append(agentID)
            }
            if team.leadAgentID == nil {
                team.leadAgentID = team.agentPoolIDs.first
            }
        }
    }

    @discardableResult
    static func removeAgent(
        _ agentID: UUID,
        from teamID: UUID,
        defaults: UserDefaults = .standard
    ) -> TeamProfile? {
        mutateTeam(teamID, defaults: defaults) { team in
            team.agentPoolIDs.removeAll { $0 == agentID }
            if team.leadAgentID == agentID {
                team.leadAgentID = team.agentPoolIDs.first
            }
        }
    }

    @discardableResult
    static func setLeadAgent(
        _ agentID: UUID?,
        for teamID: UUID,
        defaults: UserDefaults = .standard
    ) -> TeamProfile? {
        mutateTeam(teamID, defaults: defaults) { team in
            if let agentID, team.agentPoolIDs.contains(agentID) {
                team.leadAgentID = agentID
            } else {
                team.leadAgentID = team.agentPoolIDs.first
            }
        }
    }

    static func removeAgentReferences(_ agentID: UUID, defaults: UserDefaults = .standard) {
        var state = load(defaults: defaults)
        state.teams = state.teams.map { team in
            var team = team
            team.agentPoolIDs.removeAll { $0 == agentID }
            if team.leadAgentID == agentID {
                team.leadAgentID = team.agentPoolIDs.first
            }
            team.updatedAt = Date()
            return team
        }
        persist(state: state, defaults: defaults)
    }

    @discardableResult
    private static func mutateTeam(
        _ teamID: UUID,
        defaults: UserDefaults,
        mutate: (inout TeamProfile) -> Void
    ) -> TeamProfile? {
        var state = load(defaults: defaults)
        guard let index = state.teams.firstIndex(where: { $0.id == teamID }) else {
            return nil
        }

        var team = state.teams[index]
        mutate(&team)
        team.updatedAt = Date()
        state.teams[index] = team
        persist(state: state, defaults: defaults)
        return team
    }

    private static func persist(state: TeamStateSnapshot, defaults: UserDefaults) {
        let payload = PersistedState(version: 1, teams: state.teams)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        defaults.set(data, forKey: DefaultsKey.state)
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
