import AppIntents
import Foundation
import OpenClawKit

extension Notification.Name {
    /// Posted when a skill intent wants the chat UI to auto-send a message.
    static let OpenAvaIntentAutoSend = Notification.Name("com.day1-labs.openava.intentAutoSend")
}

struct RunSkillIntent: AppIntent {
    static let title: LocalizedStringResource = "Run OpenAva Skill"
    static let description = IntentDescription("Trigger OpenAva skill via Siri, Shortcuts, or widgets.")
    /// Open the app so the skill runs through the real agentic loop in the chat UI.
    static let openAppWhenRun = true

    @Parameter(title: "Skill", optionsProvider: SkillNameOptionsProvider())
    var skill: String

    @Parameter(title: "Task", default: "")
    var task: String

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let normalizedSkill = Self.normalizedSkillLabel(skill)
        guard !normalizedSkill.isEmpty else {
            throw SkillInvocationError.emptySkill
        }
        let normalizedTask = task.trimmingCharacters(in: .whitespacesAndNewlines)

        // Resolve skill using the active agent's workspace.
        let container = await MainActor.run {
            AppContainerStore(container: .makeDefault()).container
        }
        let availableSkills = AgentSkillsLoader.listSkills(
            filterUnavailable: true,
            visibility: .userInvocable,
            workspaceRootURL: container.config.agent.workspaceRootURL
        )
        let resolvedSkill = availableSkills.first(where: { $0.name == normalizedSkill })
            ?? availableSkills.first(where: { $0.displayName.localizedCaseInsensitiveCompare(normalizedSkill) == .orderedSame })
        guard let resolvedSkill else {
            throw SkillInvocationError.skillNotFound(normalizedSkill)
        }

        // Build a structured invocation block so the runtime can treat this as
        // an explicit skill request instead of a best-effort natural-language hint.
        let message = SkillLaunchService.makeInvocationMessage(
            skillName: resolvedSkill.name,
            task: normalizedTask.isEmpty ? nil : normalizedTask
        )

        // Enqueue for auto-send via the chat UI (same agentic loop as manual input).
        await SkillLaunchService.enqueueAutoSend(message: message)

        return .result(value: L10n.tr("intent.runSkill.triggeredFallback", resolvedSkill.displayName))
    }
}

extension RunSkillIntent {
    private static func normalizedSkillLabel(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let separator = trimmed.firstIndex(of: " ") else {
            return trimmed
        }

        let prefix = String(trimmed[..<separator])
        guard prefix.unicodeScalars.contains(where: { $0.properties.isEmojiPresentation || $0.properties.isEmoji }) else {
            return trimmed
        }

        let candidate = trimmed[trimmed.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
        return candidate.isEmpty ? trimmed : candidate
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
            shortTitle: "Run Skill",
            systemImageName: "wand.and.stars"
        )
    }

    static var shortcutTileColor: ShortcutTileColor {
        .purple
    }
}

struct SkillNameOptionsProvider: DynamicOptionsProvider {
    func results() async throws -> [String] {
        let workspaceRoot = AgentStore.load().activeAgent?.workspaceURL
        return AgentSkillsLoader
            .listSkills(filterUnavailable: true, visibility: .userInvocable, workspaceRootURL: workspaceRoot)
            .map { skill in
                if let emoji = skill.emoji {
                    return "\(emoji) \(skill.displayName)"
                }
                return skill.displayName
            }
    }
}

enum SkillLaunchService {
    static func handleDeepLink(url: URL, container _: AppContainer) async {
        guard let route = DeepLinkParser.parse(url) else { return }
        guard case let .agent(link) = route else { return }
        guard !link.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        await enqueueAutoSend(message: link.message)
    }

    struct PendingAutoSendRequest: Codable {
        let id: String
        let message: String
        let agentID: String?
        let sessionID: String?
        let createdAtMs: Int64

        var userInfo: [String: String] {
            var payload: [String: String] = [
                "id": id,
                "message": message,
            ]
            if let agentID {
                payload["agentID"] = agentID
            }
            if let sessionID {
                payload["sessionID"] = sessionID
            }
            return payload
        }
    }

    /// Legacy key kept for one-way migration to queue storage.
    static let pendingAutoSendKey = "openava.pendingAutoSend"
    static let pendingAutoSendQueueKey = "openava.pendingAutoSend.queue.v1"

    /// Persists and broadcasts an intent message for ChatRootView to consume once.
    static func enqueueAutoSend(message: String, sessionID: String? = nil) async {
        let request = PendingAutoSendRequest(
            id: UUID().uuidString,
            message: message,
            agentID: AgentStore.load().activeAgentID?.uuidString,
            sessionID: sessionID,
            createdAtMs: Int64(Date().timeIntervalSince1970 * 1000)
        )
        await MainActor.run {
            var queue = loadPendingQueue()
            queue.append(request)
            savePendingQueue(queue)
            NotificationCenter.default.post(
                name: .OpenAvaIntentAutoSend,
                object: nil,
                userInfo: request.userInfo
            )
        }
    }

    /// Dequeue one pending request for the active agent.
    static func dequeuePendingAutoSend(for activeAgentID: UUID?, activeSessionID: String?) -> PendingAutoSendRequest? {
        migrateLegacyPendingPayloadIfNeeded()
        var queue = loadPendingQueue()
        let activeID = activeAgentID?.uuidString
        guard let index = queue.firstIndex(where: { request in
            shouldDeliver(
                requestAgentID: request.agentID,
                activeAgentID: activeID,
                requestSessionID: request.sessionID,
                activeSessionID: activeSessionID
            )
        }) else {
            return nil
        }
        let request = queue.remove(at: index)
        savePendingQueue(queue)
        return request
    }

    static func makeInvocationMessage(skillName: String, task: String?) -> String {
        let resolvedTask = nonEmpty(task) ?? L10n.tr("intent.runSkill.request.defaultTask")
        return [
            "<openava-skill-invocation>",
            "<skill>\(escapeXML(skillName))</skill>",
            "<task>\(escapeXML(resolvedTask))</task>",
            "</openava-skill-invocation>",
        ].joined(separator: "\n")
    }

    private static func nonEmpty(_ text: String?) -> String? {
        let trimmed = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func escapeXML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func loadPendingQueue() -> [PendingAutoSendRequest] {
        guard let data = UserDefaults.standard.data(forKey: pendingAutoSendQueueKey),
              let queue = try? JSONDecoder().decode([PendingAutoSendRequest].self, from: data)
        else {
            return []
        }
        return queue
    }

    private static func savePendingQueue(_ queue: [PendingAutoSendRequest]) {
        if queue.isEmpty {
            UserDefaults.standard.removeObject(forKey: pendingAutoSendQueueKey)
            return
        }
        guard let data = try? JSONEncoder().encode(queue) else { return }
        UserDefaults.standard.set(data, forKey: pendingAutoSendQueueKey)
    }

    private static func migrateLegacyPendingPayloadIfNeeded() {
        guard let payload = UserDefaults.standard.dictionary(forKey: pendingAutoSendKey) as? [String: String],
              let id = payload["id"],
              let message = payload["message"]
        else {
            return
        }
        var queue = loadPendingQueue()
        if !queue.contains(where: { $0.id == id }) {
            queue.append(PendingAutoSendRequest(
                id: id,
                message: message,
                agentID: payload["agentID"],
                sessionID: payload["sessionID"],
                createdAtMs: Int64(Date().timeIntervalSince1970 * 1000)
            ))
            savePendingQueue(queue)
        }
        UserDefaults.standard.removeObject(forKey: pendingAutoSendKey)
    }

    private static func shouldDeliver(
        requestAgentID: String?,
        activeAgentID: String?,
        requestSessionID: String?,
        activeSessionID: String?
    ) -> Bool {
        guard let requestAgentID else {
            // Legacy payloads without agent binding can be consumed by current active agent.
            return requestSessionID == nil || requestSessionID == activeSessionID
        }
        guard requestAgentID == activeAgentID else { return false }
        // Session-bound requests must only execute in their original chat session.
        return requestSessionID == nil || requestSessionID == activeSessionID
    }
}

enum SkillInvocationError: LocalizedError {
    case emptySkill
    case skillNotFound(String)

    var errorDescription: String? {
        switch self {
        case .emptySkill:
            L10n.tr("intent.runSkill.error.emptySkill")
        case let .skillNotFound(name):
            L10n.tr("intent.runSkill.error.skillNotFound", name)
        }
    }
}
