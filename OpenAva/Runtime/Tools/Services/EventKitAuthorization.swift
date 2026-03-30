import EventKit

@available(iOS 17.0, *)
enum EventKitAuthorizationAccessLevel {
    case readOnly
    case writeOnly
}

enum EventKitAuthorization {
    static func allowsRead(status: EKAuthorizationStatus) -> Bool {
        switch status {
        case .authorized, .fullAccess:
            return true
        case .writeOnly:
            return false
        case .notDetermined:
            return false
        case .restricted, .denied:
            return false
        @unknown default:
            return false
        }
    }

    static func allowsWrite(status: EKAuthorizationStatus) -> Bool {
        switch status {
        case .authorized, .fullAccess, .writeOnly:
            return true
        case .notDetermined:
            return false
        case .restricted, .denied:
            return false
        @unknown default:
            return false
        }
    }

    static func requestAccessIfNeeded(store: EKEventStore, entityType: EKEntityType, accessLevel: EventKitAuthorizationAccessLevel) async -> EKAuthorizationStatus {
        let status = EKEventStore.authorizationStatus(for: entityType)
        if Self.hasRequiredAccess(status: status, entityType: entityType, accessLevel: accessLevel) {
            return status
        }

        if status == .restricted || status == .denied {
            return status
        }

        // Request EventKit permission before accessing local calendars or reminders.
        if #available(iOS 17.0, *) {
            switch (entityType, accessLevel) {
            case (.event, .readOnly):
                _ = try? await store.requestFullAccessToEvents()
            case (.event, .writeOnly):
                _ = try? await store.requestWriteOnlyAccessToEvents()
            case (.reminder, .readOnly), (.reminder, .writeOnly):
                // EventKit does not provide a reminders write-only API on iOS.
                _ = try? await store.requestFullAccessToReminders()
            @unknown default:
                break
            }
        } else {
            _ = try? await withCheckedThrowingContinuation { continuation in
                store.requestAccess(to: entityType) { granted, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: granted)
                    }
                }
            } as Bool
        }

        return EKEventStore.authorizationStatus(for: entityType)
    }

    /// Read-only event APIs require full access, while write-only can use write-only grant.
    private static func hasRequiredAccess(
        status: EKAuthorizationStatus,
        entityType: EKEntityType,
        accessLevel: EventKitAuthorizationAccessLevel
    ) -> Bool {
        switch entityType {
        case .event:
            switch accessLevel {
            case .readOnly:
                return allowsRead(status: status)
            case .writeOnly:
                return allowsWrite(status: status)
            }
        case .reminder:
            switch accessLevel {
            case .readOnly:
                return allowsRead(status: status)
            case .writeOnly:
                return allowsWrite(status: status)
            }
        @unknown default:
            return false
        }
    }
}
