import Foundation

#if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
    import ActivityKit

    /// Attributes for the agent task execution Live Activity.
    /// This file is compiled into both the OpenAva app target and the ActivityWidget extension
    /// so both sides reference the same type structure without a shared framework dependency.
    struct TaskActivityAttributes: ActivityAttributes {
        struct ContentState: Codable, Hashable {
            var agentName: String
            var agentEmoji: String
            var statusMessage: String
            var startedAt: Date
            var isCompleted: Bool
        }

        /// Session ID this activity tracks
        var sessionID: String
    }
#else
    /// Placeholder for platforms where ActivityKit is unavailable (e.g. Mac Catalyst).
    struct TaskActivityAttributes {
        struct ContentState: Codable, Hashable {
            var agentName: String
            var agentEmoji: String
            var statusMessage: String
            var startedAt: Date
            var isCompleted: Bool
        }

        var sessionID: String
    }
#endif
