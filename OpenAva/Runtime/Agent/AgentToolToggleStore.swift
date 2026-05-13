import Foundation
import OpenClawKit

enum AgentToolToggleStore {
    private static let defaultsKey = "agent.tool.disabledRecords"

    static func isEnabled(
        _ tool: ToolDefinition,
        workspaceRootURL: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        defaults: UserDefaults = .standard
    ) -> Bool {
        !disabledToolIdentifiers(
            workspaceRootURL: workspaceRootURL,
            environment: environment,
            fileManager: fileManager,
            defaults: defaults
        ).contains(toolIdentifier(for: tool))
    }

    static func setEnabled(
        _ isEnabled: Bool,
        for tool: ToolDefinition,
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
        let toolIdentifier = toolIdentifier(for: tool)
        var disabledRecords = loadDisabledRecords(defaults: defaults)
        var scopedIdentifiers = Set(disabledRecords[scopeKey] ?? [])

        if isEnabled {
            scopedIdentifiers.remove(toolIdentifier)
        } else {
            scopedIdentifiers.insert(toolIdentifier)
        }

        disabledRecords[scopeKey] = scopedIdentifiers.sorted()
        defaults.set(disabledRecords, forKey: defaultsKey)
    }

    private static func disabledToolIdentifiers(
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
        let rootDirectory = AgentContextLoader.resolvedRootDirectory(
            workspaceRootURL: workspaceRootURL,
            environment: environment,
            fileManager: fileManager
        )
        return rootDirectory?.standardizedFileURL.path ?? "global"
    }

    private static func toolIdentifier(for tool: ToolDefinition) -> String {
        tool.functionName
    }
}
