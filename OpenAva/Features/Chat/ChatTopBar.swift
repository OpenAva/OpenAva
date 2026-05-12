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
        let avatarDescriptor: AgentAvatarDescriptor?
        let identityKind: IdentityKind

        init(displayName: String, displayEmoji: String?, avatarDescriptor: AgentAvatarDescriptor? = nil, identityKind: IdentityKind) {
            self.displayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            self.displayEmoji = (displayEmoji ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            self.avatarDescriptor = avatarDescriptor
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
            if showsAvatar {
                return resolvedDisplayName
            }
            return displayEmoji.isEmpty ? resolvedDisplayName : "\(displayEmoji) \(resolvedDisplayName)"
        }

        var showsAvatar: Bool {
            guard let avatarDescriptor else { return false }
            return avatarDescriptor.kind != .emoji
        }
    }

    struct SessionMenuEntry: Identifiable, Equatable {
        enum Kind: Equatable {
            case allAgentsTeam
            case team(String)
            case agent(String)
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

        var sessionContext: ActiveSessionContext? {
            switch kind {
            case .allAgentsTeam:
                .allAgentsTeam
            case let .team(teamID):
                .team(teamID)
            case let .agent(agentID):
                .agent(agentID)
            case .createLocalAgent, .empty:
                nil
            }
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

        var isWorkspace: Bool {
            if case .workspace = kind { return true }
            return false
        }
    }

    enum LeadingMenuAction: Equatable {
        case switchWorkspace(UUID)
        case openActiveWorkspaceDirectory
        case importWorkspace
        case createWorkspace
        case switchSession(ActiveSessionContext)
        case createLocalAgent
    }

    struct LeadingMenuSection: Identifiable, Equatable {
        enum Kind: String, Equatable {
            case workspaceList
            case workspaceActions
            case rooms
            case agents
            case secondary
        }

        let kind: Kind
        let title: String
        let items: [LeadingMenuItem]

        var id: String {
            kind.rawValue
        }
    }

    struct LeadingMenuItem: Identifiable, Equatable {
        enum Kind: Equatable {
            case workspace(UUID)
            case openActiveWorkspaceDirectory
            case importWorkspace
            case createWorkspace
            case allAgentsTeam
            case team(String)
            case agent(String)
            case createLocalAgent
            case empty
        }

        let id: String
        let kind: Kind
        let title: String
        let subtitle: String
        let emoji: String
        let avatarDescriptor: AgentAvatarDescriptor?
        let isRunning: Bool
        let isSelected: Bool

        var action: LeadingMenuAction? {
            switch kind {
            case let .workspace(workspaceID):
                .switchWorkspace(workspaceID)
            case .openActiveWorkspaceDirectory:
                .openActiveWorkspaceDirectory
            case .importWorkspace:
                .importWorkspace
            case .createWorkspace:
                .createWorkspace
            case .allAgentsTeam:
                .switchSession(.allAgentsTeam)
            case let .team(teamID):
                .switchSession(.team(teamID))
            case let .agent(agentID):
                .switchSession(.agent(agentID))
            case .createLocalAgent:
                .createLocalAgent
            case .empty:
                nil
            }
        }
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

    static func title(
        displayName: String,
        displayEmoji: String?,
        avatarDescriptor: AgentAvatarDescriptor? = nil,
        activeContext: ActiveSessionContext
    ) -> Title {
        let identityKind: Title.IdentityKind = switch activeContext {
        case .allAgentsTeam, .team:
            .teamRoom
        case .agent:
            .agent
        }
        return Title(
            displayName: displayName,
            displayEmoji: displayEmoji,
            avatarDescriptor: avatarDescriptor,
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
                id: "team-\(team.id)",
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
                id: "agent-\(agent.id)",
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

    static func leadingMenuSections(
        workspaces: [ProjectWorkspaceProfile],
        activeWorkspaceID: UUID?,
        allAgentsTeam: TeamProfile? = nil,
        teams: [TeamProfile],
        agents: [AgentProfile],
        activeContext: ActiveSessionContext,
        isSessionRunning: (ActiveSessionContext) -> Bool = { _ in false }
    ) -> [LeadingMenuSection] {
        let workspaceEntries = workspaceMenuEntries(
            workspaces: workspaces,
            activeWorkspaceID: activeWorkspaceID
        )
        let sessionEntries = sessionMenuEntries(
            allAgentsTeam: allAgentsTeam,
            teams: teams,
            agents: agents,
            activeContext: activeContext
        )

        var workspaceListItems: [LeadingMenuItem] = []
        var workspaceActionItems: [LeadingMenuItem] = []
        var roomItems: [LeadingMenuItem] = []
        var agentItems: [LeadingMenuItem] = []
        var secondaryItems: [LeadingMenuItem] = []

        for entry in workspaceEntries {
            let item = leadingMenuItem(from: entry)
            if entry.isWorkspace {
                workspaceListItems.append(item)
            } else {
                workspaceActionItems.append(item)
            }
        }

        let agentAvatarDescriptors = Dictionary(uniqueKeysWithValues: agents.map { agent in
            (agent.id, agent.avatarDescriptor)
        })
        for entry in sessionEntries {
            let item = leadingMenuItem(
                from: entry,
                agentAvatarDescriptors: agentAvatarDescriptors,
                isSessionRunning: isSessionRunning
            )
            switch entry.kind {
            case .createLocalAgent:
                secondaryItems.append(item)
            case .allAgentsTeam, .team:
                roomItems.append(item)
            case .agent, .empty:
                agentItems.append(item)
            }
        }

        var sections: [LeadingMenuSection] = []
        appendSection(
            kind: .workspaceList,
            title: L10n.tr("chat.workspace.sectionTitle"),
            items: workspaceListItems,
            to: &sections
        )
        appendSection(kind: .workspaceActions, title: "", items: workspaceActionItems, to: &sections)
        appendSection(kind: .rooms, title: "", items: roomItems, to: &sections)
        appendSection(kind: .agents, title: "", items: agentItems, to: &sections)
        appendSection(kind: .secondary, title: "", items: secondaryItems, to: &sections)
        return sections
    }

    private static func appendSection(
        kind: LeadingMenuSection.Kind,
        title: String,
        items: [LeadingMenuItem],
        to sections: inout [LeadingMenuSection]
    ) {
        guard !items.isEmpty else { return }
        sections.append(LeadingMenuSection(kind: kind, title: title, items: items))
    }

    private static func leadingMenuItem(from entry: WorkspaceMenuEntry) -> LeadingMenuItem {
        let kind: LeadingMenuItem.Kind = switch entry.kind {
        case let .workspace(workspaceID):
            .workspace(workspaceID)
        case .openActiveWorkspaceDirectory:
            .openActiveWorkspaceDirectory
        case .importWorkspace:
            .importWorkspace
        case .createWorkspace:
            .createWorkspace
        }

        return LeadingMenuItem(
            id: entry.id,
            kind: kind,
            title: entry.title,
            subtitle: entry.subtitle,
            emoji: "",
            avatarDescriptor: nil,
            isRunning: false,
            isSelected: entry.isSelected
        )
    }

    private static func leadingMenuItem(
        from entry: SessionMenuEntry,
        agentAvatarDescriptors: [String: AgentAvatarDescriptor],
        isSessionRunning: (ActiveSessionContext) -> Bool
    ) -> LeadingMenuItem {
        let (kind, avatarDescriptor, isRunning): (LeadingMenuItem.Kind, AgentAvatarDescriptor?, Bool) = switch entry.kind {
        case .allAgentsTeam:
            (.allAgentsTeam, nil, isSessionRunning(.allAgentsTeam))
        case let .team(teamID):
            (.team(teamID), nil, isSessionRunning(.team(teamID)))
        case let .agent(agentID):
            (.agent(agentID), agentAvatarDescriptors[agentID], isSessionRunning(.agent(agentID)))
        case .createLocalAgent:
            (.createLocalAgent, nil, false)
        case .empty:
            (.empty, nil, false)
        }

        return LeadingMenuItem(
            id: entry.id,
            kind: kind,
            title: entry.title,
            subtitle: "",
            emoji: entry.emoji,
            avatarDescriptor: avatarDescriptor,
            isRunning: isRunning,
            isSelected: entry.isSelected
        )
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
