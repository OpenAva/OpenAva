import Foundation
import SwiftUI

@MainActor @Observable
final class AgentCreationViewModel {
    enum CreationMode: String, CaseIterable, Identifiable {
        case singleAgent
        case defaultTeam

        var id: String { rawValue }

        var title: String {
            switch self {
            case .singleAgent:
                L10n.tr("agent.creation.mode.single.title")
            case .defaultTeam:
                L10n.tr("agent.creation.mode.team.title")
            }
        }

        var subtitle: String {
            switch self {
            case .singleAgent:
                L10n.tr("agent.creation.mode.single.subtitle")
            case .defaultTeam:
                L10n.tr("agent.creation.mode.team.subtitle")
            }
        }

        var systemImage: String {
            switch self {
            case .singleAgent:
                "sparkles"
            case .defaultTeam:
                "person.3.fill"
            }
        }
    }

    // MARK: - State

    var data = AgentCreationData()
    var isUserInfoExpanded: Bool
    var creationMode: CreationMode
    var isCreating = false
    var errorText: String?
    var emojiNoticeText: String?
    var selectedPresetID: String?
    var selectedDefaultTeamPresetIDs = Set(AgentPresetCatalog.defaultTeamPresetIDs)
    private(set) var hasAppliedInitialDefaults = false
    private let defaults: UserDefaults
    let presets: [AgentPreset]

    /// Shared emoji source for picker and random fill.
    let emojiCandidates = [
        "🤖", "🦊", "🐼", "🦉", "🐙", "🐬", "🦄", "🐝", "🐧", "🦁",
        "🐯", "🐸", "🐵", "🦋", "🐲", "🦖", "🦕", "🐢", "🐳", "🐺",
        "😄", "😎", "🙂", "🤩", "🥳", "🧠", "💡", "✨", "🔥", "⚡️",
        "🌈", "☀️", "🌙", "⭐️", "🌊", "🍀", "🍎", "🍉", "🍵", "☕️",
        "🎯", "🎨", "🎧", "🎬", "🎮", "🧩", "🛠️", "📚", "📝", "📎",
        "🧭", "🛰️", "🔭", "🧪", "🔬", "📡", "🖥️", "💻", "⌨️", "🖱️",
        "📱", "🕹️", "🛸", "🚀", "🗺️", "🏔️", "🌋", "🌲", "🌸", "🌻",
        "🦀", "🐋", "🐅", "🦓", "🦒", "🦥", "🦦", "🦔", "🐿️", "🦜",
    ]

    let vibeOptions = [
        L10n.tr("agent.creation.vibe.warm"),
        L10n.tr("agent.creation.vibe.sharp"),
        L10n.tr("agent.creation.vibe.calm"),
        L10n.tr("agent.creation.vibe.playful"),
        L10n.tr("agent.creation.vibe.professional"),
        L10n.tr("agent.creation.vibe.direct"),
        L10n.tr("agent.creation.vibe.curious"),
        L10n.tr("agent.creation.vibe.minimal"),
    ]

    let truthOptions = [
        L10n.tr("agent.creation.truth.helpful"),
        L10n.tr("agent.creation.truth.concise"),
        L10n.tr("agent.creation.truth.stepByStep"),
        L10n.tr("agent.creation.truth.honest"),
        L10n.tr("agent.creation.truth.actionable"),
        L10n.tr("agent.creation.truth.respectPreferences"),
    ]

    init(
        initialMode: CreationMode = .singleAgent,
        defaults: UserDefaults = .standard,
        presets: [AgentPreset] = AgentPresetCatalog.load()
    ) {
        creationMode = initialMode
        self.defaults = defaults
        self.presets = presets
        isUserInfoExpanded = true
        if let savedUserInfo = AgentUserInfoDefaults.load(defaults: defaults),
           !savedUserInfo.callName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            data.userCallName = savedUserInfo.callName
            data.userContext = savedUserInfo.context
            isUserInfoExpanded = false
        }
    }

    // MARK: - Validation

    var canProceedFromUserInfo: Bool {
        !data.userCallName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var canComplete: Bool {
        switch creationMode {
        case .singleAgent:
            canProceedFromUserInfo &&
                !data.agentName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                !data.agentEmoji.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .defaultTeam:
            canCreateDefaultTeam
        }
    }

    var defaultTeamPresets: [AgentPreset] {
        AgentPresetCatalog.defaultTeamPresets(in: presets)
    }

    var selectedDefaultTeamPresets: [AgentPreset] {
        defaultTeamPresets.filter { selectedDefaultTeamPresetIDs.contains($0.id) }
    }

    var canCreateDefaultTeam: Bool {
        canProceedFromUserInfo && !selectedDefaultTeamPresets.isEmpty
    }

    // MARK: - Initial Setup

    func applyAgentDefaultsIfNeeded(avoiding usedEmojis: Set<String>) {
        guard !hasAppliedInitialDefaults else { return }
        hasAppliedInitialDefaults = true
        applyAgentDefaults(avoiding: usedEmojis)
    }

    // MARK: - Emoji

    func setAgentEmoji(_ emoji: String) {
        data.agentEmoji = emoji
        emojiNoticeText = nil
    }

    func setCreationMode(_ mode: CreationMode, avoiding usedEmojis: Set<String>) {
        guard creationMode != mode else { return }
        creationMode = mode
        errorText = nil

        if mode == .singleAgent {
            applyAgentDefaults(avoiding: usedEmojis)
        }
    }

    func applyVibeOption(_ option: String) {
        data.agentVibe = option
    }

    func applyPreset(_ preset: AgentPreset, avoiding usedEmojis: Set<String>) {
        creationMode = .singleAgent
        selectedPresetID = preset.id
        data.agentName = preset.agentName
        data.agentVibe = preset.agentVibe
        data.soulCoreTruths = preset.soulCoreTruths

        if preset.agentEmoji.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            randomizeAgentEmoji(avoiding: usedEmojis)
        } else {
            setAgentEmoji(preset.agentEmoji)
        }
    }

    func toggleTruthOption(_ option: String) {
        var lines = truthLines
        if let index = lines.firstIndex(of: option) {
            lines.remove(at: index)
        } else {
            lines.append(option)
        }
        data.soulCoreTruths = lines.joined(separator: "\n")
    }

    func containsTruthOption(_ option: String) -> Bool {
        truthLines.contains(option)
    }

    func toggleDefaultTeamPreset(_ preset: AgentPreset) {
        creationMode = .defaultTeam
        if selectedDefaultTeamPresetIDs.contains(preset.id) {
            selectedDefaultTeamPresetIDs.remove(preset.id)
        } else {
            selectedDefaultTeamPresetIDs.insert(preset.id)
        }
    }

    func containsDefaultTeamPreset(_ preset: AgentPreset) -> Bool {
        selectedDefaultTeamPresetIDs.contains(preset.id)
    }

    /// Randomly picks an emoji and avoids existing agents when possible.
    func randomizeAgentEmoji(avoiding usedEmojis: Set<String>) {
        let normalizedUsed = Set(usedEmojis.map(Self.normalizedEmoji).filter { !$0.isEmpty })
        let available = emojiCandidates.filter { !normalizedUsed.contains($0) }

        if let selected = available.randomElement() {
            data.agentEmoji = selected
            emojiNoticeText = nil
            return
        }

        if let fallback = emojiCandidates.randomElement() {
            data.agentEmoji = fallback
            emojiNoticeText = L10n.tr("agent.creation.emojiNotice.usedAll")
            return
        }

        emojiNoticeText = L10n.tr("agent.creation.emojiNotice.none")
    }

    // MARK: - Creation

    func createAgent(containerStore: AppContainerStore) async throws {
        errorText = nil
        emojiNoticeText = nil
        isCreating = true
        defer { isCreating = false }

        // Create agent profile
        let profile = try containerStore.createAgent(
            name: data.agentName,
            emoji: data.agentEmoji
        )

        // Write extended files
        try AgentTemplateWriter.writeUserFile(
            at: profile.workspaceURL,
            callName: data.userCallName,
            context: data.userContext
        )

        try AgentTemplateWriter.writeSoulFile(
            at: profile.workspaceURL,
            coreTruths: data.soulCoreTruths
        )

        // Write additional agent fields
        try AgentTemplateWriter.writeAgentFile(
            at: profile.workspaceURL,
            name: data.agentName,
            emoji: data.agentEmoji,
            vibe: data.agentVibe
        )

        AgentUserInfoDefaults.save(
            callName: data.userCallName,
            context: data.userContext,
            defaults: defaults
        )
    }

    func createDefaultTeam(containerStore: AppContainerStore) async throws {
        errorText = nil
        emojiNoticeText = nil
        isCreating = true
        defer { isCreating = false }

        let presets = selectedDefaultTeamPresets
        guard !presets.isEmpty else { return }

        let createdProfiles = try containerStore.createAgents(
            from: presets,
            callName: data.userCallName,
            context: data.userContext
        )

        _ = TeamStore.createTeam(
            name: L10n.tr("agent.creation.mode.team.title"),
            description: presets.map(\.title).joined(separator: " · "),
            agentPoolIDs: createdProfiles.map(\.id),
            leadAgentID: createdProfiles.first?.id,
            defaultTopology: .automatic
        )
        TeamSwarmCoordinator.shared.reload()

        AgentUserInfoDefaults.save(
            callName: data.userCallName,
            context: data.userContext,
            defaults: defaults
        )
    }

    private static func normalizedEmoji(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var truthLines: [String] {
        data.soulCoreTruths
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Auto-fills agent fields when the user enters step 2.
    private func applyAgentDefaults(avoiding usedEmojis: Set<String>) {
        let trimmedName = data.agentName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedName.isEmpty || trimmedName == L10n.tr("agent.creation.defaultName") {
            data.agentName = defaultAgentName()
        }

        let trimmedEmoji = data.agentEmoji.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedEmoji.isEmpty || trimmedEmoji == "🤖" {
            randomizeAgentEmoji(avoiding: usedEmojis)
        }
    }

    private func defaultAgentName() -> String {
        let callName = data.userCallName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !callName.isEmpty {
            // Use localized owner-style naming so zh-Hans becomes "xxx的助理"
            return L10n.tr("agent.creation.defaultNameWithOwner", callName)
        }
        return L10n.tr("agent.creation.defaultName")
    }
}
