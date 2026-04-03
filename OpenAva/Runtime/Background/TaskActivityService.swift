import Foundation

#if canImport(ActivityKit) && !targetEnvironment(macCatalyst)
    import ActivityKit

    /// Manages the Live Activity displayed while an agent task is still running.
    @available(iOS 16.2, *)
    final class TaskActivityService: Sendable {
        static let shared = TaskActivityService()

        private let updateQueue = DispatchQueue(label: "com.openava.task-activity.update")

        private init() {}

        func startActivity(sessionID: String, agentName: String, agentEmoji: String) {
            guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

            let attributes = TaskActivityAttributes(sessionID: sessionID)
            let state = TaskActivityAttributes.ContentState(
                agentName: agentName,
                agentEmoji: agentEmoji,
                statusMessage: "Running...",
                startedAt: Date(),
                isCompleted: false
            )

            updateQueue.async {
                Task {
                    for activity in Activity<TaskActivityAttributes>.activities
                        where activity.attributes.sessionID == sessionID
                    {
                        await activity.end(using: nil, dismissalPolicy: .immediate)
                    }

                    try? Activity<TaskActivityAttributes>.request(
                        attributes: attributes,
                        content: .init(state: state, staleDate: nil),
                        pushType: nil
                    )
                }
            }
        }

        func endActivity(sessionID: String, completed: Bool) {
            updateQueue.async {
                Task {
                    for activity in Activity<TaskActivityAttributes>.activities
                        where activity.attributes.sessionID == sessionID
                    {
                        var finalState = activity.content.state
                        finalState.isCompleted = completed
                        finalState.statusMessage = completed ? "Completed" : "Stopped"
                        // Pass concrete state directly to match ActivityKit end API.
                        await activity.end(
                            using: finalState,
                            dismissalPolicy: .after(Date().addingTimeInterval(4))
                        )
                    }
                }
            }
        }
    }
#else
    /// No-op implementation for platforms where ActivityKit is unavailable (e.g. Mac Catalyst).
    final class TaskActivityService: Sendable {
        static let shared = TaskActivityService()

        private init() {}

        func startActivity(sessionID _: String, agentName _: String, agentEmoji _: String) {}

        func endActivity(sessionID _: String, completed _: Bool) {}
    }
#endif
