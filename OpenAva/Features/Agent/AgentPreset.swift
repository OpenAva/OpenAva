import Foundation

struct AgentPreset: Identifiable, Codable, Equatable {
    var id: String
    var title: String
    var subtitle: String
    var agentName: String
    var agentEmoji: String
    var agentVibe: String
    var soulCoreTruths: String

    func normalized() -> AgentPreset? {
        let normalized = AgentPreset(
            id: id.trimmingCharacters(in: .whitespacesAndNewlines),
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            subtitle: subtitle.trimmingCharacters(in: .whitespacesAndNewlines),
            agentName: agentName.trimmingCharacters(in: .whitespacesAndNewlines),
            agentEmoji: agentEmoji.trimmingCharacters(in: .whitespacesAndNewlines),
            agentVibe: agentVibe.trimmingCharacters(in: .whitespacesAndNewlines),
            soulCoreTruths: soulCoreTruths.trimmingCharacters(in: .whitespacesAndNewlines)
        )

        guard !normalized.id.isEmpty,
              !normalized.title.isEmpty,
              !normalized.agentName.isEmpty
        else {
            return nil
        }

        return normalized
    }
}

enum AgentPresetCatalog {
    static let environmentPathKey = "OPENAVA_AGENT_PRESETS_PATH"
    static let defaultTeamPresetIDs = [
        "marketing",
        "sales",
        "support",
        "hr",
        "finance",
        "legal",
        "design",
        "product",
        "engineering",
        "operations",
    ]

    static func load(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> [AgentPreset] {
        let builtIn = builtInPresets()
        let external = loadExternalPresets(environment: environment, fileManager: fileManager)
        return merge(builtIn: builtIn, external: external)
    }

    static func defaultTeamPresets(in presets: [AgentPreset]) -> [AgentPreset] {
        let builtInByID = Dictionary(uniqueKeysWithValues: builtInPresets().map { ($0.id, $0) })
        let availableByID = Dictionary(uniqueKeysWithValues: presets.map { ($0.id, $0) })
        return defaultTeamPresetIDs.compactMap { availableByID[$0] ?? builtInByID[$0] }
    }

    static func builtInPresets() -> [AgentPreset] {
        [
            preset(
                id: "marketing",
                titleKey: "agent.creation.preset.marketing.title",
                subtitleKey: "agent.creation.preset.marketing.subtitle",
                emoji: "📣",
                vibeKey: "agent.creation.vibe.sharp",
                truthKeys: [
                    "agent.creation.preset.marketing.truth.1",
                    "agent.creation.preset.marketing.truth.2",
                    "agent.creation.preset.marketing.truth.3",
                ]
            ),
            preset(
                id: "sales",
                titleKey: "agent.creation.preset.sales.title",
                subtitleKey: "agent.creation.preset.sales.subtitle",
                emoji: "🤝",
                vibeKey: "agent.creation.vibe.direct",
                truthKeys: [
                    "agent.creation.preset.sales.truth.1",
                    "agent.creation.preset.sales.truth.2",
                    "agent.creation.preset.sales.truth.3",
                ]
            ),
            preset(
                id: "support",
                titleKey: "agent.creation.preset.support.title",
                subtitleKey: "agent.creation.preset.support.subtitle",
                emoji: "🎧",
                vibeKey: "agent.creation.vibe.warm",
                truthKeys: [
                    "agent.creation.preset.support.truth.1",
                    "agent.creation.preset.support.truth.2",
                    "agent.creation.preset.support.truth.3",
                ]
            ),
            preset(
                id: "hr",
                titleKey: "agent.creation.preset.hr.title",
                subtitleKey: "agent.creation.preset.hr.subtitle",
                emoji: "🧑‍💼",
                vibeKey: "agent.creation.vibe.calm",
                truthKeys: [
                    "agent.creation.preset.hr.truth.1",
                    "agent.creation.preset.hr.truth.2",
                    "agent.creation.preset.hr.truth.3",
                ]
            ),
            preset(
                id: "finance",
                titleKey: "agent.creation.preset.finance.title",
                subtitleKey: "agent.creation.preset.finance.subtitle",
                emoji: "💰",
                vibeKey: "agent.creation.vibe.professional",
                truthKeys: [
                    "agent.creation.preset.finance.truth.1",
                    "agent.creation.preset.finance.truth.2",
                    "agent.creation.preset.finance.truth.3",
                ]
            ),
            preset(
                id: "legal",
                titleKey: "agent.creation.preset.legal.title",
                subtitleKey: "agent.creation.preset.legal.subtitle",
                emoji: "⚖️",
                vibeKey: "agent.creation.vibe.professional",
                truthKeys: [
                    "agent.creation.preset.legal.truth.1",
                    "agent.creation.preset.legal.truth.2",
                    "agent.creation.preset.legal.truth.3",
                ]
            ),
            preset(
                id: "design",
                titleKey: "agent.creation.preset.design.title",
                subtitleKey: "agent.creation.preset.design.subtitle",
                emoji: "🎨",
                vibeKey: "agent.creation.vibe.playful",
                truthKeys: [
                    "agent.creation.preset.design.truth.1",
                    "agent.creation.preset.design.truth.2",
                    "agent.creation.preset.design.truth.3",
                ]
            ),
            preset(
                id: "product",
                titleKey: "agent.creation.preset.product.title",
                subtitleKey: "agent.creation.preset.product.subtitle",
                emoji: "🧭",
                vibeKey: "agent.creation.vibe.professional",
                truthKeys: [
                    "agent.creation.preset.product.truth.1",
                    "agent.creation.preset.product.truth.2",
                    "agent.creation.preset.product.truth.3",
                ]
            ),
            preset(
                id: "engineering",
                titleKey: "agent.creation.preset.engineering.title",
                subtitleKey: "agent.creation.preset.engineering.subtitle",
                emoji: "💻",
                vibeKey: "agent.creation.vibe.direct",
                truthKeys: [
                    "agent.creation.preset.engineering.truth.1",
                    "agent.creation.preset.engineering.truth.2",
                    "agent.creation.preset.engineering.truth.3",
                ]
            ),
            preset(
                id: "operations",
                titleKey: "agent.creation.preset.operations.title",
                subtitleKey: "agent.creation.preset.operations.subtitle",
                emoji: "📋",
                vibeKey: "agent.creation.vibe.minimal",
                truthKeys: [
                    "agent.creation.preset.operations.truth.1",
                    "agent.creation.preset.operations.truth.2",
                    "agent.creation.preset.operations.truth.3",
                ]
            ),
        ]
    }

    static func merge(builtIn: [AgentPreset], external: [AgentPreset]) -> [AgentPreset] {
        guard !external.isEmpty else {
            return builtIn
        }

        var merged = builtIn
        var indexByID = Dictionary(uniqueKeysWithValues: merged.enumerated().map { ($0.element.id, $0.offset) })

        for preset in external {
            if let index = indexByID[preset.id] {
                merged[index] = preset
            } else {
                indexByID[preset.id] = merged.count
                merged.append(preset)
            }
        }

        return merged
    }

    private static func loadExternalPresets(
        environment: [String: String],
        fileManager: FileManager
    ) -> [AgentPreset] {
        guard let rawPath = environment[environmentPathKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawPath.isEmpty
        else {
            return []
        }

        let fileURL = URL(fileURLWithPath: rawPath, isDirectory: false)
        guard fileManager.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([AgentPreset].self, from: data)
        else {
            return []
        }

        return decoded.compactMap { $0.normalized() }
    }

    private static func truths(_ keys: [String]) -> String {
        keys.map { L10n.tr($0) }.joined(separator: "\n")
    }

    private static func preset(
        id: String,
        titleKey: String,
        subtitleKey: String,
        emoji: String,
        vibeKey: String,
        truthKeys: [String]
    ) -> AgentPreset {
        let title = L10n.tr(titleKey)
        return AgentPreset(
            id: id,
            title: title,
            subtitle: L10n.tr(subtitleKey),
            agentName: title,
            agentEmoji: emoji,
            agentVibe: L10n.tr(vibeKey),
            soulCoreTruths: truths(truthKeys)
        )
    }
}
