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

    @discardableResult
    static func createTeam(
        name: String,
        description: String? = nil,
        agentPoolIDs: [UUID],
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
        guard !normalizedName.isEmpty, !normalizedAgentPoolIDs.isEmpty else {
            return nil
        }

        var state = load(defaults: defaults)
        let uniqueName = nextUniqueName(baseName: normalizedName, existingNames: state.teams.map(\.name))
        let team = TeamProfile(
            name: uniqueName,
            description: description,
            agentPoolIDs: normalizedAgentPoolIDs,
            leadAgentID: leadAgentID,
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

    static func removeAgentReferences(_ agentID: UUID, defaults: UserDefaults = .standard) {
        var state = load(defaults: defaults)
        state.teams = state.teams.compactMap { team in
            var team = team
            team.agentPoolIDs.removeAll { $0 == agentID }
            if team.leadAgentID == agentID {
                team.leadAgentID = team.agentPoolIDs.first
            }
            guard !team.agentPoolIDs.isEmpty else { return nil }
            team.updatedAt = Date()
            return team
        }
        persist(state: state, defaults: defaults)
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
