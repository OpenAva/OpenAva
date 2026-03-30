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
    static let environmentPathKey = "ICLAW_AGENT_PRESETS_PATH"

    static func load(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> [AgentPreset] {
        let builtIn = builtInPresets()
        let external = loadExternalPresets(environment: environment, fileManager: fileManager)
        return merge(builtIn: builtIn, external: external)
    }

    static func builtInPresets() -> [AgentPreset] {
        [
            AgentPreset(
                id: "general",
                title: L10n.tr("agent.creation.preset.general.title"),
                subtitle: L10n.tr("agent.creation.preset.general.subtitle"),
                agentName: L10n.tr("agent.creation.preset.general.title"),
                agentEmoji: "🤖",
                agentVibe: L10n.tr("agent.creation.vibe.warm"),
                soulCoreTruths: truths([
                    "agent.creation.truth.helpful",
                    "agent.creation.truth.concise",
                    "agent.creation.truth.respectPreferences",
                ])
            ),
            AgentPreset(
                id: "coding",
                title: L10n.tr("agent.creation.preset.coding.title"),
                subtitle: L10n.tr("agent.creation.preset.coding.subtitle"),
                agentName: L10n.tr("agent.creation.preset.coding.title"),
                agentEmoji: "💻",
                agentVibe: L10n.tr("agent.creation.vibe.direct"),
                soulCoreTruths: truths([
                    "agent.creation.truth.stepByStep",
                    "agent.creation.truth.honest",
                    "agent.creation.truth.actionable",
                ])
            ),
            AgentPreset(
                id: "writing",
                title: L10n.tr("agent.creation.preset.writing.title"),
                subtitle: L10n.tr("agent.creation.preset.writing.subtitle"),
                agentName: L10n.tr("agent.creation.preset.writing.title"),
                agentEmoji: "✍️",
                agentVibe: L10n.tr("agent.creation.vibe.calm"),
                soulCoreTruths: truths([
                    "agent.creation.truth.concise",
                    "agent.creation.truth.actionable",
                    "agent.creation.truth.respectPreferences",
                ])
            ),
            AgentPreset(
                id: "research",
                title: L10n.tr("agent.creation.preset.research.title"),
                subtitle: L10n.tr("agent.creation.preset.research.subtitle"),
                agentName: L10n.tr("agent.creation.preset.research.title"),
                agentEmoji: "🔎",
                agentVibe: L10n.tr("agent.creation.vibe.curious"),
                soulCoreTruths: truths([
                    "agent.creation.truth.stepByStep",
                    "agent.creation.truth.honest",
                    "agent.creation.truth.concise",
                ])
            ),
            AgentPreset(
                id: "product",
                title: L10n.tr("agent.creation.preset.product.title"),
                subtitle: L10n.tr("agent.creation.preset.product.subtitle"),
                agentName: L10n.tr("agent.creation.preset.product.title"),
                agentEmoji: "🧭",
                agentVibe: L10n.tr("agent.creation.vibe.professional"),
                soulCoreTruths: truths([
                    "agent.creation.truth.actionable",
                    "agent.creation.truth.stepByStep",
                    "agent.creation.truth.respectPreferences",
                ])
            ),
            AgentPreset(
                id: "meeting",
                title: L10n.tr("agent.creation.preset.meeting.title"),
                subtitle: L10n.tr("agent.creation.preset.meeting.subtitle"),
                agentName: L10n.tr("agent.creation.preset.meeting.title"),
                agentEmoji: "🗓️",
                agentVibe: L10n.tr("agent.creation.vibe.minimal"),
                soulCoreTruths: truths([
                    "agent.creation.truth.concise",
                    "agent.creation.truth.actionable",
                    "agent.creation.truth.respectPreferences",
                ])
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
}
