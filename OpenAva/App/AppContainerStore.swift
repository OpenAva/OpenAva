import Foundation
import Observation

@MainActor
@Observable
final class AppContainerStore {
    private(set) var container: AppContainer
    private(set) var agentState: AgentStateSnapshot
    private(set) var preferredLanguageCode: String?
    private(set) var resolvedLanguageCode: String

    var activeAgent: AgentProfile? {
        agentState.activeAgent
    }

    var agents: [AgentProfile] {
        agentState.agents
    }

    var hasAgent: Bool {
        agentState.hasAgent
    }

    var activeAgentWorkspaceURL: URL? {
        activeAgent?.workspaceURL
    }

    init(container: AppContainer) {
        self.container = container
        agentState = AgentStore.load()
        // Migration: clear stale explicit "en" override left from early development.
        // English is the fallback — storing it explicitly blocks system language negotiation.
        AppLanguagePreference.clearStaleEnglishOverride()
        preferredLanguageCode = AppLanguagePreference.userPreferredLanguageCode()
        resolvedLanguageCode = LocaleResolver.currentLanguageCode()
        rebuildContainer(with: container.config)
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
            _ = AgentStore.setSelectedModel(id, for: activeAgentID)
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
        AgentStore.repairSelectedModel(afterDeleting: id, replacement: updatedCollection.models.first?.id)
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
        let profile = try AgentStore.createAgent(name: name, emoji: emoji)
        // Seed new agent with the current model as its initial preference.
        _ = AgentStore.setSelectedModel(container.config.selectedLLMModelID, for: profile.id)
        _ = AgentStore.setActiveAgent(profile.id)
        try AgentTemplateWriter.writeAgentFile(
            at: profile.workspaceURL,
            name: profile.name,
            emoji: profile.emoji
        )
        rebuildContainer(with: container.config)
        return profile
    }

    @discardableResult
    func setActiveAgent(_ agentID: UUID) -> Bool {
        let changed = AgentStore.setActiveAgent(agentID)
        if changed {
            rebuildContainer(with: container.config)
        }
        return changed
    }

    @discardableResult
    func setSelectedSessionKey(_ sessionKey: String?, for agentID: UUID) -> Bool {
        let changed = AgentStore.setSelectedSession(sessionKey, for: agentID)
        if changed {
            agentState = AgentStore.load()
        }
        return changed
    }

    @discardableResult
    func deleteAgent(_ agentID: UUID) -> Bool {
        let changed = AgentStore.deleteAgent(agentID)
        if changed {
            rebuildContainer(with: container.config)
        }
        return changed
    }

    @discardableResult
    func renameActiveAgent(to name: String) -> Bool {
        guard let activeAgent else { return false }
        let previousName = activeAgent.name

        guard let renamedProfile = AgentStore.renameAgent(agentID: activeAgent.id, name: name) else {
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
            _ = AgentStore.renameAgent(agentID: activeAgent.id, name: previousName)
            rebuildContainer(with: container.config)
            return false
        }
    }

    private func rebuildContainer(with baseConfig: AppConfig) {
        agentState = AgentStore.load()
        let resolvedConfig = Self.applyAgent(to: baseConfig, state: agentState)
        container = AppContainer.make(config: resolvedConfig)
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
