import Foundation
import UIKit

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

enum AgentAvatarKind: String, Codable, Equatable {
    case diceBear
    case emoji
    case uploaded
}

struct AgentAvatarDescriptor: Equatable {
    var kind: AgentAvatarKind
    var name: String
    var emoji: String
    var avatarFileURL: URL?
    var diceBearSeed: String?
    var remoteURL: URL?
    var avatarIdentityValue: String?

    var diceBearURL: URL {
        remoteURL ?? AgentAvatarDefaults.diceBearURL(seed: resolvedDiceBearSeed)
    }

    var resolvedDiceBearSeed: String {
        let seed = diceBearSeed?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !seed.isEmpty {
            return seed
        }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedName.isEmpty ? "openava-agent" : trimmedName
    }

    var displayEmoji: String {
        let trimmed = emoji.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "🤖" : trimmed
    }
}

enum AgentAvatarDefaults {
    static let diceBearBaseURLString = "https://api.dicebear.com/9.x/notionists/png"
    static let uploadedAvatarIdentityValue = "avatar.png"

    static func diceBearURL(seed rawSeed: String) -> URL {
        var components = URLComponents(string: diceBearBaseURLString)!
        let seed = rawSeed.trimmingCharacters(in: .whitespacesAndNewlines)
        components.queryItems = [
            URLQueryItem(name: "seed", value: seed.isEmpty ? "openava-agent" : seed),
        ]
        return components.url!
    }

    static func descriptor(
        kind: AgentAvatarKind,
        name: String,
        emoji: String,
        avatarFileURL: URL? = nil,
        diceBearSeed: String? = nil,
        remoteURL: URL? = nil,
        avatarIdentityValue: String? = nil
    ) -> AgentAvatarDescriptor {
        AgentAvatarDescriptor(
            kind: kind,
            name: name,
            emoji: emoji,
            avatarFileURL: avatarFileURL,
            diceBearSeed: diceBearSeed,
            remoteURL: remoteURL,
            avatarIdentityValue: avatarIdentityValue
        )
    }

    static func descriptor(
        identityValue: String?,
        name: String,
        emoji: String,
        contextURL: URL?
    ) -> AgentAvatarDescriptor {
        guard let components = identityComponents(from: identityValue, relativeTo: contextURL) else {
            return descriptor(kind: .emoji, name: name, emoji: emoji)
        }
        let defaultAvatarFileURL = contextURL?.appendingPathComponent(uploadedAvatarIdentityValue, isDirectory: false)

        return descriptor(
            kind: components.kind,
            name: name,
            emoji: emoji,
            avatarFileURL: components.fileURL ?? defaultAvatarFileURL,
            diceBearSeed: components.seed,
            remoteURL: components.remoteURL,
            avatarIdentityValue: components.identityValue
        )
    }

    static func localImage(for descriptor: AgentAvatarDescriptor, canvasSize: CGFloat) -> UIImage? {
        switch descriptor.kind {
        case .uploaded, .diceBear:
            guard let avatarFileURL = descriptor.avatarFileURL,
                  let data = try? Data(contentsOf: avatarFileURL),
                  let image = UIImage(data: data)
            else {
                return nil
            }
            return image
        case .emoji:
            return emojiImage(from: descriptor.displayEmoji, canvasSize: canvasSize)
        }
    }

    static func emojiImage(from emoji: String, canvasSize: CGFloat) -> UIImage? {
        let trimmed = emoji.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let format = UIGraphicsImageRendererFormat()
        format.scale = UIScreen.main.scale
        let size = CGSize(width: canvasSize, height: canvasSize)
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            let fontSize = canvasSize * 0.62
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: fontSize),
                .paragraphStyle: paragraph,
            ]
            let text = trimmed as NSString
            let textSize = text.size(withAttributes: attributes)
            let rect = CGRect(
                x: (size.width - textSize.width) / 2,
                y: (size.height - textSize.height) / 2,
                width: textSize.width,
                height: textSize.height
            )
            text.draw(in: rect, withAttributes: attributes)
        }
    }

    static func identityValue(for descriptor: AgentAvatarDescriptor) -> String? {
        switch descriptor.kind {
        case .diceBear:
            return descriptor.remoteURL?.absoluteString ?? descriptor.diceBearURL.absoluteString
        case .uploaded:
            return descriptor.avatarIdentityValue ?? uploadedAvatarIdentityValue
        case .emoji:
            return nil
        }
    }

    static func identityValue(kind: AgentAvatarKind, seed: String?, name: String, emoji: String) -> String? {
        identityValue(for: descriptor(kind: kind, name: name, emoji: emoji, diceBearSeed: seed))
    }

    static func normalizedIdentityValue(_ value: String?) -> String? {
        guard let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !normalized.isEmpty
        else {
            return nil
        }
        return normalized
    }

    static func identityComponents(
        from value: String?,
        relativeTo baseURL: URL? = nil
    ) -> (kind: AgentAvatarKind, seed: String?, remoteURL: URL?, fileURL: URL?, identityValue: String?)? {
        guard let normalized = normalizedIdentityValue(value) else {
            return nil
        }

        if let url = URL(string: normalized),
           url.scheme == "https" || url.scheme == "http"
        {
            let seed: String?
            if url.host == "api.dicebear.com" {
                seed = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?
                    .first(where: { $0.name == "seed" })?
                    .value
            } else {
                seed = nil
            }
            return (.diceBear, seed, url, nil, normalized)
        }

        let fileURL: URL?
        if let url = URL(string: normalized), url.isFileURL {
            fileURL = url
        } else if normalized.hasPrefix("/") {
            fileURL = URL(fileURLWithPath: normalized, isDirectory: false)
        } else {
            fileURL = baseURL?.appendingPathComponent(normalized, isDirectory: false)
        }

        return (.uploaded, nil, nil, fileURL, normalized)
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
                id: "nova",
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
                id: "atlas",
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
                id: "iris",
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
                id: "jett",
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
                id: "vera",
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
                id: "sage",
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
