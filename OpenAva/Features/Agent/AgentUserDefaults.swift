import Foundation

enum AgentUserDefaults {
    struct Value: Equatable {
        var callName: String
        var context: String
    }

    static func load(
        directoryURL: URL? = nil,
        fileManager: FileManager = .default
    ) -> Value? {
        guard let decoded = AgentStore.loadUser(
            fileManager: fileManager,
            workspaceRootURL: directoryURL
        )
        else {
            return nil
        }

        return Value(callName: decoded.callName, context: decoded.context)
    }

    static func save(
        callName: String,
        context: String,
        directoryURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        AgentStore.saveUser(
            callName: callName,
            context: context,
            fileManager: fileManager,
            workspaceRootURL: directoryURL
        )
    }
}
