import Combine
import Foundation
import Observation

@MainActor
@Observable
final class AppContainerStore {
    private(set) var container: AppContainer
    private(set) var agentState: AgentStateSnapshot
    private(set) var teamState: TeamStateSnapshot
    private(set) var preferredLanguageCode: String?
    private(set) var resolvedLanguageCode: String
    private(set) var usageSnapshot: UsageSnapshot = .init()
    private let defaults: UserDefaults
    private let fileManager: FileManager
    private var usageCancellable: AnyCancellable?

    var activeAgent: AgentProfile? {
        agentState.activeAgent
    }

    var agents: [AgentProfile] {
        agentState.agents
    }

    var teams: [TeamProfile] {
        teamState.teams
    }

    var hasAgent: Bool {
        agentState.hasAgent
    }

    var activeAgentWorkspaceURL: URL? {
        activeAgent?.workspaceURL
    }

    init(
        container: AppContainer,
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) {
        self.container = container
        self.defaults = defaults
        self.fileManager = fileManager
        agentState = AgentStore.load(defaults: defaults, fileManager: fileManager)
        teamState = TeamStore.load(defaults: defaults)
        // Migration: clear stale explicit "en" override left from early development.
        // English is the fallback — storing it explicitly blocks system language negotiation.
        AppLanguagePreference.clearStaleEnglishOverride()
        preferredLanguageCode = AppLanguagePreference.userPreferredLanguageCode()
        resolvedLanguageCode = LocaleResolver.currentLanguageCode()
        rebuildContainer(with: container.config)
        subscribeToUsageTracker()
    }

    private func subscribeToUsageTracker() {
        // Seed from persisted state immediately.
        Task { @MainActor in
            usageSnapshot = await LLMUsageTracker.shared.current
        }
        // Keep in sync with live updates.
        usageCancellable = LLMUsageTracker.shared.snapshotDidChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] snapshot in
                self?.usageSnapshot = snapshot
            }
    }

    func resetUsageStats() {
        Task {
            await LLMUsageTracker.shared.reset()
        }
    }

    func setPreferredLanguageCode(_ languageCode: String?) {
        let normalizedCode = LocaleResolver.normalize(code: languageCode)
        AppLanguagePreference.setUserPreferredLanguageCode(normalizedCode)
        preferredLanguageCode = normalizedCode
        resolvedLanguageCode = LocaleResolver.currentLanguageCode()
    }

    /// Update the entire collection and rebuild container.
    func updateLLMCollection(_ collection: AppConfig.LLMCollection) {
        var config = container.config
        config.llmCollection = collection
        LLMConfigStore.saveCollection(collection)
        rebuildContainer(with: config)
    }

    /// Select a specific model from the collection.
    func selectLLMModel(id: UUID) {
        var config = container.config
        config.agent.selectedLLMModelID = id

        // Persist agent-scoped selection when an active agent exists.
        if let activeAgentID = activeAgent?.id {
            _ = AgentStore.setSelectedModel(id, for: activeAgentID, defaults: defaults)
        }
        rebuildContainer(with: config)
    }

    /// Save a single model and rebuild the container from the persisted collection.
    func saveLLMModel(_ model: AppConfig.LLMModel) {
        LLMConfigStore.saveModel(model)

        // Reload collection and update container.
        let updatedCollection = LLMConfigStore.loadCollection()
        var config = container.config
        config.llmCollection = updatedCollection
        rebuildContainer(with: config)
    }

    /// Delete a model from the collection.
    func deleteLLMModel(id: UUID) {
        LLMConfigStore.deleteModel(id: id)

        // Reload collection and update container.
        let updatedCollection = LLMConfigStore.loadCollection()
        // Fallback to first available model when repairing deleted references.
        AgentStore.repairSelectedModel(
            afterDeleting: id,
            replacement: updatedCollection.models.first?.id,
            defaults: defaults
        )
        var config = container.config
        config.llmCollection = updatedCollection
        rebuildContainer(with: config)
    }

    /// Clear persisted overrides and fall back to environment defaults.
    func clearLLM() {
        LLMConfigStore.clearCollection()

        let freshConfig = AppConfig.make(environment: ProcessInfo.processInfo.environment)
        var config = container.config
        config.llmCollection = freshConfig.llmCollection
        rebuildContainer(with: config)
    }

    func createAgent(name: String, emoji: String) throws -> AgentProfile {
        let profile = try AgentStore.createAgent(name: name, emoji: emoji, defaults: defaults, fileManager: fileManager)
        // Seed new agent with the current model as its initial preference.
        _ = AgentStore.setSelectedModel(container.config.selectedLLMModelID, for: profile.id, defaults: defaults)
        _ = AgentStore.setActiveAgent(profile.id, defaults: defaults)
        try AgentTemplateWriter.writeAgentFile(
            at: profile.workspaceURL,
            name: profile.name,
            emoji: profile.emoji
        )
        rebuildContainer(with: container.config)
        return profile
    }

    func createAgents(from presets: [AgentPreset], callName: String, context: String) throws -> [AgentProfile] {
        var createdProfiles: [AgentProfile] = []

        do {
            for preset in presets {
                let profile = try AgentStore.createAgent(
                    name: preset.agentName,
                    emoji: preset.agentEmoji,
                    defaults: defaults,
                    fileManager: fileManager
                )
                try AgentTemplateWriter.writeUserFile(
                    at: profile.workspaceURL,
                    callName: callName,
                    context: context
                )
                try AgentTemplateWriter.writeSoulFile(
                    at: profile.workspaceURL,
                    coreTruths: preset.soulCoreTruths
                )
                try AgentTemplateWriter.writeAgentFile(
                    at: profile.workspaceURL,
                    name: preset.agentName,
                    emoji: preset.agentEmoji,
                    vibe: preset.agentVibe
                )
                _ = AgentStore.setSelectedModel(container.config.selectedLLMModelID, for: profile.id, defaults: defaults)
                createdProfiles.append(profile)
            }
        } catch {
            for profile in createdProfiles.reversed() {
                _ = AgentStore.deleteAgent(profile.id, defaults: defaults, fileManager: fileManager)
            }
            rebuildContainer(with: container.config)
            throw error
        }

        if let firstCreated = createdProfiles.first {
            _ = AgentStore.setActiveAgent(firstCreated.id, defaults: defaults)
        }

        rebuildContainer(with: container.config)
        return createdProfiles
    }

    @discardableResult
    func createTeam(
        name: String,
        emoji: String = "👥",
        description: String? = nil,
        agentIDs: [UUID] = [],
        leadAgentID: UUID? = nil,
        defaultTopology: TeamTopologyKind = .automatic
    ) -> TeamProfile? {
        let team = TeamStore.createTeam(
            name: name,
            emoji: emoji,
            description: description,
            agentPoolIDs: agentIDs,
            leadAgentID: leadAgentID,
            defaultTopology: defaultTopology,
            defaults: defaults
        )
        if team != nil {
            reloadTeamState()
        }
        return team
    }

    @discardableResult
    func updateTeam(_ teamID: UUID, name: String, emoji: String, description: String?) -> TeamProfile? {
        let team = TeamStore.updateTeam(teamID, name: name, emoji: emoji, description: description, defaults: defaults)
        if team != nil {
            reloadTeamState()
        }
        return team
    }

    @discardableResult
    func addAgents(_ agentIDs: [UUID], toTeam teamID: UUID) -> TeamProfile? {
        let team = TeamStore.addAgents(agentIDs, to: teamID, defaults: defaults)
        if team != nil {
            reloadTeamState()
        }
        return team
    }

    @discardableResult
    func removeAgent(_ agentID: UUID, fromTeam teamID: UUID) -> TeamProfile? {
        let team = TeamStore.removeAgent(agentID, from: teamID, defaults: defaults)
        if team != nil {
            reloadTeamState()
        }
        return team
    }

    @discardableResult
    func setLeadAgent(_ agentID: UUID?, forTeam teamID: UUID) -> TeamProfile? {
        let team = TeamStore.setLeadAgent(agentID, for: teamID, defaults: defaults)
        if team != nil {
            reloadTeamState()
        }
        return team
    }

    func deleteTeam(_ teamID: UUID) {
        TeamStore.deleteTeam(teamID, defaults: defaults)
        reloadTeamState()
    }

    @discardableResult
    func setActiveAgent(_ agentID: UUID) -> Bool {
        let changed = AgentStore.setActiveAgent(agentID, defaults: defaults)
        if changed {
            rebuildContainer(with: container.config)
        }
        return changed
    }

    @discardableResult
    func setSelectedSessionKey(_ sessionKey: String?, for agentID: UUID) -> Bool {
        let changed = AgentStore.setSelectedSession(sessionKey, for: agentID, defaults: defaults)
        if changed {
            agentState = AgentStore.load(defaults: defaults, fileManager: fileManager)
        }
        return changed
    }

    @discardableResult
    func setAutoCompact(_ enabled: Bool) -> Bool {
        guard let activeAgentID = activeAgent?.id else { return false }
        let changed = AgentStore.setAutoCompact(enabled, for: activeAgentID, defaults: defaults)
        if changed {
            agentState = AgentStore.load(defaults: defaults, fileManager: fileManager)
        }
        return changed
    }

    @discardableResult
    func deleteAgent(_ agentID: UUID) -> Bool {
        let changed = AgentStore.deleteAgent(agentID, defaults: defaults, fileManager: fileManager)
        if changed {
            TeamStore.removeAgentReferences(agentID, defaults: defaults)
            reloadTeamState()
            rebuildContainer(with: container.config)
        }
        return changed
    }

    @discardableResult
    func renameActiveAgent(to name: String) -> Bool {
        guard let activeAgent else { return false }
        let previousName = activeAgent.name

        guard let renamedProfile = AgentStore.renameAgent(
            agentID: activeAgent.id,
            name: name,
            defaults: defaults,
            fileManager: fileManager
        ) else {
            return false
        }

        do {
            try AgentTemplateWriter.syncIdentityName(
                at: renamedProfile.workspaceURL,
                name: renamedProfile.name
            )
            rebuildContainer(with: container.config)
            return true
        } catch {
            // Roll back rename when identity sync fails to keep metadata consistent.
            _ = AgentStore.renameAgent(
                agentID: activeAgent.id,
                name: previousName,
                defaults: defaults,
                fileManager: fileManager
            )
            rebuildContainer(with: container.config)
            return false
        }
    }

    private func rebuildContainer(with baseConfig: AppConfig) {
        agentState = AgentStore.load(defaults: defaults, fileManager: fileManager)
        let resolvedConfig = Self.applyAgent(to: baseConfig, state: agentState)
        container = AppContainer.make(config: resolvedConfig)
    }

    private func reloadTeamState() {
        teamState = TeamStore.load(defaults: defaults)
        TeamSwarmCoordinator.shared.reload()
    }

    private static func applyAgent(to baseConfig: AppConfig, state: AgentStateSnapshot) -> AppConfig {
        var config = baseConfig

        // Keep selected model id valid even before an active agent is resolved.
        config.agent.selectedLLMModelID = Self.resolveSelectedModelID(
            in: config.llmCollection,
            preferredID: config.agent.selectedLLMModelID
        )

        guard let activeAgent = state.activeAgent else {
            return config
        }

        // Prefer the active agent model, then fallback to first available model.
        let resolvedSelectedModelID = Self.resolveSelectedModelID(
            in: config.llmCollection,
            preferredID: activeAgent.selectedModelID
        )

        config.agent = AppConfig.Agent(
            id: activeAgent.id.uuidString,
            name: activeAgent.name,
            emoji: activeAgent.emoji,
            selectedLLMModelID: resolvedSelectedModelID,
            workspaceRootURL: activeAgent.workspaceURL,
            runtimeRootURL: activeAgent.runtimeURL
        )

        return config
    }

    private static func resolveSelectedModelID(
        in collection: AppConfig.LLMCollection,
        preferredID: UUID?
    ) -> UUID? {
        if let preferredID,
           collection.models.contains(where: { $0.id == preferredID })
        {
            return preferredID
        }

        return collection.models.first?.id
    }
}
