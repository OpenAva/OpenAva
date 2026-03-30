import SwiftUI

private struct AppContainerStoreEnvironmentKey: EnvironmentKey {
    static let defaultValue = AppContainerStore(container: .makeDefault())
}

extension EnvironmentValues {
    var appContainerStore: AppContainerStore {
        get { self[AppContainerStoreEnvironmentKey.self] }
        set { self[AppContainerStoreEnvironmentKey.self] = newValue }
    }

    var appContainer: AppContainer {
        get { appContainerStore.container }
        set { appContainerStore = AppContainerStore(container: newValue) }
    }

    var appLocalization: LocalizationService {
        appContainerStore.container.services.localization
    }

    var appWindowCoordinator: AppWindowCoordinator {
        get { self[AppWindowCoordinatorEnvironmentKey.self] }
        set { self[AppWindowCoordinatorEnvironmentKey.self] = newValue }
    }
}

private struct AppWindowCoordinatorEnvironmentKey: EnvironmentKey {
    static let defaultValue = AppWindowCoordinator()
}
