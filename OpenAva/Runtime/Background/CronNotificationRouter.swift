import Foundation
import OpenClawKit
import UserNotifications

enum CronNotificationRouter {
    @discardableResult
    static func handle(_ notification: UNNotification) async -> Bool {
        guard let metadata = CronNotificationMetadata(request: notification.request),
              metadata.kind == .heartbeat,
              let agentID = AppConfig.nonEmpty(metadata.agentID)
        else {
            return false
        }

        let enqueued = await HeartbeatTriggerStore.shared.enqueue(
            jobID: metadata.jobID,
            agentID: agentID,
            deliveredAt: notification.date
        )
        if enqueued {
            await HeartbeatService.shared.processPendingCronTriggers()
        }
        return true
    }
}
