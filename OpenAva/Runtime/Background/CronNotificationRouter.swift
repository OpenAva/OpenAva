import Foundation
import OpenClawKit
import UserNotifications

enum CronNotificationRouter {
    static var removeCronJob: @Sendable (String) async -> Void = { jobID in
        _ = try? await CronService().remove(id: jobID)
    }

    @discardableResult
    static func handle(_ notification: UNNotification) async -> Bool {
        await handle(request: notification.request, deliveredAt: notification.date)
    }

    @discardableResult
    static func handle(request: UNNotificationRequest, deliveredAt: Date) async -> Bool {
        guard let metadata = CronNotificationMetadata(request: request) else {
            return false
        }

        switch metadata.kind {
        case .heartbeat:
            guard let agentID = AppConfig.nonEmpty(metadata.agentID) else {
                return false
            }

            let enqueued = await HeartbeatTriggerStore.shared.enqueue(
                jobID: metadata.jobID,
                agentID: agentID,
                deliveredAt: deliveredAt
            )
            if enqueued {
                await HeartbeatRuntimeRegistry.shared.processPendingCronTriggers(for: agentID)
            }
            return true

        case .notify:
            guard let agentID = AppConfig.nonEmpty(metadata.agentID) else {
                return false
            }
            let message = request.content.body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !message.isEmpty else {
                return false
            }
            let delivered = await MainActor.run {
                TeamSwarmCoordinator.shared.sendScheduledMessage(
                    toAgentID: agentID,
                    message: message
                )
            }
            if delivered {
                return true
            }

            if metadata.schedule == "every" {
                await removeCronJob(metadata.jobID)
            }
            return false
        }
    }
}
