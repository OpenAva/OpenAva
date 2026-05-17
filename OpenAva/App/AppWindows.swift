import SwiftUI

enum AppWindowID {
    static let settings = "openava.settings"
    static let agentCreation = "openava.agentCreation"
}

/// Encodes the source main-window scene into standalone Catalyst window payloads.
///
/// The source scene is required because standalone `WindowGroup`s do not inherit
/// the opener's `AppContainerStore`. It lets the auxiliary window operate on
/// the same window-scoped store and workspace as the opener without introducing
/// one app-global workspace store.
enum AppWindowRoute {
    private static let separator = "|"

    static func settingsPayload(sceneID: String, section: SettingsWindowSection) -> String {
        [sceneID, section.rawValue].joined(separator: separator)
    }

    static func settingsPayload(defaultSection section: SettingsWindowSection) -> String {
        settingsPayload(sceneID: "", section: section)
    }

    static func parseSettingsPayload(_ payload: String) -> (sceneID: String?, section: SettingsWindowSection) {
        let parts = payload.split(separator: separator, maxSplits: 1, omittingEmptySubsequences: false)
        let sceneID = parts.first.map(String.init).flatMap { $0.isEmpty ? nil : $0 }
        let rawSection = parts.dropFirst().first.map(String.init) ?? payload
        return (
            sceneID,
            SettingsWindowSection(rawValue: rawSection) ?? .llm
        )
    }
}

enum SettingsWindowSection: String, CaseIterable, Hashable, Identifiable {
    case llm
    case skills
    case tools
    case cron

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .llm:
            L10n.tr("settings.llm.navigationTitle")
        case .skills:
            L10n.tr("settings.skills.navigationTitle")
        case .tools:
            L10n.tr("settings.tools.navigationTitle")
        case .cron:
            L10n.tr("settings.cron.navigationTitle")
        }
    }
}

struct SettingsWindowRootView: View {
    @Binding private var payload: String

    init(payload: Binding<String>) {
        _payload = payload
    }

    var body: some View {
        Group {
            if let containerStore = AppSceneStoreRegistry.shared.store(for: route.sceneID) {
                NavigationStack {
                    detailView(for: route.section)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .background(Color.white)
                }
                .environment(\.appContainerStore, containerStore)
            } else {
                MissingWindowSourceView()
            }
        }
        .background(Color.white)
    }

    private var route: (sceneID: String?, section: SettingsWindowSection) {
        AppWindowRoute.parseSettingsPayload(payload)
    }

    @ViewBuilder
    private func detailView(for section: SettingsWindowSection) -> some View {
        switch section {
        case .llm:
            LLMListView()
        case .skills:
            SkillListView()
        case .tools:
            ToolListView()
        case .cron:
            CronListView()
        }
    }
}

struct AgentCreationWindowRootView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding private var sceneID: String

    init(sceneID: Binding<String>) {
        _sceneID = sceneID
    }

    var body: some View {
        Group {
            if let containerStore = AppSceneStoreRegistry.shared.store(for: sceneID) {
                NavigationStack {
                    AgentCreationView {
                        dismiss()
                    }
                }
                .environment(\.appContainerStore, containerStore)
            } else {
                MissingWindowSourceView()
            }
        }
        .background(Color.white)
    }
}

private struct MissingWindowSourceView: View {
    var body: some View {
        ContentUnavailableView(
            L10n.tr("common.error"),
            systemImage: "exclamationmark.triangle",
            description: Text("The originating workspace window is no longer available.")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
