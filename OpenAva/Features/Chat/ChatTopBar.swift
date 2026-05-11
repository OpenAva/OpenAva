import Foundation

enum ChatTopBar {
    static let leadingMenuSystemImage = "square.grid.2x2"
    static let trailingMenuSystemImage = "ellipsis"

    struct Title: Equatable {
        enum IdentityKind: Equatable {
            case teamRoom
            case agent
        }

        let displayName: String
        let displayEmoji: String
        let identityKind: IdentityKind

        init(displayName: String, displayEmoji: String?, identityKind: IdentityKind) {
            self.displayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            self.displayEmoji = (displayEmoji ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            self.identityKind = identityKind
        }

        var resolvedDisplayName: String {
            if !displayName.isEmpty { return displayName }
            switch identityKind {
            case .teamRoom:
                return L10n.tr("chat.activeTeam.fallbackName")
            case .agent:
                return L10n.tr("chat.activeAgent.fallbackName")
            }
        }

        var principalDisplayText: String {
            displayEmoji.isEmpty ? resolvedDisplayName : "\(displayEmoji) \(resolvedDisplayName)"
        }
    }

    struct SessionMenuEntry: Identifiable, Equatable {
        enum Kind: Equatable {
            case allAgentsTeam
            case team(UUID)
            case agent(UUID)
            case createLocalAgent
            case empty
        }

        let id: String
        let kind: Kind
        let title: String
        let emoji: String
        let isSelected: Bool

        var displayTitle: String {
            emoji.isEmpty ? title : "\(emoji) \(title)"
        }
    }

    struct WorkspaceMenuEntry: Identifiable, Equatable {
        enum Kind: Equatable {
            case workspace(UUID)
            case openActiveWorkspaceDirectory
            case importWorkspace
            case createWorkspace
        }

        let id: String
        let kind: Kind
        let title: String
        let subtitle: String
        let isSelected: Bool
    }

    enum Destination: String, Equatable {
        case llm
        case skills
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
    }

    static func title(displayName: String, displayEmoji: String?, activeContext: ActiveSessionContext) -> Title {
        let identityKind: Title.IdentityKind = switch activeContext {
        case .allAgentsTeam, .team:
            .teamRoom
        case .agent:
            .agent
        }
        return Title(
            displayName: displayName,
            displayEmoji: displayEmoji,
            identityKind: identityKind
        )
    }

    static func workspaceMenuEntries(workspaces: [ProjectWorkspaceProfile], activeWorkspaceID: UUID?) -> [WorkspaceMenuEntry] {
        var items = workspaces.map { workspace in
            WorkspaceMenuEntry(
                id: "workspace-\(workspace.id.uuidString)",
                kind: .workspace(workspace.id),
                title: workspace.resolvedName,
                subtitle: workspace.displayPath,
                isSelected: workspace.id == activeWorkspaceID
            )
        }

        if activeWorkspaceID != nil {
            items.append(WorkspaceMenuEntry(
                id: "workspace-open-active-directory",
                kind: .openActiveWorkspaceDirectory,
                title: L10n.tr("chat.workspace.openDirectory"),
                subtitle: "",
                isSelected: false
            ))
        }
        items.append(WorkspaceMenuEntry(
            id: "workspace-import",
            kind: .importWorkspace,
            title: L10n.tr("chat.workspace.import"),
            subtitle: "",
            isSelected: false
        ))
        items.append(WorkspaceMenuEntry(
            id: "workspace-create",
            kind: .createWorkspace,
            title: L10n.tr("chat.workspace.create"),
            subtitle: "",
            isSelected: false
        ))
        return items
    }

    static func sessionMenuEntries(
        allAgentsTeam: TeamProfile? = nil,
        teams: [TeamProfile],
        agents: [AgentProfile],
        activeContext: ActiveSessionContext
    ) -> [SessionMenuEntry] {
        var items: [SessionMenuEntry] = []
        let allAgentsTitle = allAgentsTeam?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let allAgentsEmoji = allAgentsTeam?.emoji.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        items.append(SessionMenuEntry(
            id: "session-globalTeam",
            kind: .allAgentsTeam,
            title: allAgentsTitle.isEmpty ? L10n.tr("chat.menu.allAgentsTeam") : allAgentsTitle,
            emoji: allAgentsEmoji,
            isSelected: activeContext == .allAgentsTeam
        ))

        for team in teams {
            let title = team.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let emoji = team.emoji.trimmingCharacters(in: .whitespacesAndNewlines)
            items.append(SessionMenuEntry(
                id: "team-\(team.id.uuidString)",
                kind: .team(team.id),
                title: title.isEmpty ? L10n.tr("chat.activeTeam.fallbackName") : title,
                emoji: emoji,
                isSelected: activeContext == .team(team.id)
            ))
        }

        for agent in agents {
            let title = agent.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let emoji = agent.emoji.trimmingCharacters(in: .whitespacesAndNewlines)
            items.append(SessionMenuEntry(
                id: "agent-\(agent.id.uuidString)",
                kind: .agent(agent.id),
                title: title.isEmpty ? L10n.tr("chat.activeAgent.fallbackName") : title,
                emoji: emoji,
                isSelected: activeContext == .agent(agent.id)
            ))
        }

        if agents.isEmpty {
            items.append(SessionMenuEntry(
                id: "agent-empty",
                kind: .empty,
                title: L10n.tr("chat.menu.noAgentsAvailable"),
                emoji: "",
                isSelected: false
            ))
        }

        items.append(SessionMenuEntry(
            id: "agent-create-local",
            kind: .createLocalAgent,
            title: L10n.tr("chat.menu.newLocalAgent"),
            emoji: "",
            isSelected: false
        ))

        return items
    }

    static func configurationSections(
        autoCompactEnabled: Bool,
        isBackgroundEnabled: Bool,
        includeBackgroundExecution: Bool,
        includeAgentManagement: Bool = true,
        includeTeamRename: Bool = false
    ) -> [ConfigurationSection] {
        let coreItems = [
            ConfigurationItem(
                id: "open-llm",
                kind: .destination(.llm),
                title: L10n.tr("settings.llm.navigationTitle"),
                systemImage: "cpu"
            ),
            ConfigurationItem(
                id: "open-skills",
                kind: .destination(.skills),
                title: L10n.tr("settings.skills.navigationTitle"),
                systemImage: "square.stack.3d.up"
            ),
        ]

        var toggleItems: [ConfigurationItem] = []
        if includeBackgroundExecution {
            toggleItems.append(
                ConfigurationItem(
                    id: "background-execution",
                    kind: .backgroundExecution(enabled: isBackgroundEnabled),
                    title: L10n.tr("settings.background.enabled"),
                    systemImage: "arrow.down.app"
                )
            )
        }
        if includeAgentManagement {
            toggleItems.append(
                ConfigurationItem(
                    id: "auto-compact",
                    kind: .autoCompact(enabled: autoCompactEnabled),
                    title: L10n.tr("chat.menu.autoCompact"),
                    systemImage: "rectangle.compress.vertical"
                )
            )
        }

        let extensionItems = [
            ConfigurationItem(
                id: "open-cron",
                kind: .destination(.cron),
                title: L10n.tr("settings.cron.navigationTitle"),
                systemImage: "calendar.badge.clock"
            ),
            ConfigurationItem(
                id: "open-remote-control",
                kind: .destination(.remoteControl),
                title: L10n.tr("settings.remoteControl.navigationTitle"),
                systemImage: "dot.radiowaves.left.and.right"
            ),
        ]

        var managementItems: [ConfigurationItem] = []
        if includeAgentManagement || includeTeamRename {
            managementItems.append(
                ConfigurationItem(
                    id: "rename-agent",
                    kind: .renameAgent,
                    title: L10n.tr("chat.menu.renameAgent"),
                    systemImage: "pencil"
                )
            )
        }
        if includeAgentManagement {
            managementItems.append(
                ConfigurationItem(
                    id: "delete-agent",
                    kind: .deleteAgent,
                    title: L10n.tr("chat.menu.deleteAgent"),
                    systemImage: "trash"
                )
            )
        }

        var sections: [ConfigurationSection] = [
            ConfigurationSection(id: "core", items: coreItems),
        ]

        if !toggleItems.isEmpty {
            sections.append(ConfigurationSection(id: "toggles", items: toggleItems))
        }

        sections.append(ConfigurationSection(id: "extensions", items: extensionItems))

        if !managementItems.isEmpty {
            sections.append(ConfigurationSection(id: "management", items: managementItems))
        }

        return sections
    }
}
