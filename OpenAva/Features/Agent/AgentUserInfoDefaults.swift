import Foundation

enum AgentUserInfoDefaults {
    private struct PersistedUserInfo: Codable {
        var version: Int
        var callName: String
        var context: String
    }

    struct Value: Equatable {
        var callName: String
        var context: String
    }

    private enum DefaultsKey {
        static let userInfo = "agent.creation.userInfo.v1"
    }

    static func load(defaults: UserDefaults = .standard) -> Value? {
        guard let data = defaults.data(forKey: DefaultsKey.userInfo),
              let decoded = try? JSONDecoder().decode(PersistedUserInfo.self, from: data),
              decoded.version == 1
        else {
            return nil
        }

        return Value(callName: decoded.callName, context: decoded.context)
    }

    static func save(callName: String, context: String, defaults: UserDefaults = .standard) {
        let normalizedCallName = callName.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedContext = context.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !(normalizedCallName.isEmpty && normalizedContext.isEmpty) else {
            defaults.removeObject(forKey: DefaultsKey.userInfo)
            return
        }

        let payload = PersistedUserInfo(
            version: 1,
            callName: normalizedCallName,
            context: normalizedContext
        )

        guard let encoded = try? JSONEncoder().encode(payload) else {
            defaults.removeObject(forKey: DefaultsKey.userInfo)
            return
        }

        defaults.set(encoded, forKey: DefaultsKey.userInfo)
    }
}
