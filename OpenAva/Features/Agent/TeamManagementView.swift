import SwiftUI

struct TeamManagementView: View {
    @Environment(\.appContainerStore) private var containerStore
    @Environment(\.appWindowCoordinator) private var windowCoordinator
    let initialTeamID: UUID?

    @State private var isPresentingCreateTeam = false
    @State private var selectedTeamID: UUID?

    init(initialTeamID: UUID? = nil) {
        self.initialTeamID = initialTeamID
    }

    var body: some View {
        List {
            if containerStore.teams.isEmpty {
                ContentUnavailableView(
                    L10n.tr("team.management.empty.title"),
                    systemImage: "person.3",
                    description: Text(L10n.tr("team.management.empty.description"))
                )
                .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(containerStore.teams) { team in
                        NavigationLink {
                            TeamDetailView(teamID: team.id)
                        } label: {
                            TeamRowView(team: team)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationDestination(item: $selectedTeamID) { teamID in
            TeamDetailView(teamID: teamID)
        }
        .onAppear {
            openRequestedTeamIfNeeded(initialTeamID)
            openRequestedTeamIfNeeded(windowCoordinator.selectedTeamID)
        }
        .onChange(of: initialTeamID) { _, teamID in
            openRequestedTeamIfNeeded(teamID)
        }
        .onChange(of: windowCoordinator.settingsRequestID) { _, _ in
            openRequestedTeamIfNeeded(windowCoordinator.selectedTeamID)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isPresentingCreateTeam = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(L10n.tr("team.management.create.button"))
            }
        }
        .sheet(isPresented: $isPresentingCreateTeam) {
            CreateTeamSheet(isPresented: $isPresentingCreateTeam)
        }
    }

    private func openRequestedTeamIfNeeded(_ teamID: UUID?) {
        guard let teamID,
              containerStore.teams.contains(where: { $0.id == teamID })
        else { return }
        selectedTeamID = teamID
    }
}

private struct TeamRowView: View {
    let team: TeamProfile

    var body: some View {
        HStack(spacing: 12) {
            Text(team.emoji)
                .font(.title2)
                .frame(width: 40, height: 40)
                .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(team.name)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)

                HStack(spacing: 4) {
                    Text(String(format: L10n.tr("team.management.memberCount"), team.agentPoolIDs.count))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }
}

private struct TeamDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appContainerStore) private var containerStore

    let teamID: UUID

    @State private var draftName = ""
    @State private var draftEmoji = "👥"
    @State private var draftDescription = ""
    @State private var isPresentingAddExistingAgents = false
    @State private var isPresentingCreateAgent = false
    @State private var isDeleteAlertPresented = false
    @State private var isEmojiPickerPresented = false
    @State private var autosaveTask: Task<Void, Never>?
    @State private var isSyncingDrafts = false
    @State private var lastSavedBasics: TeamBasics = .empty

    private struct TeamBasics: Equatable {
        var name: String
        var emoji: String
        var description: String?

        static let empty = TeamBasics(name: "", emoji: "👥", description: nil)
    }

    private var team: TeamProfile? {
        containerStore.teams.first(where: { $0.id == teamID })
    }

    private var teamAgents: [AgentProfile] {
        guard let team else { return [] }
        return containerStore.agents.filter { team.agentPoolIDs.contains($0.id) }
    }

    private var navigationTitle: String {
        guard let team else { return L10n.tr("team.management.navigationTitle") }
        return "\(team.emoji) \(team.name)"
    }

    var body: some View {
        Form {
            if let team {
                Section {
                    HStack {
                        TextField(L10n.tr("team.management.name.placeholder"), text: $draftName)
                            .textInputAutocapitalization(.words)

                        Spacer(minLength: 12)

                        EmojiSelectionControl(
                            emoji: draftEmoji,
                            onPick: {
                                isEmojiPickerPresented = true
                            },
                            onShuffle: {
                                draftEmoji = EmojiPickerCatalog.candidates.randomElement() ?? draftEmoji
                            }
                        )
                    }

                    TextField(L10n.tr("team.management.description.placeholder"), text: $draftDescription, axis: .vertical)
                        .lineLimit(3 ... 8)
                } header: {
                    Text(L10n.tr("team.management.section.basics"))
                }

                Section {
                    if teamAgents.isEmpty {
                        Text(L10n.tr("team.management.members.empty"))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(teamAgents) { agent in
                            HStack(spacing: 12) {
                                Text(agent.emoji)
                                    .font(.title3)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(agent.name)
                                        .font(.body.weight(.medium))
                                    Text(agent.workspaceURL.lastPathComponent)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    _ = containerStore.removeAgent(agent.id, fromTeam: team.id)
                                } label: {
                                    Label(L10n.tr("common.delete"), systemImage: "trash")
                                }
                            }
                        }
                    }

                    Button {
                        isPresentingAddExistingAgents = true
                    } label: {
                        Label(L10n.tr("team.management.action.addExisting"), systemImage: "person.badge.plus")
                    }
                    Button {
                        isPresentingCreateAgent = true
                    } label: {
                        Label(L10n.tr("team.management.action.createAndAdd"), systemImage: "plus.circle")
                    }
                } header: {
                    Text(L10n.tr("team.management.section.members"))
                }

                Section {
                    Button(L10n.tr("team.management.action.delete"), role: .destructive) {
                        isDeleteAlertPresented = true
                    }
                }
            } else {
                ContentUnavailableView(
                    L10n.tr("team.management.missing.title"),
                    systemImage: "exclamationmark.triangle",
                    description: Text(L10n.tr("team.management.missing.description"))
                )
            }
        }
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: syncDrafts)
        .onChange(of: team?.updatedAt) { _, _ in
            syncDrafts()
        }
        .onChange(of: draftName) { _, _ in
            scheduleAutosave()
        }
        .onChange(of: draftDescription) { _, _ in
            scheduleAutosave()
        }
        .onChange(of: draftEmoji) { _, _ in
            scheduleAutosave(delayNanoseconds: 0)
        }
        .onDisappear {
            autosaveTask?.cancel()
            autosaveTask = nil
        }
        .sheet(isPresented: $isPresentingAddExistingAgents) {
            if let team {
                AddExistingAgentsSheet(team: team, isPresented: $isPresentingAddExistingAgents)
            }
        }
        .sheet(isPresented: $isEmojiPickerPresented) {
            NavigationStack {
                EmojiPickerGrid(emojis: EmojiPickerCatalog.candidates) { emoji in
                    draftEmoji = emoji
                    isEmojiPickerPresented = false
                }
                .navigationTitle(L10n.tr("agent.creation.emojiPicker.title"))
                .navigationBarTitleDisplayMode(.inline)
            }
            .presentationDetents([.medium, .large])
        }
        .fullScreenCover(isPresented: $isPresentingCreateAgent) {
            AgentCreationView(initialMode: .singleAgent, targetTeamID: teamID) {
                isPresentingCreateAgent = false
            }
        }
        .alert(L10n.tr("team.management.delete.confirm.title"), isPresented: $isDeleteAlertPresented) {
            Button(L10n.tr("common.cancel"), role: .cancel) {}
            Button(L10n.tr("common.delete"), role: .destructive) {
                containerStore.deleteTeam(teamID)
                dismiss()
            }
        } message: {
            Text(L10n.tr("team.management.delete.confirm.message"))
        }
    }

    private func syncDrafts() {
        guard let team else { return }
        isSyncingDrafts = true
        defer { isSyncingDrafts = false }

        if draftName != team.name {
            draftName = team.name
        }
        if draftEmoji != team.emoji {
            draftEmoji = team.emoji
        }
        let description = team.description ?? ""
        if draftDescription != description {
            draftDescription = description
        }
        lastSavedBasics = TeamBasics(
            name: team.name,
            emoji: team.emoji,
            description: team.description?.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private func scheduleAutosave(delayNanoseconds: UInt64 = 450_000_000) {
        guard !isSyncingDrafts else { return }
        autosaveTask?.cancel()
        autosaveTask = Task {
            if delayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                autosaveBasicsIfNeeded()
            }
        }
    }

    private func autosaveBasicsIfNeeded() {
        guard let team else { return }

        let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }

        let emoji = EmojiPickerCatalog.normalized(draftEmoji)
        let normalizedDescription = draftDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let description = normalizedDescription.isEmpty ? nil : normalizedDescription
        let basics = TeamBasics(name: name, emoji: emoji, description: description)

        guard basics != lastSavedBasics else { return }
        guard containerStore.updateTeam(team.id, name: name, emoji: emoji, description: description) != nil else { return }
        lastSavedBasics = basics
    }
}

private struct CreateTeamSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appContainerStore) private var containerStore

    @Binding var isPresented: Bool
    @State private var name = ""
    @State private var emoji = "👥"
    @State private var description = ""
    @State private var errorText: String?
    @State private var isEmojiPickerPresented = false

    private var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        TextField(L10n.tr("team.management.name.placeholder"), text: $name)
                            .textInputAutocapitalization(.words)

                        Spacer(minLength: 12)

                        EmojiSelectionControl(
                            emoji: emoji,
                            onPick: {
                                isEmojiPickerPresented = true
                            },
                            onShuffle: {
                                emoji = EmojiPickerCatalog.candidates.randomElement() ?? emoji
                            }
                        )
                    }
                    TextField(L10n.tr("team.management.description.placeholder"), text: $description, axis: .vertical)
                        .lineLimit(3 ... 6)
                } footer: {
                    Text(L10n.tr("team.management.create.footer"))
                }

                if let errorText {
                    Section {
                        Text(errorText)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(L10n.tr("team.management.create.button"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L10n.tr("common.cancel")) {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L10n.tr("common.create")) {
                        guard containerStore.createTeam(name: name, emoji: emoji, description: description) != nil else {
                            errorText = L10n.tr("team.management.create.failed")
                            return
                        }
                        isPresented = false
                    }
                    .disabled(!canCreate)
                }
            }
            .sheet(isPresented: $isEmojiPickerPresented) {
                NavigationStack {
                    EmojiPickerGrid(emojis: EmojiPickerCatalog.candidates) { value in
                        emoji = value
                        isEmojiPickerPresented = false
                    }
                    .navigationTitle(L10n.tr("agent.creation.emojiPicker.title"))
                    .navigationBarTitleDisplayMode(.inline)
                }
                .presentationDetents([.medium, .large])
            }
        }
    }
}

private struct AddExistingAgentsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appContainerStore) private var containerStore

    let team: TeamProfile
    @Binding var isPresented: Bool

    @State private var selectedAgentIDs: Set<UUID> = []

    private var availableAgents: [AgentProfile] {
        let assignedIDs = Set(
            containerStore.teams
                .filter { $0.id != team.id }
                .flatMap(\.agentPoolIDs)
        )
        return containerStore.agents.filter {
            !team.agentPoolIDs.contains($0.id) && !assignedIDs.contains($0.id)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if availableAgents.isEmpty {
                    Text(L10n.tr("team.management.addExisting.empty"))
                        .foregroundStyle(.secondary)
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
                                        .foregroundStyle(.primary)
                                    Text(agent.workspaceURL.lastPathComponent)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle(L10n.tr("team.management.action.addExisting"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L10n.tr("common.cancel")) {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L10n.tr("common.add")) {
                        _ = containerStore.addAgents(Array(selectedAgentIDs), toTeam: team.id)
                        isPresented = false
                    }
                    .disabled(selectedAgentIDs.isEmpty)
                }
            }
        }
    }

    private func toggle(_ agentID: UUID) {
        if selectedAgentIDs.contains(agentID) {
            selectedAgentIDs.remove(agentID)
        } else {
            selectedAgentIDs.insert(agentID)
        }
    }
}
