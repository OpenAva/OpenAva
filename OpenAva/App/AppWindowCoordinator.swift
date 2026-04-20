import Combine
import Foundation
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
    @Published private(set) var agentCreationRequestID: Int = 0
    @Published private(set) var agentCreationMode: AgentCreationViewModel.CreationMode = .singleAgent

    func openAgentCreation() {
        agentCreationMode = .singleAgent
        agentCreationRequestID &+= 1
    }
}

struct SettingsWindowRootView: View {
    @Binding private var sectionID: String

    init(sectionID: Binding<String>) {
        _sectionID = sectionID
    }

    var body: some View {
        NavigationStack {
            detailView(for: section)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color.white)
        }
        .background(Color.white)
    }

    private var section: SettingsWindowSection {
        guard let section = SettingsWindowSection(rawValue: sectionID)
        else {
            return .llm
        }
        return section
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
    @Environment(\.appWindowCoordinator) private var windowCoordinator

    var body: some View {
        NavigationStack {
            AgentCreationView(
                initialMode: windowCoordinator.agentCreationMode,
                onComplete: {
                    dismiss()
                }
            )
        }
        .background(Color.white)
    }
}
