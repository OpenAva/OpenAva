import Foundation

enum AgentUserInfoDefaults {
    private struct PersistedUserInfo: Codable {
        var callName: String
        var context: String
    }

    struct Value: Equatable {
        var callName: String
        var context: String
    }

    private static func fileURL(directoryURL: URL?, fileManager: FileManager) -> URL? {
        let root = directoryURL ?? (try? AgentStore.workspaceRootDirectory(fileManager: fileManager))
        return root?.appendingPathComponent("userInfo.json", isDirectory: false)
    }

    static func load(
        directoryURL: URL? = nil,
        fileManager: FileManager = .default
    ) -> Value? {
        guard let url = fileURL(directoryURL: directoryURL, fileManager: fileManager),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(PersistedUserInfo.self, from: data)
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
        let normalizedCallName = callName.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedContext = context.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let url = fileURL(directoryURL: directoryURL, fileManager: fileManager) else { return }

        guard !(normalizedCallName.isEmpty && normalizedContext.isEmpty) else {
            try? fileManager.removeItem(at: url)
            return
        }

        let payload = PersistedUserInfo(
            callName: normalizedCallName,
            context: normalizedContext
        )

        guard let encoded = try? JSONEncoder().encode(payload) else {
            try? fileManager.removeItem(at: url)
            return
        }

        try? encoded.write(to: url, options: .atomic)
    }
}
