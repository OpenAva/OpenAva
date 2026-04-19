import Foundation

public enum OpenAvaSharedDefaults {
    public static let suiteName = "group.ai.openava.shared"

    public static var usesSharedAppGroup: Bool {
        #if targetEnvironment(macCatalyst)
            false
        #else
            true
        #endif
    }

    public static var defaults: UserDefaults {
        guard usesSharedAppGroup else {
            return .standard
        }
        return UserDefaults(suiteName: suiteName) ?? .standard
    }
}

public enum SkillLauncherPresetCatalog {
    public static let defaultIconName = "wand.and.stars"

    public static func fallbackDisplayName(for skillID: String) -> String {
        let normalized = skillID
            .split(separator: "-")
            .map { piece in
                let lower = piece.lowercased()
                return lower.prefix(1).uppercased() + lower.dropFirst()
            }
            .joined(separator: " ")

        return normalized.isEmpty ? skillID : normalized
    }
}

public struct SkillLauncherCatalogSnapshot: Codable, Sendable, Equatable {
    public let generatedAtMs: Int64
    public let agentID: String?
    public let skills: [SkillLauncherSkillSummary]

    public init(generatedAtMs: Int64, agentID: String?, skills: [SkillLauncherSkillSummary]) {
        self.generatedAtMs = generatedAtMs
        self.agentID = agentID
        self.skills = skills
    }
}

public struct SkillLauncherSkillSummary: Codable, Sendable, Equatable, Hashable, Identifiable {
    public let id: String
    public let displayName: String
    public let emoji: String?
    public let iconName: String

    public init(id: String, displayName: String, emoji: String?, iconName: String) {
        self.id = id
        self.displayName = displayName
        self.emoji = emoji
        self.iconName = iconName
    }
}

public enum SkillLaunchSource: String, Codable, Sendable, Equatable {
    case widget
    case shortcut
    case deepLink
}

public struct PendingChatLaunchRequest: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case skill
        case message
    }

    public let id: String
    public let kind: Kind
    public let source: SkillLaunchSource
    public let createdAtMs: Int64
    public let skillID: String?
    public let task: String?
    public let message: String?

    public init(
        skillID: String,
        task: String? = nil,
        source: SkillLaunchSource,
        id: String = UUID().uuidString,
        createdAtMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) {
        self.id = id
        kind = .skill
        self.source = source
        self.createdAtMs = createdAtMs
        self.skillID = skillID
        self.task = task
        message = nil
    }

    public init(
        message: String,
        source: SkillLaunchSource,
        id: String = UUID().uuidString,
        createdAtMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
    ) {
        self.id = id
        kind = .message
        self.source = source
        self.createdAtMs = createdAtMs
        skillID = nil
        task = nil
        self.message = message
    }
}

public enum SkillLauncherCatalogStore {
    private static let catalogKey = "openava.skill-launcher.catalog.v1"

    public static func load(defaults: UserDefaults = OpenAvaSharedDefaults.defaults) -> SkillLauncherCatalogSnapshot? {
        guard let data = defaults.data(forKey: catalogKey) else {
            return nil
        }
        return try? JSONDecoder().decode(SkillLauncherCatalogSnapshot.self, from: data)
    }

    public static func save(_ snapshot: SkillLauncherCatalogSnapshot, defaults: UserDefaults = OpenAvaSharedDefaults.defaults) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: catalogKey)
    }

    public static func clear(defaults: UserDefaults = OpenAvaSharedDefaults.defaults) {
        defaults.removeObject(forKey: catalogKey)
    }
}

public enum PendingChatLaunchRequestStore {
    private static let queueKey = "openava.skill-launcher.requests.v1"

    public static func loadQueue(defaults: UserDefaults = OpenAvaSharedDefaults.defaults) -> [PendingChatLaunchRequest] {
        guard let data = defaults.data(forKey: queueKey),
              let queue = try? JSONDecoder().decode([PendingChatLaunchRequest].self, from: data)
        else {
            return []
        }
        return queue
    }

    public static func saveQueue(_ queue: [PendingChatLaunchRequest], defaults: UserDefaults = OpenAvaSharedDefaults.defaults) {
        if queue.isEmpty {
            defaults.removeObject(forKey: queueKey)
            return
        }
        guard let data = try? JSONEncoder().encode(queue) else { return }
        defaults.set(data, forKey: queueKey)
    }

    public static func enqueue(_ request: PendingChatLaunchRequest, defaults: UserDefaults = OpenAvaSharedDefaults.defaults) {
        var queue = loadQueue(defaults: defaults)
        queue.append(request)
        saveQueue(queue, defaults: defaults)
    }

    public static func clear(defaults: UserDefaults = OpenAvaSharedDefaults.defaults) {
        defaults.removeObject(forKey: queueKey)
    }
}
