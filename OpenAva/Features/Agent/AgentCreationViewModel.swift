import Foundation
import SwiftUI
import UIKit

@MainActor @Observable
final class AgentCreationViewModel {
    static let randomAgentNameCandidates = [
        "Aiden", "Aria", "Atlas", "Avery", "Blake", "Brooks", "Caleb", "Carmen",
        "Cassian", "Cleo", "Damon", "Daphne", "Ellis", "Ember", "Ethan", "Eva",
        "Felix", "Finn", "Hazel", "Iris", "Jasper", "Juno", "Kai", "Lena",
        "Leo", "Liam", "Lila", "Luca", "Lyra", "Mason", "Mila", "Milo",
        "Nadia", "Nolan", "Noah", "Nova", "Orion", "Owen", "Piper", "Quinn",
        "Riley", "Roman", "Ruby", "Sawyer", "Silas", "Stella", "Sutton", "Theo",
        "Vera", "Wes", "Wyatt", "Zara", "Zoe", "Adrian", "Ayla", "Beckett",
        "Brielle", "Calla", "Cole", "Delia", "Elio", "Freya", "Gavin", "Hugo",
        "Isla", "Julian", "Keira", "Leona", "Maeve", "Micah", "Naomi", "Rowan",
    ]

    enum CreationMode: String, CaseIterable, Identifiable {
        case singleAgent

        var id: String {
            rawValue
        }

        var title: String {
            switch self {
            case .singleAgent:
                L10n.tr("agent.creation.mode.single.title")
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
    private(set) var hasAppliedInitialDefaults = false
    private let userDirectoryURL: URL?
    let presets: [AgentPreset]
    let agentNameCandidates = AgentCreationViewModel.randomAgentNameCandidates

    /// Shared emoji source for picker and random fill.
    let emojiCandidates = EmojiPickerCatalog.candidates

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
        presets: [AgentPreset]? = nil,
        userDirectoryURL: URL? = nil
    ) {
        creationMode = initialMode
        self.presets = presets ?? AgentPresetCatalog.load()
        self.userDirectoryURL = userDirectoryURL
        isUserInfoExpanded = true
        if let savedUser = AgentUserDefaults.load(directoryURL: userDirectoryURL),
           !savedUser.callName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            data.userCallName = savedUser.callName
            data.userContext = savedUser.context
            isUserInfoExpanded = false
        }
    }

    // MARK: - Validation

    var canProceedFromUserInfo: Bool {
        !data.userCallName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var canComplete: Bool {
        canProceedFromUserInfo &&
            !data.agentName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !data.agentEmoji.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Initial Setup

    func applyAgentDefaultsIfNeeded(avoiding usedEmojis: Set<String>, usedAgentNames: Set<String>) {
        guard !hasAppliedInitialDefaults else { return }
        hasAppliedInitialDefaults = true
        applyAgentDefaults(avoiding: usedEmojis, usedAgentNames: usedAgentNames)
    }

    // MARK: - Emoji

    func setAgentEmoji(_ emoji: String) {
        data.agentEmoji = emoji
        emojiNoticeText = nil
    }

    @discardableResult
    func setAgentAvatarData(_ imageData: Data) -> Bool {
        guard !imageData.isEmpty, UIImage(data: imageData) != nil else {
            return false
        }
        data.agentAvatarData = imageData
        errorText = nil
        return true
    }

    func clearAgentAvatar() {
        data.agentAvatarData = nil
        errorText = nil
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

    func randomizeAgentName(avoiding usedAgentNames: Set<String>) {
        let normalizedUsed = Set(usedAgentNames.map(Self.normalizedName).filter { !$0.isEmpty })
        let currentName = Self.normalizedName(data.agentName)
        let uniqueCandidates = agentNameCandidates.filter { !normalizedUsed.contains(Self.normalizedName($0)) }
        let available = uniqueCandidates.filter { Self.normalizedName($0) != currentName }

        if let selected = available.randomElement() ?? uniqueCandidates.randomElement() {
            data.agentName = selected
            return
        }

        data.agentName = uniqueFallbackAgentName(avoiding: normalizedUsed)
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

    /// Randomly picks an emoji and avoids existing agents when possible.
    func randomizeAgentEmoji(avoiding usedEmojis: Set<String>) {
        let normalizedUsed = Set(usedEmojis.map(Self.normalizedEmoji).filter { !$0.isEmpty })
        let available = emojiCandidates.filter { !normalizedUsed.contains(Self.normalizedEmoji($0)) }

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

        let profile = try containerStore.createAgent(
            name: data.agentName,
            emoji: data.agentEmoji
        )

        if let avatarData = data.agentAvatarData {
            try avatarData.write(to: profile.avatarURL, options: [.atomic])
        }

        try AgentTemplateWriter.writeUserFile(
            at: profile.contextURL,
            callName: data.userCallName,
            context: data.userContext
        )

        try AgentTemplateWriter.writeSoulFile(
            at: profile.contextURL,
            coreTruths: data.soulCoreTruths
        )

        try AgentTemplateWriter.writeAgentFile(
            at: profile.contextURL,
            name: data.agentName,
            emoji: data.agentEmoji,
            vibe: data.agentVibe
        )

        let trimmedTools = data.toolsConfig.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTools.isEmpty {
            try AgentTemplateWriter.writeToolsFile(
                at: profile.workspaceURL,
                config: trimmedTools
            )
        }

        AgentUserDefaults.save(
            callName: data.userCallName,
            context: data.userContext,
            directoryURL: userDirectoryURL
        )
    }

    private static func normalizedEmoji(_ raw: String) -> String {
        EmojiPickerCatalog.normalized(raw)
    }

    private static func normalizedName(_ raw: String) -> String {
        raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private var truthLines: [String] {
        data.soulCoreTruths
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Auto-fills agent fields when the user enters step 2.
    private func applyAgentDefaults(avoiding usedEmojis: Set<String>, usedAgentNames: Set<String>) {
        let trimmedName = data.agentName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedName.isEmpty || isLegacyDefaultAgentName(trimmedName) {
            randomizeAgentName(avoiding: usedAgentNames)
        }

        let trimmedEmoji = data.agentEmoji.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedEmoji.isEmpty || trimmedEmoji == "🤖" {
            randomizeAgentEmoji(avoiding: usedEmojis)
        }
    }

    private func defaultAgentName() -> String {
        return L10n.tr("agent.creation.defaultName")
    }

    private func isLegacyDefaultAgentName(_ name: String) -> Bool {
        let normalizedName = Self.normalizedName(name)
        if normalizedName == Self.normalizedName(L10n.tr("agent.creation.defaultName")) {
            return true
        }

        let callName = data.userCallName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !callName.isEmpty else {
            return false
        }

        return normalizedName == Self.normalizedName(L10n.tr("agent.creation.defaultNameWithOwner", callName))
    }

    private func uniqueFallbackAgentName(avoiding normalizedUsed: Set<String>) -> String {
        let baseName = defaultAgentName()
        if !normalizedUsed.contains(Self.normalizedName(baseName)) {
            return baseName
        }

        var index = 2
        while true {
            let candidate = "\(baseName) \(index)"
            if !normalizedUsed.contains(Self.normalizedName(candidate)) {
                return candidate
            }
            index += 1
        }
    }
}
