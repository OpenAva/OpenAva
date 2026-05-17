import Foundation

@MainActor
/// Maps auxiliary Catalyst windows back to the main window that opened them.
///
/// Each main window owns its own `AppContainerStore`, and that store owns the
/// active workspace for that window. Auxiliary windows such as settings or
/// agent creation do not inherit the opener's SwiftUI environment, so they pass
/// a scene-scoped identifier through `openWindow` and resolve the matching
/// store here. The scene ID is a UI/window instance key, not a workspace ID.
final class AppSceneStoreRegistry {
    static let shared = AppSceneStoreRegistry()

    /// Weak values keep this registry from extending a closed window's lifetime.
    private var stores: [String: WeakStore] = [:]

    private init() {}

    func register(_ store: AppContainerStore, sceneID: String) {
        pruneReleasedStores()
        stores[sceneID] = WeakStore(store)
    }

    func unregister(sceneID: String, store: AppContainerStore) {
        guard stores[sceneID]?.value === store else { return }
        stores.removeValue(forKey: sceneID)
    }

    func store(for sceneID: String?) -> AppContainerStore? {
        pruneReleasedStores()
        guard let sceneID, !sceneID.isEmpty else { return nil }
        return stores[sceneID]?.value
    }

    private func pruneReleasedStores() {
        stores = stores.filter { $0.value.value != nil }
    }
}

private final class WeakStore {
    weak var value: AppContainerStore?

    init(_ value: AppContainerStore) {
        self.value = value
    }
}
