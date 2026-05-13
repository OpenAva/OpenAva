import Foundation

struct TeamStateSnapshot: Equatable {
    var teams: [TeamProfile]
}

enum TeamStore {
    static let allAgentsTeamID = "team_00000000000000000000000001"

    private enum Storage {
        static let directoryName = "teams"
    }

    private static var localizedAllAgentsTeamName: String {
        L10n.tr("chat.menu.allAgentsTeam")
    }

    static func load(fileManager: FileManager = .default, workspaceRootURL: URL? = nil) -> TeamStateSnapshot {
        let teams = OpenAvaProjectFile.load(fileManager: fileManager, workspaceRootURL: workspaceRootURL)?.teams ?? []
        let resolvedTeams = teams.compactMap { team in
            applyMetadata(to: team, fileManager: fileManager, workspaceRootURL: workspaceRootURL)
        }
        return TeamStateSnapshot(teams: resolvedTeams.sorted { $0.createdAt < $1.createdAt })
    }

    static func team(id teamID: String, fileManager: FileManager = .default, workspaceRootURL: URL? = nil) -> TeamProfile? {
        load(fileManager: fileManager, workspaceRootURL: workspaceRootURL).teams.first { $0.id == teamID }
    }

    static func allAgentsTeam(fileManager: FileManager = .default, workspaceRootURL: URL? = nil) -> TeamProfile? {
        ensureAllAgentsTeamIdentity(fileManager: fileManager, workspaceRootURL: workspaceRootURL)
        return applyMetadata(
            to: TeamProfile(id: allAgentsTeamID, name: "", members: []),
            context: .allAgentsTeam,
            fileManager: fileManager,
            workspaceRootURL: workspaceRootURL
        )
    }

    @discardableResult
    static func createTeam(
        name: String,
        emoji: String = "👥",
        description: String? = nil,
        members: [String] = [],
        defaultTopology: TeamTopologyKind = .automatic,
        fileManager: FileManager = .default,
        workspaceRootURL: URL? = nil
    ) -> TeamProfile? {
        var state = load(fileManager: fileManager, workspaceRootURL: workspaceRootURL)
        let normalizedMembers = members.reduce(into: [String]()) { partialResult, id in
            if !partialResult.contains(id) {
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
            members: normalizedMembers,
            defaultTopology: defaultTopology
        )
        if let directoryURL = contextDirectoryURL(
            for: .team(team.id),
            fileManager: fileManager,
            workspaceRootURL: workspaceRootURL,
            createDirectoryIfNeeded: true
        ) {
            try? AgentTemplateWriter.writeTeamFile(
                at: directoryURL,
                name: team.name,
                emoji: team.emoji,
                description: team.description,
                fileManager: fileManager
            )
        }
        persistMetadata(
            metadata(from: team),
            for: .team(team.id),
            fileManager: fileManager,
            workspaceRootURL: workspaceRootURL
        )
        state.teams.append(TeamProfile(id: team.id, name: "", members: []))
        persist(state: state, fileManager: fileManager, workspaceRootURL: workspaceRootURL)
        return applyMetadata(to: TeamProfile(id: team.id, name: "", members: []), fileManager: fileManager, workspaceRootURL: workspaceRootURL)
    }

    static func deleteTeam(_ teamID: String, fileManager: FileManager = .default, workspaceRootURL: URL? = nil) {
        var state = load(fileManager: fileManager, workspaceRootURL: workspaceRootURL)
        state.teams.removeAll { $0.id == teamID }
        persist(state: state, fileManager: fileManager, workspaceRootURL: workspaceRootURL)
        if let directoryURL = contextDirectoryURL(for: .team(teamID), fileManager: fileManager, workspaceRootURL: workspaceRootURL) {
            try? fileManager.removeItem(at: directoryURL)
        }
    }

    static func teams(containing agentID: String, fileManager: FileManager = .default, workspaceRootURL: URL? = nil) -> [TeamProfile] {
        load(fileManager: fileManager, workspaceRootURL: workspaceRootURL).teams.filter { $0.members.contains(agentID) }
    }

    @discardableResult
    static func updateTeamProfile(
        _ profile: TeamProfile,
        fileManager: FileManager = .default,
        workspaceRootURL: URL? = nil
    ) -> TeamProfile? {
        let updated = mutateTeam(profile.id, fileManager: fileManager, workspaceRootURL: workspaceRootURL) { team in
            team.name = profile.name
            team.emoji = profile.emoji
            team.members = profile.members
            team.description = profile.description
            team.defaultTopology = profile.defaultTopology
        }
        guard let updated else { return nil }
        return updated
    }

    @discardableResult
    static func updateTeam(
        _ teamID: String,
        name: String,
        emoji: String,
        description: String?,
        fileManager: FileManager = .default,
        workspaceRootURL: URL? = nil
    ) -> TeamProfile? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedEmoji = EmojiPickerCatalog.normalized(emoji)
        guard !trimmedName.isEmpty else {
            return nil
        }
        let state = load(fileManager: fileManager, workspaceRootURL: workspaceRootURL)
        let existingNames = state.teams
            .filter { $0.id != teamID }
            .map(\.name)
        return mutateTeam(teamID, fileManager: fileManager, workspaceRootURL: workspaceRootURL) { team in
            team.name = nextUniqueName(baseName: trimmedName, existingNames: existingNames)
            team.emoji = trimmedEmoji.isEmpty ? "👥" : trimmedEmoji
            team.description = description?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    @discardableResult
    static func renameTeam(
        _ teamID: String,
        name: String,
        fileManager: FileManager = .default,
        workspaceRootURL: URL? = nil
    ) -> TeamProfile? {
        if teamID == allAgentsTeamID {
            return renameAllAgentsTeam(name, fileManager: fileManager, workspaceRootURL: workspaceRootURL)
        }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            return nil
        }
        let state = load(fileManager: fileManager, workspaceRootURL: workspaceRootURL)
        let existingNames = state.teams
            .filter { $0.id != teamID }
            .map(\.name)
        return mutateTeam(teamID, fileManager: fileManager, workspaceRootURL: workspaceRootURL) { team in
            team.name = nextUniqueName(baseName: trimmedName, existingNames: existingNames)
        }
    }

    @discardableResult
    static func renameAllAgentsTeam(
        _ name: String,
        fileManager: FileManager = .default,
        workspaceRootURL: URL? = nil
    ) -> TeamProfile? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            return nil
        }
        let existingNames = load(fileManager: fileManager, workspaceRootURL: workspaceRootURL).teams.map(\.name)
        ensureAllAgentsTeamIdentity(fileManager: fileManager, workspaceRootURL: workspaceRootURL)
        guard var team = allAgentsTeam(fileManager: fileManager, workspaceRootURL: workspaceRootURL) else {
            return nil
        }
        team.name = nextUniqueName(baseName: trimmedName, existingNames: existingNames)
        team.updatedAt = Date()
        persistMetadata(metadata(from: team), for: .allAgentsTeam, fileManager: fileManager, workspaceRootURL: workspaceRootURL)
        persistIdentity(from: team, context: .allAgentsTeam, fileManager: fileManager, workspaceRootURL: workspaceRootURL)
        return allAgentsTeam(fileManager: fileManager, workspaceRootURL: workspaceRootURL)
    }

    @discardableResult
    static func addAgents(
        _ agentIDs: [String],
        to teamID: String,
        fileManager: FileManager = .default,
        workspaceRootURL: URL? = nil
    ) -> TeamProfile? {
        return mutateTeam(teamID, fileManager: fileManager, workspaceRootURL: workspaceRootURL) { team in
            for agentID in agentIDs where !team.members.contains(agentID) {
                team.members.append(agentID)
            }
        }
    }

    @discardableResult
    static func removeAgent(
        _ agentID: String,
        from teamID: String,
        fileManager: FileManager = .default,
        workspaceRootURL: URL? = nil
    ) -> TeamProfile? {
        mutateTeam(teamID, fileManager: fileManager, workspaceRootURL: workspaceRootURL) { team in
            team.members.removeAll { $0 == agentID }
        }
    }

    static func removeAgentReferences(_ agentID: String, fileManager: FileManager = .default, workspaceRootURL: URL? = nil) {
        let state = load(fileManager: fileManager, workspaceRootURL: workspaceRootURL)
        for team in state.teams where team.members.contains(agentID) {
            _ = mutateTeam(team.id, fileManager: fileManager, workspaceRootURL: workspaceRootURL) { team in
                team.members.removeAll { $0 == agentID }
            }
        }
    }

    @discardableResult
    private static func mutateTeam(
        _ teamID: String,
        fileManager: FileManager,
        workspaceRootURL: URL?,
        mutate: (inout TeamProfile) -> Void
    ) -> TeamProfile? {
        var projectState = OpenAvaProjectFile.load(fileManager: fileManager, workspaceRootURL: workspaceRootURL) ?? OpenAvaProjectState()
        guard projectState.teams.contains(where: { $0.id == teamID }) else {
            return nil
        }
        guard var team = applyMetadata(
            to: TeamProfile(id: teamID, name: "", members: []),
            context: .team(teamID),
            fileManager: fileManager,
            workspaceRootURL: workspaceRootURL
        ) else {
            return nil
        }
        mutate(&team)
        team.updatedAt = Date()
        persistMetadata(metadata(from: team), for: .team(teamID), fileManager: fileManager, workspaceRootURL: workspaceRootURL)
        persistIdentity(from: team, context: .team(teamID), fileManager: fileManager, workspaceRootURL: workspaceRootURL)
        projectState.teams = projectState.teams.map { existing in
            existing.id == teamID ? TeamProfile(id: teamID, name: "", members: []) : existing
        }
        OpenAvaProjectFile.persist(projectState, fileManager: fileManager, workspaceRootURL: workspaceRootURL)
        return applyMetadata(to: TeamProfile(id: teamID, name: "", members: []), context: .team(teamID), fileManager: fileManager, workspaceRootURL: workspaceRootURL)
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
        _ selectedModelID: String?,
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
        afterDeleting deletedModelID: String,
        replacement: String?,
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
                .appendingPathComponent(allAgentsTeamID, isDirectory: true)
        case let .team(teamID):
            return storageDirectoryURL(
                fileManager: fileManager,
                workspaceRootURL: workspaceRootURL,
                createDirectoryIfNeeded: createDirectoryIfNeeded
            )?
                .appendingPathComponent(teamID, isDirectory: true)
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
        if case .allAgentsTeam = context {
            ensureAllAgentsTeamIdentity(fileManager: fileManager, workspaceRootURL: workspaceRootURL)
        }
        return ChatContextMetadata.load(from: directoryURL)
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
        context: ActiveSessionContext? = nil,
        fileManager: FileManager,
        workspaceRootURL: URL?
    ) -> TeamProfile? {
        let context = context ?? .team(team.id)
        guard let metadata = loadMetadata(for: context, fileManager: fileManager, workspaceRootURL: workspaceRootURL) else {
            return nil
        }
        var team = team
        team.members = metadata.members
        team.createdAt = metadata.createdAt
        team.updatedAt = metadata.updatedAt
        team.selectedModelID = metadata.selectedModelID
        team.thinkingStrength = metadata.thinkingStrength
        team.autoCompactEnabled = metadata.autoCompactEnabled
        team.defaultTopology = metadata.defaultTopology
        guard let identity = identityMetadata(for: context, fileManager: fileManager, workspaceRootURL: workspaceRootURL) else {
            return nil
        }
        guard let name = identity.name, let emoji = identity.emoji else {
            return nil
        }
        team.name = name
        team.emoji = emoji
        team.description = identity.description
        team.identityDocument = identity.content
        return team
    }

    private static func metadata(from profile: TeamProfile) -> ChatContextMetadata {
        ChatContextMetadata(
            selectedModelID: profile.selectedModelID,
            thinkingStrength: profile.thinkingStrength,
            members: profile.members,
            createdAt: profile.createdAt,
            updatedAt: profile.updatedAt,
            autoCompactEnabled: profile.autoCompactEnabled,
            defaultTopology: profile.defaultTopology
        )
    }

    private struct IdentityMetadata {
        var name: String?
        var emoji: String?
        var description: String?
        var content: String
    }

    private static func persistIdentity(
        from team: TeamProfile,
        context: ActiveSessionContext,
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
        try? AgentTemplateWriter.syncTeamIdentityProfile(
            at: directoryURL,
            name: team.name,
            emoji: team.emoji,
            description: team.description,
            fileManager: fileManager
        )
    }

    private static func identityMetadata(
        for context: ActiveSessionContext,
        fileManager: FileManager,
        workspaceRootURL: URL?
    ) -> IdentityMetadata? {
        guard let directoryURL = contextDirectoryURL(
            for: context,
            fileManager: fileManager,
            workspaceRootURL: workspaceRootURL
        ) else {
            return nil
        }
        let identityURL = directoryURL.appendingPathComponent(AgentContextDocumentKind.identity.fileName, isDirectory: false)
        guard let data = try? Data(contentsOf: identityURL),
              let content = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return IdentityMetadata(
            name: AgentTemplateWriter.identityFieldValue(named: "Name", in: content),
            emoji: AgentTemplateWriter.identityFieldValue(named: "Emoji", in: content),
            description: AgentTemplateWriter.identityFieldValue(named: "Description", in: content),
            content: content
        )
    }

    private static func ensureAllAgentsTeamIdentity(fileManager: FileManager, workspaceRootURL: URL?) {
        guard let directoryURL = contextDirectoryURL(
            for: .allAgentsTeam,
            fileManager: fileManager,
            workspaceRootURL: workspaceRootURL,
            createDirectoryIfNeeded: true
        ) else {
            return
        }

        let identityURL = directoryURL.appendingPathComponent(AgentContextDocumentKind.identity.fileName, isDirectory: false)
        if !fileManager.fileExists(atPath: identityURL.path) {
            try? AgentTemplateWriter.writeTeamFile(
                at: directoryURL,
                name: localizedAllAgentsTeamName,
                emoji: "👥",
                description: "A shared room where all agents can respond.",
                fileManager: fileManager
            )
        }

        if ChatContextMetadata.load(from: directoryURL) == nil {
            ChatContextMetadata.persist(ChatContextMetadata(selectedModelID: nil), to: directoryURL, fileManager: fileManager)
        }
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
