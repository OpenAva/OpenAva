import Foundation
import OpenClawKit

#if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
    import ActivityKit

    /// Manages Live Activity for cron jobs display on lock screen and Dynamic Island
    @available(iOS 16.1, *)
    final class CronActivityService: Sendable {
        // MARK: - Singleton

        static let shared = CronActivityService()

        // MARK: - Private State

        private let updateQueue = DispatchQueue(label: "com.openava.cron-activity.update")
        private var currentActivityID: String?

        // MARK: - Initialization

        private init() {}

        // MARK: - Public API

        /// Start or update the Live Activity with current cron jobs
        func updateActivity(with jobs: [CronJobPayload]) async {
            guard ActivityAuthorizationInfo().areActivitiesEnabled else {
                // Live Activities not available, skip silently
                return
            }

            // Get the next upcoming job
            guard let nextJob = jobs.sorted(by: { job1, job2 in
                let date1 = job1.nextRunISO.flatMap(parseISODate)
                let date2 = job2.nextRunISO.flatMap(parseISODate)
                switch (date1, date2) {
                case let (d1?, d2?): return d1 < d2
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil): return job1.createdAtISO < job2.createdAtISO
                }
            }).first else {
                // No jobs, end any existing activity
                await endActivity()
                return
            }

            let state = CronActivityAttributes.ContentState(
                from: nextJob,
                totalJobs: jobs.count
            )
            let attributes = CronActivityAttributes(jobID: nextJob.id)

            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                updateQueue.async { [weak self] in
                    self?.performUpdate(attributes: attributes, state: state)
                    continuation.resume()
                }
            }
        }

        /// End the current Live Activity
        func endActivity() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                updateQueue.async { [weak self] in
                    self?.performEnd()
                    continuation.resume()
                }
            }
        }

        // MARK: - Private Helpers

        private func performUpdate(
            attributes: CronActivityAttributes,
            state: CronActivityAttributes.ContentState
        ) {
            Task {
                // Check if we have an existing activity with the same job ID
                if let existingActivity = Activity<CronActivityAttributes>.activities.first(where: { $0.attributes.jobID == attributes.jobID }) {
                    // Update existing activity
                    await existingActivity.update(using: state)
                } else if let existingActivity = Activity<CronActivityAttributes>.activities.first {
                    // End old activity and start new one with different job
                    await existingActivity.end(using: nil, dismissalPolicy: .immediate)
                    try? await startNewActivity(attributes: attributes, state: state)
                } else {
                    // Start new activity
                    try? await startNewActivity(attributes: attributes, state: state)
                }
            }
        }

        private func startNewActivity(
            attributes: CronActivityAttributes,
            state: CronActivityAttributes.ContentState
        ) async throws {
            let activity = try Activity<CronActivityAttributes>.request(
                attributes: attributes,
                content: .init(state: state, staleDate: nil),
                pushType: nil
            )
            currentActivityID = activity.id
        }

        private func performEnd() {
            Task {
                for activity in Activity<CronActivityAttributes>.activities {
                    await activity.end(using: nil, dismissalPolicy: .default)
                }
                currentActivityID = nil
            }
        }

        private func parseISODate(_ isoString: String) -> Date? {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: isoString) {
                return date
            }
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: isoString)
        }
    }

    // MARK: - Activity Authorization Helper

    extension CronActivityService {
        /// Check if Live Activities are enabled for this app
        var areActivitiesEnabled: Bool {
            if #available(iOS 16.1, *) {
                return ActivityAuthorizationInfo().areActivitiesEnabled
            }
            return false
        }
    }

    // MARK: - CronJobPayload Convenience Mapping

    private extension CronActivityAttributes.ContentState {
        init(from payload: CronJobPayload, totalJobs: Int) {
            jobName = payload.name
            message = payload.message
            scheduleType = payload.schedule
            nextRunISO = payload.nextRunISO ?? ""
            self.totalJobs = totalJobs
            isDueSoon = Self.calculateIsDueSoon(nextRunISO: payload.nextRunISO)
        }

        private static func calculateIsDueSoon(nextRunISO: String?) -> Bool {
            guard let iso = nextRunISO,
                  let nextDate = ISO8601DateFormatter().date(from: iso)
            else {
                return false
            }
            return nextDate.timeIntervalSinceNow < 60
        }
    }
#else
    /// No-op implementation for platforms where ActivityKit is unavailable (e.g. Mac Catalyst).
    final class CronActivityService: Sendable {
        static let shared = CronActivityService()

        private init() {}

        func updateActivity(with _: [CronJobPayload]) async {}

        func endActivity() async {}

        var areActivitiesEnabled: Bool {
            false
        }
    }
#endif
