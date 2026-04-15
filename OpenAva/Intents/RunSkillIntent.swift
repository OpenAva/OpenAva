import AppIntents
import Foundation
import OpenClawKit

extension Notification.Name {
    /// Posted when a skill launch request is queued while the app is active.
    static let OpenAvaIntentAutoSend = Notification.Name("com.day1-labs.openava.intentAutoSend")
}

private func currentAppAgent() -> AgentProfile? {
    AgentStore.load().activeAgent
}

struct RunSkillIntent: AppIntent {
    static let title: LocalizedStringResource = "intent.runSkill.meta.title"
    static let description = IntentDescription("intent.runSkill.meta.description")
    static let openAppWhenRun = true

    @Parameter(title: "intent.runSkill.parameter.skill", optionsProvider: SkillNameOptionsProvider())
    var skillID: String

    @Parameter(title: "intent.runSkill.parameter.task", default: "")
    var task: String

    init() {}

    init(skillID: String, task: String = "") {
        self.skillID = skillID
        self.task = task
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let displayName = try SkillLaunchService.enqueueSkillLaunch(
            skillID: skillID,
            task: task,
            source: .shortcut
        )
        return .result(value: L10n.tr("intent.runSkill.triggeredFallback", displayName))
    }
}

struct OpenAvaAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: RunSkillIntent(),
            phrases: [
                "Run skill in \(.applicationName)",
                "Call skill with \(.applicationName)",
                "Let \(.applicationName) execute skill",
            ],
            shortTitle: "intent.runSkill.meta.shortTitle",
            systemImageName: "wand.and.stars"
        )
    }

    static var shortcutTileColor: ShortcutTileColor {
        .purple
    }
}

struct SkillNameOptionsProvider: DynamicOptionsProvider {
    func results() async throws -> [String] {
        let workspaceRoot = currentAppAgent()?.workspaceURL
        return AgentSkillsLoader
            .listSkills(filterUnavailable: true, visibility: .userInvocable, workspaceRootURL: workspaceRoot)
            .map(\.name)
    }
}

enum SkillLaunchService {
    struct PendingAutoSendRequest {
        let id: String
        let message: String
    }

    static func handleDeepLink(url: URL, container _: AppContainer) async {
        guard let route = DeepLinkParser.parse(url) else { return }
        guard case let .agent(link) = route else { return }
        await enqueueAutoSend(message: link.message)
    }

    static func enqueueAutoSend(message: String) async {
        guard let normalizedMessage = nonEmpty(message) else { return }
        PendingChatLaunchRequestStore.enqueue(
            PendingChatLaunchRequest(message: normalizedMessage, source: .deepLink)
        )
        await notifyQueueChanged()
    }

    @discardableResult
    static func enqueueSkillLaunch(skillID: String, task: String?, source: SkillLaunchSource) throws -> String {
        guard let normalizedSkillID = nonEmpty(skillID) else {
            throw SkillInvocationError.emptySkill
        }
        guard let resolvedSkill = resolveSkillDefinition(named: normalizedSkillID) else {
            throw currentAppAgent() == nil
                ? SkillInvocationError.agentUnavailable
                : SkillInvocationError.skillNotFound(normalizedSkillID)
        }

        PendingChatLaunchRequestStore.enqueue(
            PendingChatLaunchRequest(
                skillID: resolvedSkill.name,
                task: nonEmpty(task),
                source: source
            )
        )

        Task { @MainActor in
            NotificationCenter.default.post(name: .OpenAvaIntentAutoSend, object: nil)
        }

        return resolvedSkill.displayName
    }

    static func dequeuePendingAutoSend() -> PendingAutoSendRequest? {
        var queue = PendingChatLaunchRequestStore.loadQueue()
        guard !queue.isEmpty else { return nil }

        let activeAgent = currentAppAgent()
        let workspaceRootURL = activeAgent?.workspaceURL
        var index = 0
        var mutated = false

        while index < queue.count {
            let request = queue[index]

            switch request.kind {
            case .message:
                guard let normalizedMessage = nonEmpty(request.message) else {
                    queue.remove(at: index)
                    mutated = true
                    continue
                }
                guard activeAgent != nil else {
                    if mutated {
                        PendingChatLaunchRequestStore.saveQueue(queue)
                    }
                    return nil
                }
                queue.remove(at: index)
                PendingChatLaunchRequestStore.saveQueue(queue)
                return PendingAutoSendRequest(id: request.id, message: normalizedMessage)

            case .skill:
                guard activeAgent != nil else {
                    if mutated {
                        PendingChatLaunchRequestStore.saveQueue(queue)
                    }
                    return nil
                }
                guard let normalizedSkillID = nonEmpty(request.skillID) else {
                    queue.remove(at: index)
                    mutated = true
                    continue
                }
                guard let resolvedSkill = resolveSkillDefinition(
                    named: normalizedSkillID,
                    workspaceRootURL: workspaceRootURL
                ) else {
                    queue.remove(at: index)
                    mutated = true
                    continue
                }
                let message = makeInvocationMessage(skillName: resolvedSkill.name, task: request.task)
                queue.remove(at: index)
                PendingChatLaunchRequestStore.saveQueue(queue)
                return PendingAutoSendRequest(id: request.id, message: message)
            }
        }

        if mutated {
            PendingChatLaunchRequestStore.saveQueue(queue)
        }
        return nil
    }

    static func makeInvocationMessage(skillName: String, task: String?) -> String {
        let escapedSkill = escapeSlashArgument(skillName)
        guard let resolvedTask = nonEmpty(task) else {
            return "/\(escapedSkill) "
        }
        let escapedTask = escapeSlashArgument(resolvedTask)
        return "/\(escapedSkill) \(escapedTask)"
    }

    private static func resolveSkillDefinition(
        named requestedName: String,
        workspaceRootURL: URL? = currentAppAgent()?.workspaceURL
    ) -> AgentSkillsLoader.SkillDefinition? {
        AgentSkillsLoader.resolveSkill(
            named: requestedName,
            visibility: .userInvocable,
            filterUnavailable: true,
            workspaceRootURL: workspaceRootURL
        )
    }

    private static func nonEmpty(_ text: String?) -> String? {
        let trimmed = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func escapeSlashArgument(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let escaped = trimmed.replacingOccurrences(of: "\"", with: "\\\"")
        guard escaped.contains(where: \.isWhitespace) else {
            return escaped
        }
        return "\"\(escaped)\""
    }

    @MainActor
    private static func notifyQueueChanged() {
        NotificationCenter.default.post(name: .OpenAvaIntentAutoSend, object: nil)
    }
}

enum SkillInvocationError: LocalizedError {
    case emptySkill
    case skillNotFound(String)
    case agentUnavailable

    var errorDescription: String? {
        switch self {
        case .emptySkill:
            L10n.tr("intent.runSkill.error.emptySkill")
        case let .skillNotFound(name):
            L10n.tr("intent.runSkill.error.skillNotFound", name)
        case .agentUnavailable:
            L10n.tr("intent.runSkill.error.agentUnavailable")
        }
    }
}
