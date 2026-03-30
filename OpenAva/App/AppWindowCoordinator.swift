import Combine
import SwiftUI

enum AppWindowID {
    static let settings = "openava.settings"
    static let agentCreation = "openava.agentCreation"
}

enum SettingsWindowSection: String, CaseIterable, Hashable, Identifiable {
    case llm
    case skills
    case context
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
        case .context:
            L10n.tr("settings.context.navigationTitle")
        case .cron:
            L10n.tr("settings.cron.navigationTitle")
        }
    }
}

final class AppWindowCoordinator: ObservableObject {
    @Published private(set) var settingsSelection: SettingsWindowSection = .llm
    @Published private(set) var settingsRequestID: Int = 0
    @Published private(set) var agentCreationRequestID: Int = 0

    func openSettings(_ section: SettingsWindowSection) {
        settingsSelection = section
        settingsRequestID &+= 1
    }

    func openAgentCreation() {
        agentCreationRequestID &+= 1
    }
}

struct SettingsWindowRootView: View {
    @Environment(\.appWindowCoordinator) private var windowCoordinator
    @State private var selection: SettingsWindowSection = .llm

    var body: some View {
        NavigationStack {
            detailView(for: selection)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color.white)
        }
        .background(Color.white)
        .onAppear {
            selection = windowCoordinator.settingsSelection
        }
        .onChange(of: windowCoordinator.settingsRequestID) { _, _ in
            selection = windowCoordinator.settingsSelection
        }
    }

    @ViewBuilder
    private func detailView(for section: SettingsWindowSection) -> some View {
        switch section {
        case .llm:
            LLMListView()
        case .skills:
            SkillListView()
        case .context:
            ContextSettingsView()
        case .cron:
            CronListView()
        }
    }
}

struct AgentCreationWindowRootView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        AgentCreationView(onComplete: {
            dismiss()
        })
        .background(Color.white)
    }
}
