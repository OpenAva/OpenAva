import ChatUI
import SwiftUI

struct ManageTeamAgentsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appContainerStore) private var containerStore

    let teamID: UUID

    @State private var selectedAgentIDs: Set<UUID> = []
    @State private var lastSyncedAgentIDs: Set<UUID> = []

    private var currentTeam: TeamProfile? {
        containerStore.teams.first { $0.id == teamID }
    }

    private var currentTeamAgentIDs: Set<UUID> {
        Set(currentTeam?.agentPoolIDs ?? [])
    }

    /// Show all available agents except those belonging to OTHER teams.
    private var availableAgents: [AgentProfile] {
        let assignedToOtherTeamsIDs = Set(
            containerStore.teams
                .filter { $0.id != teamID }
                .flatMap(\.agentPoolIDs)
        )
        return containerStore.agents.filter {
            !assignedToOtherTeamsIDs.contains($0.id)
        }
    }

    var body: some View {
        NavigationStack {
            contentList
            #if !targetEnvironment(macCatalyst)
            .navigationTitle(L10n.tr("team.management.action.manageAgents"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.tr("common.cancel")) {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.tr("common.save")) {
                        saveSelection()
                    }
                }
            }
            #endif
        }
        .presentationBackground(Color(uiColor: ChatUIDesign.Color.warmCream))
        .onAppear {
            syncSelectionIfNeeded(force: true)
        }
        .onChange(of: currentTeamAgentIDs) { _, _ in
            syncSelectionIfNeeded(force: false)
        }
    }

    private var contentList: some View {
        VStack(spacing: 0) {
            #if targetEnvironment(macCatalyst)
                ZStack {
                    Text(L10n.tr("team.management.action.manageAgents"))
                        .font(.headline)
                        .foregroundStyle(.primary)

                    HStack(spacing: 12) {
                        actionButton(
                            title: L10n.tr("common.cancel"),
                            role: .secondary,
                            action: dismiss.callAsFunction
                        )
                        Spacer(minLength: 0)
                        actionButton(
                            title: L10n.tr("common.save"),
                            role: .primary,
                            action: saveSelection
                        )
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)
            #endif

            List {
                if availableAgents.isEmpty {
                    Text(L10n.tr("team.management.addExisting.empty"))
                        .font(.body)
                        .foregroundStyle(Color(uiColor: ChatUIDesign.Color.black60))
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 40)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                } else {
                    ForEach(availableAgents) { agent in
                        let selected = selectedAgentIDs.contains(agent.id)
                        Button {
                            toggle(agent.id)
                        } label: {
                            HStack(spacing: 12) {
                                Text(agent.emoji)
                                    .font(.title3)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(agent.name)
                                        .font(.body.weight(.medium))
                                        .foregroundStyle(Color(uiColor: ChatUIDesign.Color.offBlack))
                                    Text(agent.workspaceURL.lastPathComponent)
                                        .font(.caption)
                                        .foregroundStyle(Color(uiColor: ChatUIDesign.Color.black60))
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 20))
                                    .foregroundStyle(selected ? Color(uiColor: ChatUIDesign.Color.brandOrange) : Color(uiColor: ChatUIDesign.Color.oatBorder))
                            }
                            .padding(.vertical, 12)
                            .padding(.horizontal, 16)
                            .background(
                                RoundedRectangle(cornerRadius: ChatUIDesign.Radius.card, style: .continuous)
                                    .fill(Color(uiColor: ChatUIDesign.Color.warmCream))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: ChatUIDesign.Radius.card, style: .continuous)
                                    .strokeBorder(Color(uiColor: ChatUIDesign.Color.oatBorder), lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color(uiColor: ChatUIDesign.Color.warmCream))
        }
        .background(Color(uiColor: ChatUIDesign.Color.warmCream))
    }

    private enum ActionButtonRole {
        case primary
        case secondary
    }

    private func actionButton(
        title: String,
        role: ActionButtonRole,
        action: @escaping () -> Void
    ) -> some View {
        let foregroundColor: UIColor = switch role {
        case .primary:
            ChatUIDesign.Color.pureWhite
        case .secondary:
            ChatUIDesign.Color.offBlack
        }
        let backgroundColor: Color = switch role {
        case .primary:
            Color(uiColor: ChatUIDesign.Color.offBlack)
        case .secondary:
            .clear
        }

        return Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color(uiColor: foregroundColor))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(backgroundColor)
                .clipShape(RoundedRectangle(cornerRadius: ChatUIDesign.Radius.button, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: ChatUIDesign.Radius.button, style: .continuous)
                        .strokeBorder(Color(uiColor: ChatUIDesign.Color.oatBorder), lineWidth: role == .secondary ? 1 : 0)
                )
        }
        .buttonStyle(.plain)
    }

    private func toggle(_ agentID: UUID) {
        if selectedAgentIDs.contains(agentID) {
            selectedAgentIDs.remove(agentID)
        } else {
            selectedAgentIDs.insert(agentID)
        }
    }

    private func saveSelection() {
        guard var updatedTeam = currentTeam else {
            dismiss()
            return
        }
        updatedTeam.agentPoolIDs = Array(selectedAgentIDs)
        containerStore.updateTeam(updatedTeam)
        dismiss()
    }

    private func syncSelectionIfNeeded(force: Bool) {
        let latestAgentIDs = currentTeamAgentIDs
        guard force || selectedAgentIDs == lastSyncedAgentIDs else {
            lastSyncedAgentIDs = latestAgentIDs
            return
        }
        selectedAgentIDs = latestAgentIDs
        lastSyncedAgentIDs = latestAgentIDs
    }
}
