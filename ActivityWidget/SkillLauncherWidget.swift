import AppIntents
import OpenClawKit
import SwiftUI
import WidgetKit

struct SkillLauncherEntry: TimelineEntry {
    let date: Date
    let configuration: SkillLauncherWidgetIntent
}

struct SkillLauncherProvider: AppIntentTimelineProvider {
    func placeholder(in _: Context) -> SkillLauncherEntry {
        SkillLauncherEntry(date: Date(), configuration: .defaultIntent)
    }

    func snapshot(for configuration: SkillLauncherWidgetIntent, in _: Context) async -> SkillLauncherEntry {
        SkillLauncherEntry(date: Date(), configuration: configuration)
    }

    func timeline(for configuration: SkillLauncherWidgetIntent, in _: Context) async -> Timeline<SkillLauncherEntry> {
        let entry = SkillLauncherEntry(date: Date(), configuration: configuration)
        let nextRefresh = Calendar.current.date(byAdding: .hour, value: 1, to: Date()) ?? Date().addingTimeInterval(3600)
        return Timeline(entries: [entry], policy: .after(nextRefresh))
    }
}

struct SkillLauncherWidget: Widget {
    private let kind = "SkillLauncherWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: SkillLauncherWidgetIntent.self, provider: SkillLauncherProvider()) { entry in
            SkillLauncherWidgetView(entry: entry)
        }
        .configurationDisplayName("widget.skillLauncher.configurationDisplayName")
        .description("widget.skillLauncher.configurationDescription")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

private struct SkillLauncherWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SkillLauncherEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("widget.skillLauncher.heading")
                .font(.headline)

            ForEach(actions) { action in
                Button(intent: LaunchSkillFromWidgetIntent(skillID: action.skillID, task: action.task ?? "")) {
                    HStack(spacing: 6) {
                        if let emoji = action.emoji {
                            Text(emoji)
                        } else {
                            Image(systemName: action.icon)
                        }

                        Text(action.title)
                            .lineLimit(1)

                        Spacer(minLength: 0)
                    }
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }

            if actions.isEmpty {
                Text(emptyStateText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .containerBackground(.fill.tertiary, for: .widget)
    }

    private var actions: [SkillWidgetAction] {
        entry.configuration.actions(limit: maxActionCount)
    }

    private var maxActionCount: Int {
        family == .systemSmall ? 2 : 3
    }

    private var emptyStateText: String {
        guard let snapshot = SkillLauncherCatalogStore.load() else {
            return widgetString("widget.skillLauncher.empty.sync")
        }
        if snapshot.agentID == nil, snapshot.skills.isEmpty {
            return widgetString("widget.skillLauncher.empty.noAgent")
        }
        return widgetString("widget.skillLauncher.empty.selectSkill")
    }
}

struct SkillLauncherWidgetIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "widget.skillLauncher.intent.title"
    static let description = IntentDescription("widget.skillLauncher.intent.description")

    @Parameter(title: "widget.skillLauncher.parameter.skill1", optionsProvider: SkillLauncherSkillOptionsProvider())
    var firstSkillID: String?

    @Parameter(title: "widget.skillLauncher.parameter.task1")
    var firstTask: String?

    @Parameter(title: "widget.skillLauncher.parameter.skill2", optionsProvider: SkillLauncherSkillOptionsProvider())
    var secondSkillID: String?

    @Parameter(title: "widget.skillLauncher.parameter.task2")
    var secondTask: String?

    @Parameter(title: "widget.skillLauncher.parameter.skill3", optionsProvider: SkillLauncherSkillOptionsProvider())
    var thirdSkillID: String?

    @Parameter(title: "widget.skillLauncher.parameter.task3")
    var thirdTask: String?

    init() {
        firstSkillID = nil
        firstTask = nil
        secondSkillID = nil
        secondTask = nil
        thirdSkillID = nil
        thirdTask = nil
    }

    static var defaultIntent: SkillLauncherWidgetIntent {
        SkillLauncherWidgetIntent()
    }

    fileprivate func actions(limit: Int) -> [SkillWidgetAction] {
        guard let snapshot = SkillLauncherCatalogStore.load() else {
            return []
        }
        let summariesByID = Dictionary(uniqueKeysWithValues: snapshot.skills.map { ($0.id, $0) })
        let candidates: [(slot: Int, skillID: String?, task: String?)] = [
            (0, firstSkillID, firstTask),
            (1, secondSkillID, secondTask),
            (2, thirdSkillID, thirdTask),
        ]

        let actions = candidates.compactMap { candidate -> SkillWidgetAction? in
            guard let normalizedSkillID = Self.nonEmpty(candidate.skillID) else {
                return nil
            }
            guard let summary = summariesByID[normalizedSkillID] else {
                return nil
            }
            return SkillWidgetAction(slot: candidate.slot, summary: summary, task: Self.nonEmpty(candidate.task))
        }

        return Array(actions.prefix(max(0, limit)))
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct SkillLauncherSkillOptionsProvider: DynamicOptionsProvider {
    func results() async throws -> [String] {
        SkillLauncherCatalogStore.load()?.skills.map(\.id) ?? []
    }
}

struct LaunchSkillFromWidgetIntent: AppIntent {
    static let title: LocalizedStringResource = "widget.skillLauncher.launchIntent.title"
    static let description = IntentDescription("widget.skillLauncher.launchIntent.description")
    static let openAppWhenRun = true

    @Parameter(title: "widget.skillLauncher.launchIntent.parameter.skillID")
    var skillID: String

    @Parameter(title: "widget.skillLauncher.launchIntent.parameter.task", default: "")
    var task: String

    init() {}

    init(skillID: String, task: String) {
        self.skillID = skillID
        self.task = task
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let normalizedSkillID = skillID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSkillID.isEmpty else {
            throw SkillLauncherWidgetError.emptySkill
        }

        let normalizedTask = task.trimmingCharacters(in: .whitespacesAndNewlines)
        PendingChatLaunchRequestStore.enqueue(
            PendingChatLaunchRequest(
                skillID: normalizedSkillID,
                task: normalizedTask.isEmpty ? nil : normalizedTask,
                source: .widget
            )
        )

        let displayName = SkillLauncherCatalogStore.load()?
            .skills
            .first(where: { $0.id == normalizedSkillID })?
            .displayName
            ?? SkillLauncherPresetCatalog.fallbackDisplayName(for: normalizedSkillID)
        return .result(value: displayName)
    }
}

private struct SkillWidgetAction: Identifiable {
    let id: String
    let skillID: String
    let title: String
    let emoji: String?
    let icon: String
    let task: String?

    init(slot: Int, summary: SkillLauncherSkillSummary, task: String?) {
        id = "slot-\(slot)-\(summary.id)"
        skillID = summary.id
        title = summary.displayName
        emoji = Self.nonEmpty(summary.emoji)
        icon = summary.iconName
        self.task = task
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private enum SkillLauncherWidgetError: LocalizedError {
    case emptySkill

    var errorDescription: String? {
        switch self {
        case .emptySkill:
            widgetString("widget.skillLauncher.error.emptySkill")
        }
    }
}

private func widgetString(_ key: String) -> String {
    NSLocalizedString(key, tableName: "Localizable", bundle: .main, value: key, comment: "")
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard indices.contains(index) else {
            return nil
        }
        return self[index]
    }
}
