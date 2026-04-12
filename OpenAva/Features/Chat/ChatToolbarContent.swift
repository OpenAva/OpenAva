//
//  ChatToolbarContent.swift
//  OpenAva
//

import ChatUI
import OpenClawKit
import SwiftUI
import UserNotifications

struct ChatToolbarContent: ToolbarContent {
    let agentName: String
    let agentEmoji: String
    let modelName: String
    let teams: [TeamProfile]
    let agents: [AgentProfile]
    let activeAgentID: UUID?
    let autoCompactEnabled: Bool
    let onTapAgent: () -> Void
    let onTapModel: () -> Void
    let onMenuAction: ((ChatViewControllerWrapper.MenuAction) -> Void)?
    let onAgentSwitch: ((UUID) -> Void)?
    let onCreateLocalAgent: (() -> Void)?
    let onCreateLocalTeam: (() -> Void)?
    let onDeleteCurrentAgent: (() -> Void)?
    let onRenameCurrentAgent: ((String) -> Bool)?
    let onAddAgentToTeam: ((UUID) -> Void)?
    let onCreateAgentForTeam: ((UUID) -> Void)?
    let onDeleteTeam: ((UUID) -> Void)?
    let onToggleAutoCompact: (() -> Void)?

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            leadingMenu
        }

        ToolbarItem(placement: .principal) {
            VStack(spacing: 0) {
                Button(action: onTapAgent) {
                    Text(resolvedAgentTitle)
                        .font(.system(size: 15, weight: .regular))
                        .foregroundStyle(Color(uiColor: ChatUIDesign.Color.offBlack))
                        .lineLimit(1)
                }
                .buttonStyle(.plain)

                Button(action: onTapModel) {
                    Text(resolvedModelTitle)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(Color(uiColor: ChatUIDesign.Color.black60))
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
            }
        }

        ToolbarItem(placement: .topBarTrailing) {
            trailingMenu
        }
    }

    // MARK: - Leading (Agent Picker)

    private var leadingMenu: some View {
        Menu {
            agentPickerContent
            Section {
                Button(action: { onCreateLocalAgent?() }) {
                    Label(L10n.tr("chat.menu.newLocalAgent"), systemImage: "plus.circle")
                }
                Button(action: { onCreateLocalTeam?() }) {
                    Label(L10n.tr("chat.menu.newTeam"), systemImage: "person.2")
                }
            }
        } label: {
            Image(uiImage: UIImage.chatInputIcon(named: "users") ?? UIImage(systemName: "person.2")!)
                .renderingMode(.template)
                .foregroundStyle(.primary.opacity(0.9))
        }
    }

    @ViewBuilder
    private var agentPickerContent: some View {
        let groupedAgentIDs = Set(teams.flatMap(\.agentPoolIDs))

        // Teams
        ForEach(teams.sorted(by: { $0.createdAt < $1.createdAt }), id: \.id) { team in
            teamSubmenu(for: team)
        }

        // Ungrouped agents
        ForEach(agents.filter { !groupedAgentIDs.contains($0.id) }, id: \.id) { agent in
            agentButton(for: agent)
        }

        if teams.isEmpty, agents.filter({ !groupedAgentIDs.contains($0.id) }).isEmpty {
            Text(L10n.tr("chat.menu.noAgentsAvailable"))
        }
    }

    private func teamSubmenu(for team: TeamProfile) -> some View {
        let snapshot = TeamSwarmCoordinator.shared.menuSnapshot(teamName: team.name)
        return Menu(teamMenuTitle(for: team, snapshot: snapshot)) {
            // Member agents
            let memberAgents = team.agentPoolIDs.compactMap { id in agents.first(where: { $0.id == id }) }
            if memberAgents.isEmpty {
                Text(L10n.tr("chat.menu.team.noAgents"))
            } else {
                ForEach(memberAgents, id: \.id) { agent in
                    agentButton(for: agent, snapshot: snapshot)
                }
            }

            if let snapshot, snapshot.activeTaskCount > 0 {
                Section {
                    Label(
                        String(format: L10n.tr("chat.menu.team.activeTasks"), snapshot.activeTaskCount),
                        systemImage: "checklist"
                    )
                }
            }

            Section {
                Button(action: { onAddAgentToTeam?(team.id) }) {
                    Label(L10n.tr("team.management.action.manageAgents"), systemImage: "person.2.badge.gearshape")
                }
                Button(action: { onCreateAgentForTeam?(team.id) }) {
                    Label(L10n.tr("team.management.action.createAndAdd"), systemImage: "plus.circle")
                }
                Button(role: .destructive, action: { onDeleteTeam?(team.id) }) {
                    Label(L10n.tr("chat.menu.deleteTeamNamed", team.name), systemImage: "trash")
                }
            }
        }
    }

    @ViewBuilder
    private func agentButton(for agent: AgentProfile, snapshot: TeamSwarmCoordinator.TeamMenuSnapshot? = nil) -> some View {
        let isActive = agent.id == activeAgentID
        Button(action: { onAgentSwitch?(agent.id) }) {
            HStack {
                if !agent.emoji.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(agent.emoji)
                }
                Text(agentMenuTitle(for: agent, snapshot: snapshot))
                if isActive {
                    Spacer()
                    Image(systemName: "checkmark")
                }
            }
        }
    }

    // MARK: - Trailing (Settings Menu)

    private var trailingMenu: some View {
        Menu {
            Section {
                Button(action: { onMenuAction?(.openLLM) }) {
                    Label(L10n.tr("settings.llm.navigationTitle"), systemImage: "cpu")
                }
                Button(action: { onMenuAction?(.openSkills) }) {
                    Label(L10n.tr("settings.skills.navigationTitle"), systemImage: "square.stack.3d.up")
                }
                Button(action: { onMenuAction?(.openContext) }) {
                    Label(L10n.tr("settings.context.navigationTitle"), systemImage: "doc.text")
                }
                Button(action: { onMenuAction?(.openCron) }) {
                    Label(L10n.tr("settings.cron.navigationTitle"), systemImage: "calendar.badge.clock")
                }
            }
            Section {
                Toggle(isOn: Binding(
                    get: { BackgroundExecutionPreferences.shared.isEnabled },
                    set: { newValue in
                        BackgroundExecutionPreferences.shared.isEnabled = newValue
                        if newValue {
                            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
                        }
                    }
                )) {
                    Label(L10n.tr("settings.background.enabled"), systemImage: "arrow.down.app")
                }
                Toggle(isOn: Binding(
                    get: { autoCompactEnabled },
                    set: { _ in onToggleAutoCompact?() }
                )) {
                    Label(L10n.tr("chat.menu.autoCompact"), systemImage: "rectangle.compress.vertical")
                }
                Button(action: { onMenuAction?(.openRemoteControl) }) {
                    Label(L10n.tr("settings.remoteControl.navigationTitle"), systemImage: "dot.radiowaves.left.and.right")
                }
                renameButton
                deleteButton
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary.opacity(0.6))
        }
    }

    private var renameButton: some View {
        Button(action: { onTapRename() }) {
            Label(L10n.tr("chat.menu.renameAgent"), systemImage: "pencil")
        }
    }

    private var deleteButton: some View {
        Button(role: .destructive, action: { onDeleteCurrentAgent?() }) {
            Label(L10n.tr("chat.menu.deleteAgent"), systemImage: "trash")
        }
    }

    private func onTapRename() {
        // Rename requires a text field alert which SwiftUI Menu cannot show directly.
        // This is handled by the coordinator via UIKit alert.
        // We route through a notification that the coordinator observes.
        NotificationCenter.default.post(name: .chatToolbarRenameRequested, object: nil)
    }

    // MARK: - Helpers

    private var resolvedAgentTitle: String {
        let trimmedEmoji = agentEmoji.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = agentName.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = name.isEmpty ? "Assistant" : name
        if trimmedEmoji.isEmpty {
            return resolvedName
        }
        return "\(trimmedEmoji) \(resolvedName)"
    }

    private var resolvedModelTitle: String {
        let model = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.isEmpty ? "Not Selected" : model
    }

    private func agentMenuTitle(for agent: AgentProfile, snapshot: TeamSwarmCoordinator.TeamMenuSnapshot?) -> String {
        var title = agent.name
        if let snapshot, let memberStatus = snapshot.memberStatuses[agent.id.uuidString] {
            let badge = statusBadge(for: memberStatus)
            if !badge.isEmpty {
                if let summary = snapshot.memberSummaries[agent.id.uuidString] {
                    let truncated = summary.count > 40 ? String(summary.prefix(40)) + "…" : summary
                    title = "\(title) · \(truncated) \(badge)"
                } else {
                    title = "\(title) \(badge)"
                }
            }
        }
        return title
    }

    private func statusBadge(for status: TeamSwarmCoordinator.MemberStatus) -> String {
        switch status {
        case .busy: return "🟢"
        case .awaitingPlanApproval: return "🟡"
        case .failed: return "🔴"
        case .idle, .stopped: return ""
        }
    }

    private func teamMenuTitle(for team: TeamProfile, snapshot: TeamSwarmCoordinator.TeamMenuSnapshot?) -> String {
        guard let snapshot else { return team.name }
        var parts: [String] = []
        if snapshot.busyCount > 0 {
            parts.append(String(format: L10n.tr("chat.menu.team.busyCount"), snapshot.busyCount))
        }
        if snapshot.pendingApprovalCount > 0 {
            parts.append(String(format: L10n.tr("chat.menu.team.pendingCount"), snapshot.pendingApprovalCount))
        }
        if snapshot.failedCount > 0 {
            parts.append(String(format: L10n.tr("chat.menu.team.failedCount"), snapshot.failedCount))
        }
        if parts.isEmpty { return team.name }
        return "\(team.name) · \(parts.joined(separator: " · "))"
    }
}

extension Notification.Name {
    static let chatToolbarRenameRequested = Notification.Name("chatToolbarRenameRequested")
    static let chatToolbarHeartbeatRequested = Notification.Name("chatToolbarHeartbeatRequested")
    static let chatToolbarOpenModelRequested = Notification.Name("chatToolbarOpenModelRequested")
}
