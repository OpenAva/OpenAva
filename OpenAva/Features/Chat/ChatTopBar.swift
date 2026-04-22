import Foundation

enum ChatTopBar {
    struct Title: Equatable {
        let agentName: String
        let agentEmoji: String
        let modelName: String

        init(agentName: String, agentEmoji: String?, modelName: String) {
            self.agentName = agentName.trimmingCharacters(in: .whitespacesAndNewlines)
            self.agentEmoji = (agentEmoji ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            self.modelName = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var resolvedAgentName: String {
            agentName.isEmpty ? L10n.tr("chat.activeAgent.fallbackName") : agentName
        }

        var principalAgentText: String {
            agentEmoji.isEmpty ? resolvedAgentName : "\(agentEmoji) \(resolvedAgentName)"
        }

        var resolvedModelName: String {
            modelName.isEmpty ? L10n.tr("chat.selectedModel.notSelected") : modelName
        }

        var principalTitleText: String {
            "\(principalAgentText) · \(resolvedModelName)"
        }
    }

    struct AgentMenuEntry: Identifiable, Equatable {
        enum Kind: Equatable {
            case agent(UUID)
            case createLocalAgent
            case empty
        }

        let id: String
        let kind: Kind
        let title: String
        let emoji: String
        let isSelected: Bool
        let isEnabled: Bool

        var displayTitle: String {
            emoji.isEmpty ? title : "\(emoji) \(title)"
        }
    }

    enum Destination: String, Equatable {
        case llm
        case skills
        case context
        case cron
        case remoteControl
    }

    struct ConfigurationSection: Identifiable, Equatable {
        let id: String
        let items: [ConfigurationItem]
    }

    struct ConfigurationItem: Identifiable, Equatable {
        enum Kind: Equatable {
            case destination(Destination)
            case backgroundExecution(enabled: Bool)
            case autoCompact(enabled: Bool)
            case renameAgent
            case deleteAgent
        }

        let id: String
        let kind: Kind
        let title: String
        let systemImage: String
        let isDestructive: Bool
    }

    static func title(agentName: String, agentEmoji: String?, modelName: String) -> Title {
        Title(agentName: agentName, agentEmoji: agentEmoji, modelName: modelName)
    }

    static func agentMenuEntries(agents: [AgentProfile], activeAgentID: UUID?) -> [AgentMenuEntry] {
        let items = agents.map { agent in
            let title = agent.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let emoji = agent.emoji.trimmingCharacters(in: .whitespacesAndNewlines)
            return AgentMenuEntry(
                id: "agent-\(agent.id.uuidString)",
                kind: .agent(agent.id),
                title: title.isEmpty ? L10n.tr("chat.activeAgent.fallbackName") : title,
                emoji: emoji,
                isSelected: agent.id == activeAgentID,
                isEnabled: true
            )
        }

        if items.isEmpty {
            return [
                AgentMenuEntry(
                    id: "agent-empty",
                    kind: .empty,
                    title: L10n.tr("chat.menu.noAgentsAvailable"),
                    emoji: "",
                    isSelected: false,
                    isEnabled: false
                ),
                AgentMenuEntry(
                    id: "agent-create-local",
                    kind: .createLocalAgent,
                    title: L10n.tr("chat.menu.newLocalAgent"),
                    emoji: "",
                    isSelected: false,
                    isEnabled: true
                ),
            ]
        }

        return items + [
            AgentMenuEntry(
                id: "agent-create-local",
                kind: .createLocalAgent,
                title: L10n.tr("chat.menu.newLocalAgent"),
                emoji: "",
                isSelected: false,
                isEnabled: true
            ),
        ]
    }

    static func configurationSections(
        autoCompactEnabled: Bool,
        isBackgroundEnabled: Bool,
        includeBackgroundExecution: Bool
    ) -> [ConfigurationSection] {
        let configurationSection = ConfigurationSection(
            id: "configuration",
            items: [
                ConfigurationItem(
                    id: "open-llm",
                    kind: .destination(.llm),
                    title: L10n.tr("settings.llm.navigationTitle"),
                    systemImage: "cpu",
                    isDestructive: false
                ),
                ConfigurationItem(
                    id: "open-skills",
                    kind: .destination(.skills),
                    title: L10n.tr("settings.skills.navigationTitle"),
                    systemImage: "square.stack.3d.up",
                    isDestructive: false
                ),
                ConfigurationItem(
                    id: "open-context",
                    kind: .destination(.context),
                    title: L10n.tr("settings.context.navigationTitle"),
                    systemImage: "doc.text",
                    isDestructive: false
                ),
                ConfigurationItem(
                    id: "open-cron",
                    kind: .destination(.cron),
                    title: L10n.tr("settings.cron.navigationTitle"),
                    systemImage: "calendar.badge.clock",
                    isDestructive: false
                ),
            ]
        )

        var managementItems: [ConfigurationItem] = []
        if includeBackgroundExecution {
            managementItems.append(
                ConfigurationItem(
                    id: "background-execution",
                    kind: .backgroundExecution(enabled: isBackgroundEnabled),
                    title: L10n.tr("settings.background.enabled"),
                    systemImage: "arrow.down.app",
                    isDestructive: false
                )
            )
        }
        managementItems.append(contentsOf: [
            ConfigurationItem(
                id: "auto-compact",
                kind: .autoCompact(enabled: autoCompactEnabled),
                title: L10n.tr("chat.menu.autoCompact"),
                systemImage: "rectangle.compress.vertical",
                isDestructive: false
            ),
            ConfigurationItem(
                id: "open-remote-control",
                kind: .destination(.remoteControl),
                title: L10n.tr("settings.remoteControl.navigationTitle"),
                systemImage: "dot.radiowaves.left.and.right",
                isDestructive: false
            ),
            ConfigurationItem(
                id: "rename-agent",
                kind: .renameAgent,
                title: L10n.tr("chat.menu.renameAgent"),
                systemImage: "pencil",
                isDestructive: false
            ),
            ConfigurationItem(
                id: "delete-agent",
                kind: .deleteAgent,
                title: L10n.tr("chat.menu.deleteAgent"),
                systemImage: "trash",
                isDestructive: true
            ),
        ])

        return [
            configurationSection,
            ConfigurationSection(id: "management", items: managementItems),
        ]
    }
}
