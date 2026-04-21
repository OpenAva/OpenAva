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
            preset(
                id: "explorer",
                titleKey: "agent.creation.preset.explorer.title",
                subtitleKey: "agent.creation.preset.explorer.subtitle",
                emoji: "🔭",
                vibeKey: "agent.creation.vibe.curious",
                truthKeys: [
                    "agent.creation.preset.explorer.truth.1",
                    "agent.creation.preset.explorer.truth.2",
                    "agent.creation.preset.explorer.truth.3",
                ]
            ),
            preset(
                id: "planner",
                titleKey: "agent.creation.preset.planner.title",
                subtitleKey: "agent.creation.preset.planner.subtitle",
                emoji: "🧭",
                vibeKey: "agent.creation.vibe.professional",
                truthKeys: [
                    "agent.creation.preset.planner.truth.1",
                    "agent.creation.preset.planner.truth.2",
                    "agent.creation.preset.planner.truth.3",
                ]
            ),
            preset(
                id: "designer",
                titleKey: "agent.creation.preset.designer.title",
                subtitleKey: "agent.creation.preset.designer.subtitle",
                emoji: "🎨",
                vibeKey: "agent.creation.vibe.playful",
                truthKeys: [
                    "agent.creation.preset.designer.truth.1",
                    "agent.creation.preset.designer.truth.2",
                    "agent.creation.preset.designer.truth.3",
                ]
            ),
            preset(
                id: "executor",
                titleKey: "agent.creation.preset.executor.title",
                subtitleKey: "agent.creation.preset.executor.subtitle",
                emoji: "⚡️",
                vibeKey: "agent.creation.vibe.direct",
                truthKeys: [
                    "agent.creation.preset.executor.truth.1",
                    "agent.creation.preset.executor.truth.2",
                    "agent.creation.preset.executor.truth.3",
                ]
            ),
            preset(
                id: "reviewer",
                titleKey: "agent.creation.preset.reviewer.title",
                subtitleKey: "agent.creation.preset.reviewer.subtitle",
                emoji: "🛡️",
                vibeKey: "agent.creation.vibe.sharp",
                truthKeys: [
                    "agent.creation.preset.reviewer.truth.1",
                    "agent.creation.preset.reviewer.truth.2",
                    "agent.creation.preset.reviewer.truth.3",
                ]
            ),
            preset(
                id: "summarizer",
                titleKey: "agent.creation.preset.summarizer.title",
                subtitleKey: "agent.creation.preset.summarizer.subtitle",
                emoji: "📢",
                vibeKey: "agent.creation.vibe.calm",
                truthKeys: [
                    "agent.creation.preset.summarizer.truth.1",
                    "agent.creation.preset.summarizer.truth.2",
                    "agent.creation.preset.summarizer.truth.3",
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
