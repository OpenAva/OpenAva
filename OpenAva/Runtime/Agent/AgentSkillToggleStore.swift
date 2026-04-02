import Foundation

enum AgentSkillToggleStore {
    private static let defaultsKey = "agent.skill.disabledRecords"

    static func isEnabled(
        _ skill: AgentSkillsLoader.SkillDefinition,
        workspaceRootURL: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        defaults: UserDefaults = .standard
    ) -> Bool {
        !disabledSkillIdentifiers(
            workspaceRootURL: workspaceRootURL,
            environment: environment,
            fileManager: fileManager,
            defaults: defaults
        ).contains(skillIdentifier(for: skill))
    }

    static func setEnabled(
        _ isEnabled: Bool,
        for skill: AgentSkillsLoader.SkillDefinition,
        workspaceRootURL: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        defaults: UserDefaults = .standard
    ) {
        let scopeKey = scopeIdentifier(
            workspaceRootURL: workspaceRootURL,
            environment: environment,
            fileManager: fileManager
        )
        let skillIdentifier = skillIdentifier(for: skill)
        var disabledRecords = loadDisabledRecords(defaults: defaults)
        var scopedIdentifiers = Set(disabledRecords[scopeKey] ?? [])

        if isEnabled {
            scopedIdentifiers.remove(skillIdentifier)
        } else {
            scopedIdentifiers.insert(skillIdentifier)
        }

        disabledRecords[scopeKey] = scopedIdentifiers.sorted()
        defaults.set(disabledRecords, forKey: defaultsKey)
    }

    private static func disabledSkillIdentifiers(
        workspaceRootURL: URL?,
        environment: [String: String],
        fileManager: FileManager,
        defaults: UserDefaults
    ) -> Set<String> {
        let scopeKey = scopeIdentifier(
            workspaceRootURL: workspaceRootURL,
            environment: environment,
            fileManager: fileManager
        )
        return Set(loadDisabledRecords(defaults: defaults)[scopeKey] ?? [])
    }

    private static func loadDisabledRecords(defaults: UserDefaults) -> [String: [String]] {
        defaults.dictionary(forKey: defaultsKey) as? [String: [String]] ?? [:]
    }

    private static func scopeIdentifier(
        workspaceRootURL: URL?,
        environment: [String: String],
        fileManager: FileManager
    ) -> String {
        // Scope the toggle state to the resolved agent context so built-in and workspace skills
        // follow the currently active agent configuration.
        let rootDirectory = AgentContextLoader.resolvedRootDirectory(
            workspaceRootURL: workspaceRootURL,
            environment: environment,
            fileManager: fileManager
        )
        return rootDirectory?.standardizedFileURL.path ?? "global"
    }

    private static func skillIdentifier(for skill: AgentSkillsLoader.SkillDefinition) -> String {
        "\(skill.source)::\(skill.name)"
    }
}
