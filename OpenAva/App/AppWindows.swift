import SwiftUI

enum AppWindowID {
    static let settings = "openava.settings"
    static let agentCreation = "openava.agentCreation"
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
        SettingsWindowSection(rawValue: sectionID) ?? .llm
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

    var body: some View {
        NavigationStack {
            AgentCreationView {
                dismiss()
            }
        }
        .background(Color.white)
    }
}
