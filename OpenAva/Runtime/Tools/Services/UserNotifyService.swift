import Foundation
import OpenClawKit
import UserNotifications

enum UserNotifyServiceError: LocalizedError {
    case emptyNotification
    case notificationPermissionDenied
    case notificationFailed(String)
    case speechFailed(String)

    var errorDescription: String? {
        switch self {
        case .emptyNotification:
            return "INVALID_REQUEST: empty notification"
        case .notificationPermissionDenied:
            return "NOT_AUTHORIZED: notifications permission denied"
        case let .notificationFailed(message):
            return "NOTIFICATION_FAILED: \(message)"
        case let .speechFailed(message):
            return "SPEECH_FAILED: \(message)"
        }
    }
}

@MainActor
final class UserNotifyService: UserNotifyServicing {
    private let notificationCenter: any NotificationCentering

    init(notificationCenter: any NotificationCentering) {
        self.notificationCenter = notificationCenter
    }

    func notify(params: UserNotifyParams) async throws -> UserNotifyExecutionResult {
        let normalized = Self.normalize(params)
        guard !normalized.body.isEmpty else {
            throw UserNotifyServiceError.emptyNotification
        }

        let status = await requestNotificationAuthorizationIfNeeded()
        guard status == .authorized || status == .provisional || status == .ephemeral else {
            throw UserNotifyServiceError.notificationPermissionDenied
        }

        let messageId = UUID().uuidString
        let content = UNMutableNotificationContent()
        content.title = normalized.title
        content.body = normalized.body

        if #available(iOS 15.0, *) {
            switch normalized.priority ?? .active {
            case .passive:
                content.interruptionLevel = .passive
            case .timeSensitive:
                content.interruptionLevel = .timeSensitive
            case .active:
                content.interruptionLevel = .active
            }
        }

        // Handle notification sound
        if normalized.playSound {
            content.sound = .default
        } else {
            content.sound = nil
        }

        content.userInfo = ["messageId": messageId]
        let request = UNNotificationRequest(identifier: messageId, content: content, trigger: nil)
        do {
            try await notificationCenter.add(request)
        } catch {
            throw UserNotifyServiceError.notificationFailed(error.localizedDescription)
        }

        let shouldSpeak = normalized.shouldSpeak
        if shouldSpeak {
            do {
                try await TalkSystemSpeechSynthesizer.shared.speak(text: normalized.speechText)
            } catch {
                // Keep speech failures visible to the caller.
                throw UserNotifyServiceError.speechFailed(error.localizedDescription)
            }
        }

        return UserNotifyExecutionResult(messageId: messageId, spoke: shouldSpeak)
    }

    private func requestNotificationAuthorizationIfNeeded() async -> NotificationAuthorizationStatus {
        let status = await notificationCenter.authorizationStatus()
        guard status == .notDetermined else { return status }
        _ = try? await notificationCenter.requestAuthorization(options: [.alert, .sound, .badge])
        return await notificationCenter.authorizationStatus()
    }

    private struct NormalizedPayload {
        var title: String
        var body: String
        var playSound: Bool
        var priority: OpenClawNotificationPriority?
        var shouldSpeak: Bool
        var speechText: String
    }

    private static func normalize(_ params: UserNotifyParams) -> NormalizedPayload {
        let message = params.message.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawTitle = params.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let title = !rawTitle.isEmpty ? rawTitle : "OpenAva"
        let body = message

        // Speech defaults to true if not explicitly set
        let shouldSpeak = params.speech ?? true
        // Notification sound defaults to true if not explicitly set
        let playSound = params.notificationSound ?? true

        let speechText = body

        return NormalizedPayload(
            title: title,
            body: body,
            playSound: playSound,
            priority: params.priority,
            shouldSpeak: shouldSpeak,
            speechText: speechText
        )
    }
}
