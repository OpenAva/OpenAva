import Foundation

public enum ShareToAgentSettings {
    private static let suiteName = "group.ai.openava.shared"
    private static let defaultInstructionKey = "share.defaultInstruction"
    private static let fallbackInstruction = "Please help me with this."

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: suiteName) ?? .standard
    }

    public static func loadDefaultInstruction() -> String {
        let raw = defaults.string(forKey: defaultInstructionKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let raw, !raw.isEmpty {
            return raw
        }
        return fallbackInstruction
    }

    public static func saveDefaultInstruction(_ value: String?) {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            defaults.removeObject(forKey: defaultInstructionKey)
            return
        }
        defaults.set(trimmed, forKey: defaultInstructionKey)
    }
}
