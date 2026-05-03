import ChatClient
import Foundation

struct AppContainer {
    struct Services {
        let toolRuntime: ToolRuntime
        let chatClient: (any ChatClient)?
        let localization: LocalizationService
    }

    let config: AppConfig
    let services: Services

    var defaultSessionKey: String {
        config.session.defaultSessionKey
    }

    static func makeDefault() -> AppContainer {
        make(config: .makeDefault())
    }

    static func make(config: AppConfig) -> AppContainer {
        AppContainer(
            config: config,
            services: makeServices(config: config)
        )
    }

    static func makeServices(config: AppConfig) -> Services {
        let agentCount = max(AgentStore.load(workspaceRootURL: config.agent.workspaceRootURL).agents.count, 1)
        let toolRuntime = ToolRuntime.makeDefault(
            workspaceRootURL: config.agent.workspaceRootURL,
            supportRootURL: config.agent.supportRootURL,
            teamsRootURL: TeamStore.storageDirectoryURL(workspaceRootURL: config.agent.workspaceRootURL, createDirectoryIfNeeded: true),
            modelConfig: config.selectedLLMModel,
            agentCount: agentCount
        )
        let localization = LocalizationService()

        // Create ChatClient from the selected LLM model configuration.
        let chatClient: (any ChatClient)? = {
            guard let modelConfig = config.selectedLLMModel,
                  modelConfig.isConfigured
            else {
                return nil
            }
            return LLMChatClient(modelConfig: modelConfig)
        }()

        return Services(
            toolRuntime: toolRuntime,
            chatClient: chatClient,
            localization: localization
        )
    }
}
