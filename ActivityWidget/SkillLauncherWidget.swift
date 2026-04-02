import AppIntents
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
        .configurationDisplayName("OpenAva Skill")
        .description("一键调用常用技能")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

private struct SkillLauncherWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SkillLauncherEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("OpenAva Skills")
                .font(.headline)

            ForEach(actions) { action in
                Link(destination: action.deepLinkURL) {
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
            }

            if actions.isEmpty {
                Text("请在编辑小组件中选择技能")
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
}

struct SkillLauncherWidgetIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Skill Launcher"
    static let description = IntentDescription("配置小组件里要快速调用的技能。")

    @Parameter(title: "会话")
    var sessionKey: String?

    @Parameter(title: "技能 1", optionsProvider: SkillLauncherSkillOptionsProvider())
    var firstSkill: String?

    @Parameter(title: "任务 1")
    var firstTask: String?

    @Parameter(title: "技能 2", optionsProvider: SkillLauncherSkillOptionsProvider())
    var secondSkill: String?

    @Parameter(title: "任务 2")
    var secondTask: String?

    @Parameter(title: "技能 3", optionsProvider: SkillLauncherSkillOptionsProvider())
    var thirdSkill: String?

    @Parameter(title: "任务 3")
    var thirdTask: String?

    init() {
        let defaults = SkillLauncherSkillCatalog.defaultSkills()
        sessionKey = "main"
        firstSkill = defaults[safe: 0] ?? "coding-agent"
        firstTask = "请快速实现我当前会话里的开发任务。"
        secondSkill = defaults[safe: 1] ?? "github"
        secondTask = "帮我查询当前仓库待处理的 PR 和 CI 状态。"
        thirdSkill = defaults[safe: 2] ?? "i-clarify"
        thirdTask = "请把下面文本改写得更清晰易懂。"
    }

    static var defaultIntent: SkillLauncherWidgetIntent {
        SkillLauncherWidgetIntent()
    }

    fileprivate func actions(limit: Int) -> [SkillWidgetAction] {
        let candidates: [(String?, String?)] = [
            (firstSkill, firstTask),
            (secondSkill, secondTask),
            (thirdSkill, thirdTask),
        ]

        let session = Self.nonEmpty(sessionKey) ?? "main"
        var actions: [SkillWidgetAction] = []

        for (skill, task) in candidates {
            guard let normalizedSkill = Self.nonEmpty(skill) else {
                continue
            }
            guard SkillLauncherSkillCatalog.isUserInvocable(normalizedSkill) else {
                continue
            }

            actions.append(
                SkillWidgetAction(
                    skill: normalizedSkill,
                    title: SkillLauncherSkillCatalog.displayTitle(for: normalizedSkill),
                    emoji: SkillLauncherSkillCatalog.emoji(for: normalizedSkill),
                    icon: SkillLauncherSkillCatalog.iconName(for: normalizedSkill),
                    task: Self.nonEmpty(task),
                    sessionKey: session
                )
            )
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
        SkillLauncherSkillCatalog.availableSkillNames()
    }
}

private struct SkillWidgetAction: Identifiable {
    let id: String
    let skill: String
    let title: String
    let emoji: String?
    let icon: String
    let task: String?
    let sessionKey: String

    init(skill: String, title: String, emoji: String?, icon: String, task: String?, sessionKey: String) {
        self.skill = skill
        self.title = title
        self.emoji = Self.nonEmpty(emoji)
        self.icon = icon
        self.task = task
        self.sessionKey = sessionKey
        id = "\(skill)|\(task ?? "")|\(sessionKey)"
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var deepLinkURL: URL {
        var components = URLComponents()
        components.scheme = "openava"
        components.host = "agent"
        components.queryItems = [
            URLQueryItem(name: "sessionKey", value: sessionKey),
            URLQueryItem(name: "thinking", value: "low"),
            URLQueryItem(name: "message", value: message),
        ]
        return components.url ?? URL(string: "openava://agent?message=%3Copenava-skill-invocation%3E%0A%3Cskill%3Eskill%3C%2Fskill%3E%0A%3Ctask%3ERun%20a%20minimal%20example.%3C%2Ftask%3E%0A%3C%2Fopenava-skill-invocation%3E")!
    }

    private var message: String {
        let resolvedTask = task ?? "执行一个最小可行示例，并简要说明结果。"
        return [
            "<openava-skill-invocation>",
            "<skill>\(escapeXML(skill))</skill>",
            "<task>\(escapeXML(resolvedTask))</task>",
            "</openava-skill-invocation>",
        ].joined(separator: "\n")
    }

    private func escapeXML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

private enum SkillLauncherSkillCatalog {
    private struct SkillMetadata {
        let title: String?
        let emoji: String?
        let userInvocable: Bool
    }

    private static let skillFileName = "SKILL.md"
    private static let fallbackSkills = ["coding-agent", "github", "i-clarify"]
    private static let iconMappings: [String: String] = [
        "coding-agent": "hammer.fill",
        "github": "chevron.left.forwardslash.chevron.right",
        "i-clarify": "text.bubble",
        "i-frontend-design": "paintbrush.pointed.fill",
        "i-polish": "wand.and.stars",
        "i-optimize": "speedometer",
        "discord": "message.fill",
        "gemini": "sparkles",
    ]
    private static let titleMappings: [String: String] = [
        "coding-agent": "编码",
        "github": "GitHub",
        "i-clarify": "润色",
    ]

    static func defaultSkills() -> [String] {
        var values: [String] = []
        for name in availableSkillNames() where values.count < 3 {
            if !values.contains(name) {
                values.append(name)
            }
        }

        for name in fallbackSkills where values.count < 3 {
            if !values.contains(name) {
                values.append(name)
            }
        }
        return values
    }

    static func availableSkillNames() -> [String] {
        let fileManager = FileManager.default
        var names: [String] = []

        // Try common skill folders from both bundle resources and writable app directories.
        for directory in candidateDirectories(fileManager: fileManager) {
            guard let entries = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
            else {
                continue
            }

            for entry in entries {
                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: entry.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                    continue
                }

                let skillPath = entry.appendingPathComponent(skillFileName)
                guard fileManager.fileExists(atPath: skillPath.path) else {
                    continue
                }

                let name = entry.lastPathComponent
                if isUserInvocableSkill(at: skillPath), !names.contains(name) {
                    names.append(name)
                }
            }
        }

        for fallback in fallbackSkills where !names.contains(fallback) {
            names.append(fallback)
        }

        return names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    static func displayTitle(for skill: String) -> String {
        if let title = discoveredSkills()[skill]?.title, !title.isEmpty {
            return title
        }

        if let mapped = titleMappings[skill] {
            return mapped
        }

        let normalized = skill
            .split(separator: "-")
            .map { piece in
                let lower = piece.lowercased()
                return lower.prefix(1).uppercased() + lower.dropFirst()
            }
            .joined(separator: " ")

        return normalized.isEmpty ? skill : normalized
    }

    static func emoji(for skill: String) -> String? {
        discoveredSkills()[skill]?.emoji
    }

    static func isUserInvocable(_ skill: String) -> Bool {
        discoveredSkills()[skill]?.userInvocable ?? false
    }

    static func iconName(for skill: String) -> String {
        iconMappings[skill] ?? "wand.and.stars"
    }

    private static func discoveredSkills() -> [String: SkillMetadata] {
        let fileManager = FileManager.default
        var skills: [String: SkillMetadata] = [:]

        for directory in candidateDirectories(fileManager: fileManager) {
            guard let entries = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
            else {
                continue
            }

            for entry in entries {
                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: entry.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                    continue
                }

                let skillPath = entry.appendingPathComponent(skillFileName)
                guard fileManager.fileExists(atPath: skillPath.path) else {
                    continue
                }

                let name = entry.lastPathComponent
                if skills[name] == nil {
                    skills[name] = metadata(at: skillPath, fallbackName: name)
                }
            }
        }

        return skills
    }

    private static func metadata(at url: URL, fallbackName: String) -> SkillMetadata {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            return SkillMetadata(title: nil, emoji: nil, userInvocable: true)
        }

        let frontmatter = parseFrontmatter(content)
        let declaredName = nonEmpty(frontmatter["name"])
        let title = nonEmpty(frontmatter["metadata.display_name"])
            ?? (declaredName?.localizedCaseInsensitiveCompare(fallbackName) == .orderedSame ? nil : declaredName)
            ?? titleMappings[fallbackName]
        let emoji = nonEmpty(frontmatter["metadata.emoji"]) ?? nonEmpty(frontmatter["emoji"])
        let userInvocable = parseBoolean(frontmatter["user-invocable"]) ?? true
        return SkillMetadata(title: title, emoji: emoji, userInvocable: userInvocable)
    }

    private static func isUserInvocableSkill(at url: URL) -> Bool {
        let metadata = metadata(at: url, fallbackName: url.deletingLastPathComponent().lastPathComponent)
        return metadata.userInvocable
    }

    private static func parseFrontmatter(_ content: String) -> [String: String] {
        let normalized = content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        guard lines.first == "---" else {
            return [:]
        }

        var metadata: [String: String] = [:]
        var index = 1

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" {
                break
            }

            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                index += 1
                continue
            }

            guard let separator = trimmed.firstIndex(of: ":") else {
                index += 1
                continue
            }

            let key = trimmed[..<separator].trimmingCharacters(in: .whitespaces).lowercased()
            let valueStart = trimmed.index(after: separator)
            let value = trimmed[valueStart...]
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))

            if key == "metadata", value.isEmpty {
                var blockLines: [String] = []
                var scanIndex = index + 1

                while scanIndex < lines.count {
                    let candidate = lines[scanIndex]
                    let trimmedCandidate = candidate.trimmingCharacters(in: .whitespaces)

                    if trimmedCandidate == "---" {
                        break
                    }

                    if trimmedCandidate.isEmpty {
                        blockLines.append(candidate)
                        scanIndex += 1
                        continue
                    }

                    if leadingWhitespaceCount(candidate) == 0 {
                        break
                    }

                    blockLines.append(candidate)
                    scanIndex += 1
                }

                let metadataBlock = parseMetadataBlock(blockLines)
                for (nestedKey, nestedValue) in metadataBlock {
                    metadata["metadata.\(nestedKey)"] = nestedValue
                }

                index = scanIndex
                continue
            }

            if !key.isEmpty {
                metadata[key] = value
            }

            index += 1
        }

        return metadata
    }

    private static func parseMetadataBlock(_ lines: [String]) -> [String: String] {
        let nonEmpty = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !nonEmpty.isEmpty,
              let baseIndent = nonEmpty.map({ leadingWhitespaceCount($0) }).min()
        else {
            return [:]
        }

        var parsed: [String: String] = [:]

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty,
                  leadingWhitespaceCount(line) == baseIndent,
                  let separator = trimmed.firstIndex(of: ":")
            else {
                continue
            }

            let key = trimmed[..<separator].trimmingCharacters(in: .whitespaces).lowercased()
            let valueStart = trimmed.index(after: separator)
            let value = trimmed[valueStart...]
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))

            guard !key.isEmpty, !value.isEmpty else {
                continue
            }

            parsed[key] = value
        }

        return parsed
    }

    private static func leadingWhitespaceCount(_ line: String) -> Int {
        line.prefix { $0 == " " || $0 == "\t" }.count
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func parseBoolean(_ value: String?) -> Bool? {
        guard let normalized = nonEmpty(value)?.lowercased() else {
            return nil
        }

        switch normalized {
        case "true", "1", "yes", "y", "on":
            return true
        case "false", "0", "no", "n", "off":
            return false
        default:
            return nil
        }
    }

    private static func candidateDirectories(fileManager: FileManager) -> [URL] {
        var candidates: [URL] = []

        if let resourceURL = Bundle.main.resourceURL {
            candidates.append(resourceURL.appendingPathComponent("skills", isDirectory: true))
            candidates.append(
                resourceURL
                    .appendingPathComponent("Runtime", isDirectory: true)
                    .appendingPathComponent("Agent", isDirectory: true)
                    .appendingPathComponent("Skills", isDirectory: true)
            )
        }

        if let documentsDirectory = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
            candidates.append(documentsDirectory.appendingPathComponent("skills", isDirectory: true))
        }

        if let appSupportDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            candidates.append(appSupportDirectory.appendingPathComponent("skills", isDirectory: true))
        }

        return candidates
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard indices.contains(index) else {
            return nil
        }
        return self[index]
    }
}
