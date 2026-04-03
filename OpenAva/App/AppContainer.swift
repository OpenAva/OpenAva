import ChatClient
import Foundation

struct AppContainer {
    struct Services {
        let localToolInvokeService: LocalToolInvokeService
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
        let localToolInvokeService = LocalToolInvokeService.makeDefault(
            workspaceRootURL: config.agent.workspaceRootURL,
            runtimeRootURL: config.agent.runtimeRootURL,
            modelConfig: config.selectedLLMModel
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
            localToolInvokeService: localToolInvokeService,
            chatClient: chatClient,
            localization: localization
        )
    }
}
