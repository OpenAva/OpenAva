import Foundation

#if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
    import ActivityKit

    /// Attributes for Cron Live Activity.
    /// This file is compiled into both the OpenAva app target and the ActivityWidget extension
    /// so both sides reference the same type structure without a shared framework dependency.
    struct CronActivityAttributes: ActivityAttributes {
        struct ContentState: Codable, Hashable {
            var jobName: String
            var message: String
            /// Schedule type: "at" (one-time) or "every" (repeating)
            var scheduleType: String
            var nextRunISO: String
            var totalJobs: Int
            var isDueSoon: Bool
        }

        /// Stable identifier used to find the existing activity for updates
        var jobID: String
    }
#else
    /// Placeholder for platforms where ActivityKit is unavailable (e.g. Mac Catalyst).
    struct CronActivityAttributes {
        struct ContentState: Codable, Hashable {
            var jobName: String
            var message: String
            var scheduleType: String
            var nextRunISO: String
            var totalJobs: Int
            var isDueSoon: Bool
        }

        var jobID: String
    }
#endif
