import CoreLocation
import Foundation
import OpenClawKit
import OpenClawProtocol
import UserNotifications

/// Provides tool definitions and invocation handlers for device-related commands
/// (location, camera, screen, notify, device status, watch, photos, image, contacts,
/// calendar, reminders, cron, motion, speech).
final class DeviceToolDefinitions: ToolDefinitionProvider {
    enum PlatformProfile {
        case iOS
        case macCatalyst

        static var current: PlatformProfile {
            #if targetEnvironment(macCatalyst)
                .macCatalyst
            #else
                .iOS
            #endif
        }

        var unsupportedFunctionNames: Set<String> {
            switch self {
            case .iOS:
                return []
            case .macCatalyst:
                return [
                    "watch_status",
                    "watch_notify",
                    "motion_activity",
                    "motion_pedometer",
                ]
            }
        }

        var limitedFunctionNames: Set<String> {
            switch self {
            case .iOS:
                return []
            case .macCatalyst:
                return [
                    "screen_record",
                    "notify_user",
                    "location_get",
                    "photos_latest",
                    "camera_list",
                    "camera_snap",
                    "camera_clip",
                    "calendar_events",
                    "calendar_add",
                    "reminders_list",
                    "reminders_add",
                    "speech_transcribe",
                ]
            }
        }

        var isMacCatalyst: Bool {
            switch self {
            case .iOS: return false
            case .macCatalyst: return true
            }
        }

        var catalystRestrictedCommands: Set<String> {
            [
                OpenClawWatchCommand.status.rawValue,
                OpenClawWatchCommand.notify.rawValue,
                OpenClawMotionCommand.activity.rawValue,
                OpenClawMotionCommand.pedometer.rawValue,
            ]
        }

        var notificationAuthorizationGuidance: String {
            #if targetEnvironment(macCatalyst)
                "请在 macOS 系统设置 > 通知 > OpenAva 中开启通知权限。"
            #else
                "请在 iOS 设置 > 通知 > OpenAva 中开启通知权限。"
            #endif
        }
    }

    private let platform: PlatformProfile
    private let cameraService: any CameraServicing
    private let screenRecordingService: any ScreenRecordingServicing
    private let locationService: any LocationServicing
    private let deviceStatusService: any DeviceStatusServicing
    private let watchMessagingService: any WatchMessagingServicing
    private let photosService: any PhotosServicing
    private let imageBackgroundRemovalService: any ImageBackgroundRemoving
    private let contactsService: any ContactsServicing
    private let calendarService: any CalendarServicing
    private let remindersService: any RemindersServicing
    private let motionService: any MotionServicing
    private let userNotifyService: any UserNotifyServicing
    private let speechService: any SpeechServicing
    private let cronService: any CronServicing
    private let notificationCenter: any NotificationCentering
    private let fileSystemService: FileSystemService

    /// Shared media-persistence closure injected from LocalToolInvokeService.
    let persistMediaData: @Sendable (Data, String, String) throws -> MediaFile

    /// Resolves the active agent workspace URL for media output.
    let activeAgentWorkspaceURL: @Sendable () -> URL?

    struct MediaFile {
        let path: String
        let sizeBytes: Int
    }

    init(
        platform: PlatformProfile = .current,
        cameraService: any CameraServicing,
        screenRecordingService: any ScreenRecordingServicing,
        locationService: any LocationServicing,
        deviceStatusService: any DeviceStatusServicing,
        watchMessagingService: any WatchMessagingServicing,
        photosService: any PhotosServicing,
        imageBackgroundRemovalService: any ImageBackgroundRemoving,
        contactsService: any ContactsServicing,
        calendarService: any CalendarServicing,
        remindersService: any RemindersServicing,
        motionService: any MotionServicing,
        userNotifyService: any UserNotifyServicing,
        speechService: any SpeechServicing,
        cronService: any CronServicing,
        notificationCenter: any NotificationCentering,
        fileSystemService: FileSystemService,
        persistMediaData: @escaping @Sendable (Data, String, String) throws -> MediaFile,
        activeAgentWorkspaceURL: @escaping @Sendable () -> URL?
    ) {
        self.platform = platform
        self.cameraService = cameraService
        self.screenRecordingService = screenRecordingService
        self.locationService = locationService
        self.deviceStatusService = deviceStatusService
        self.watchMessagingService = watchMessagingService
        self.photosService = photosService
        self.imageBackgroundRemovalService = imageBackgroundRemovalService
        self.contactsService = contactsService
        self.calendarService = calendarService
        self.remindersService = remindersService
        self.motionService = motionService
        self.userNotifyService = userNotifyService
        self.speechService = speechService
        self.cronService = cronService
        self.notificationCenter = notificationCenter
        self.fileSystemService = fileSystemService
        self.persistMediaData = persistMediaData
        self.activeAgentWorkspaceURL = activeAgentWorkspaceURL
    }

    // MARK: - Tool Definitions

    func toolDefinitions() -> [ToolDefinition] {
        var definitions = [
            makeTool(
                functionName: "screen_record",
                command: OpenClawScreenCommand.record.rawValue,
                description: "Record the screen for a short period and return the saved file path with metadata.",
                schema: [
                    "type": "object",
                    "properties": [
                        "screenIndex": ["type": "integer"],
                        "durationMs": ["type": "integer"],
                        "fps": ["type": "number"],
                        "format": ["type": "string"],
                        "includeAudio": ["type": "boolean"],
                    ],
                    "additionalProperties": false,
                ]
            ),
            makeTool(
                functionName: "notify_user",
                command: OpenClawSystemCommand.notify.rawValue,
                description: """
                Send a notification to the user with optional text-to-speech.

                Use this tool to alert the user about important information. The message can be displayed as a system notification and/or spoken aloud.

                Examples:
                - notify_user({message: "Your download is complete", speech: true})
                - notify_user({message: "Meeting in 5 minutes", speech: true, notification_sound: false})
                - notify_user({title: "Reminder", message: "Take a break", speech: false})
                """,
                schema: [
                    "type": "object",
                    "properties": [
                        "message": [
                            "type": "string",
                            "description": "The notification message content to display and optionally speak aloud.",
                        ],
                        "title": [
                            "type": "string",
                            "description": "Optional notification title. Defaults to app name if not provided.",
                        ],
                        "speech": [
                            "type": "boolean",
                            "description": "Whether to speak the message aloud using text-to-speech. Default: true.",
                        ],
                        "notification_sound": [
                            "type": "boolean",
                            "description": "Whether to play the system notification sound. Use false for silent notifications. Default: true.",
                        ],
                        "priority": [
                            "type": "string",
                            "enum": ["passive", "active", "timeSensitive"],
                            "description": "Notification priority. Use 'passive' for non-urgent, 'timeSensitive' for urgent alerts.",
                        ],
                    ],
                    "required": ["message"],
                ]
            ),
            makeTool(
                functionName: "location_get",
                command: OpenClawLocationCommand.get.rawValue,
                description: "Get the current device location.",
                schema: [
                    "type": "object",
                    "properties": [
                        "timeoutMs": ["type": "integer"],
                        "maxAgeMs": ["type": "integer"],
                        "desiredAccuracy": ["type": "string", "enum": ["coarse", "balanced", "precise"]],
                    ],
                    "additionalProperties": false,
                ],
                isReadOnly: true,
                isConcurrencySafe: false
            ),
            makeTool(
                functionName: "device_status",
                command: OpenClawDeviceCommand.status.rawValue,
                description: "Get battery, thermal, storage, network, and uptime status.",
                schema: [
                    "type": "object",
                    "properties": [:],
                    "additionalProperties": false,
                ],
                isReadOnly: true,
                isConcurrencySafe: true
            ),
            makeTool(
                functionName: "device_info",
                command: OpenClawDeviceCommand.info.rawValue,
                description: "Get device model and app information.",
                schema: [
                    "type": "object",
                    "properties": [:],
                    "additionalProperties": false,
                ],
                isReadOnly: true,
                isConcurrencySafe: true
            ),
            makeTool(
                functionName: "current_time",
                command: "current.time",
                description: "Get the current runtime date/time with timezone and locale details.",
                schema: [
                    "type": "object",
                    "properties": [
                        "timezone": ["type": "string"],
                        "locale": ["type": "string"],
                    ],
                    "additionalProperties": false,
                ],
                isReadOnly: true,
                isConcurrencySafe: true
            ),
            makeTool(
                functionName: "photos_latest",
                command: OpenClawPhotosCommand.latest.rawValue,
                description: "Fetch the latest photos from the library and return saved file paths with metadata.",
                schema: [
                    "type": "object",
                    "properties": [
                        "limit": ["type": "integer"],
                        "maxWidth": ["type": "integer"],
                        "quality": ["type": "number"],
                    ],
                    "additionalProperties": false,
                ],
                isReadOnly: true,
                isConcurrencySafe: false
            ),
            makeTool(
                functionName: "image_remove_background",
                command: OpenClawImageCommand.removeBackground.rawValue,
                description: "Remove the background from an image file using Apple's Vision foreground mask and write the result as a transparent PNG.",
                schema: [
                    "type": "object",
                    "properties": [
                        "inputPath": ["type": "string"],
                        "outputPath": ["type": "string"],
                    ],
                    "required": ["inputPath"],
                    "additionalProperties": false,
                ]
            ),
            makeTool(
                functionName: "contacts_search",
                command: OpenClawContactsCommand.search.rawValue,
                description: "Search contacts by name, phone, or email.",
                schema: [
                    "type": "object",
                    "properties": [
                        "query": ["type": "string"],
                        "limit": ["type": "integer"],
                    ],
                    "additionalProperties": false,
                ],
                isReadOnly: true,
                isConcurrencySafe: true
            ),
            makeTool(
                functionName: "contacts_add",
                command: OpenClawContactsCommand.add.rawValue,
                description: "Create a new contact.",
                schema: [
                    "type": "object",
                    "properties": [
                        "givenName": ["type": "string"],
                        "familyName": ["type": "string"],
                        "organizationName": ["type": "string"],
                        "displayName": ["type": "string"],
                        "phoneNumbers": ["type": "array", "items": ["type": "string"]],
                        "emails": ["type": "array", "items": ["type": "string"]],
                    ],
                    "additionalProperties": false,
                ]
            ),
            makeTool(
                functionName: "calendar_events",
                command: OpenClawCalendarCommand.events.rawValue,
                description: "List calendar events in a date range.",
                schema: [
                    "type": "object",
                    "properties": [
                        "startISO": ["type": "string"],
                        "endISO": ["type": "string"],
                        "limit": ["type": "integer"],
                    ],
                    "additionalProperties": false,
                ],
                isReadOnly: true,
                isConcurrencySafe: true
            ),
            makeTool(
                functionName: "calendar_add",
                command: OpenClawCalendarCommand.add.rawValue,
                description: "Create a calendar event.",
                schema: [
                    "type": "object",
                    "properties": [
                        "title": ["type": "string"],
                        "startISO": ["type": "string"],
                        "endISO": ["type": "string"],
                        "isAllDay": ["type": "boolean"],
                        "location": ["type": "string"],
                        "notes": ["type": "string"],
                        "calendarId": ["type": "string"],
                        "calendarTitle": ["type": "string"],
                    ],
                    "required": ["title", "startISO", "endISO"],
                    "additionalProperties": false,
                ]
            ),
            makeTool(
                functionName: "reminders_list",
                command: OpenClawRemindersCommand.list.rawValue,
                description: "List reminders.",
                schema: [
                    "type": "object",
                    "properties": [
                        "status": ["type": "string", "enum": ["incomplete", "completed", "all"]],
                        "limit": ["type": "integer"],
                    ],
                    "additionalProperties": false,
                ],
                isReadOnly: true,
                isConcurrencySafe: true
            ),
            makeTool(
                functionName: "reminders_add",
                command: OpenClawRemindersCommand.add.rawValue,
                description: "Create a reminder.",
                schema: [
                    "type": "object",
                    "properties": [
                        "title": ["type": "string"],
                        "dueISO": ["type": "string"],
                        "notes": ["type": "string"],
                        "listId": ["type": "string"],
                        "listName": ["type": "string"],
                    ],
                    "required": ["title"],
                    "additionalProperties": false,
                ]
            ),
            makeTool(
                functionName: "cron",
                command: "cron",
                description: "Schedule and manage local cron reminders or heartbeat triggers (add, list, remove).",
                schema: [
                    "type": "object",
                    "properties": [
                        "action": ["type": "string", "enum": ["add", "list", "remove"]],
                        "message": ["type": "string"],
                        "kind": ["type": "string", "enum": ["notify", "heartbeat"]],
                        "agentId": ["type": "string"],
                        "agent_id": ["type": "string"],
                        "at": ["type": "string"],
                        "everySeconds": ["type": "integer"],
                        "every_seconds": ["type": "integer"],
                        "id": ["type": "string"],
                        "jobId": ["type": "string"],
                        "job_id": ["type": "string"],
                    ],
                    "required": ["action"],
                    "additionalProperties": false,
                ]
            ),
            makeTool(
                functionName: "camera_list",
                command: OpenClawCameraCommand.list.rawValue,
                description: "List available cameras.",
                schema: [
                    "type": "object",
                    "properties": [:],
                    "additionalProperties": false,
                ],
                isReadOnly: true,
                isConcurrencySafe: false
            ),
            makeTool(
                functionName: "camera_snap",
                command: OpenClawCameraCommand.snap.rawValue,
                description: "Capture a still image from the camera and return the saved file path with metadata.",
                schema: [
                    "type": "object",
                    "properties": [
                        "facing": ["type": "string", "enum": ["back", "front"]],
                        "maxWidth": ["type": "integer"],
                        "quality": ["type": "number"],
                        "format": ["type": "string", "enum": ["jpg", "jpeg"]],
                        "deviceId": ["type": "string"],
                        "delayMs": ["type": "integer"],
                    ],
                    "additionalProperties": false,
                ]
            ),
            makeTool(
                functionName: "camera_clip",
                command: OpenClawCameraCommand.clip.rawValue,
                description: "Record a short camera clip and return the saved file path with metadata.",
                schema: [
                    "type": "object",
                    "properties": [
                        "facing": ["type": "string", "enum": ["back", "front"]],
                        "durationMs": ["type": "integer"],
                        "includeAudio": ["type": "boolean"],
                        "format": ["type": "string", "enum": ["mp4"]],
                        "deviceId": ["type": "string"],
                    ],
                    "additionalProperties": false,
                ]
            ),
        ]

        // Watch tools (not available on Mac Catalyst)
        if !platform.isMacCatalyst {
            definitions.append(contentsOf: [
                makeTool(
                    functionName: "watch_status",
                    command: OpenClawWatchCommand.status.rawValue,
                    description: "Get Apple Watch connectivity status.",
                    schema: [
                        "type": "object",
                        "properties": [:],
                        "additionalProperties": false,
                    ],
                    isReadOnly: true,
                    isConcurrencySafe: false
                ),
                makeTool(
                    functionName: "watch_notify",
                    command: OpenClawWatchCommand.notify.rawValue,
                    description: "Send a notification to Apple Watch.",
                    schema: [
                        "type": "object",
                        "properties": [
                            "title": ["type": "string"],
                            "body": ["type": "string"],
                            "priority": ["type": "string", "enum": ["passive", "active", "timeSensitive"]],
                            "promptId": ["type": "string"],
                            "sessionKey": ["type": "string"],
                            "kind": ["type": "string"],
                            "details": ["type": "string"],
                            "expiresAtMs": ["type": "integer"],
                            "risk": ["type": "string", "enum": ["low", "medium", "high"]],
                        ],
                        "required": ["title", "body"],
                        "additionalProperties": false,
                    ]
                ),
            ])
        }

        // Motion tools (not available on Mac Catalyst)
        if !platform.isMacCatalyst {
            definitions.append(contentsOf: [
                makeTool(
                    functionName: "motion_activity",
                    command: OpenClawMotionCommand.activity.rawValue,
                    description: "Query recent motion activity type (stationary, walking, running, cycling, automotive, unknown).",
                    schema: [
                        "type": "object",
                        "properties": [
                            "hoursBack": ["type": "number"],
                        ],
                        "additionalProperties": false,
                    ],
                    isReadOnly: true,
                    isConcurrencySafe: true
                ),
                makeTool(
                    functionName: "motion_pedometer",
                    command: OpenClawMotionCommand.pedometer.rawValue,
                    description: "Query pedometer data for a time range.",
                    schema: [
                        "type": "object",
                        "properties": [
                            "startISO": ["type": "string"],
                            "endISO": ["type": "string"],
                        ],
                        "required": ["startISO", "endISO"],
                        "additionalProperties": false,
                    ],
                    isReadOnly: true,
                    isConcurrencySafe: true
                ),
            ])
        }

        // Speech
        definitions.append(
            makeTool(
                functionName: "speech_transcribe",
                command: OpenClawSpeechCommand.transcribe.rawValue,
                description: "Transcribe an audio file to text using on-device speech recognition.",
                schema: [
                    "type": "object",
                    "properties": [
                        "filePath": ["type": "string"],
                        "language": ["type": "string"],
                    ],
                    "required": ["filePath"],
                    "additionalProperties": false,
                ]
            )
        )

        // Filter out unsupported tools for current platform
        let unsupported = platform.unsupportedFunctionNames
        return definitions.filter { !unsupported.contains($0.functionName) }
    }

    // MARK: - Handler Registration

    func registerHandlers(into handlers: inout [String: ToolHandler]) {
        let platform = self.platform

        // Location
        handlers[OpenClawLocationCommand.get.rawValue] = { [weak self] request in
            guard let self else { throw NodeCapabilityRouter.RouterError.handlerUnavailable }
            if let message = Self.unsupportedPlatformMessage(platform: platform, command: request.command) {
                return ToolInvocationHelpers.unavailableResponse(id: request.id, message)
            }
            return try await self.handleLocationInvoke(request)
        }

        // Camera
        for command in [OpenClawCameraCommand.list.rawValue, OpenClawCameraCommand.snap.rawValue, OpenClawCameraCommand.clip.rawValue] {
            handlers[command] = { [weak self] request in
                guard let self else { throw NodeCapabilityRouter.RouterError.handlerUnavailable }
                return try await self.handleCameraInvoke(request)
            }
        }

        // Screen record
        handlers[OpenClawScreenCommand.record.rawValue] = { [weak self] request in
            guard let self else { throw NodeCapabilityRouter.RouterError.handlerUnavailable }
            return try await self.handleScreenRecordInvoke(request)
        }

        // System notify
        handlers[OpenClawSystemCommand.notify.rawValue] = { [weak self] request in
            guard let self else { throw NodeCapabilityRouter.RouterError.handlerUnavailable }
            return try await self.handleSystemNotify(request)
        }

        // Device status / info / current time
        for command in [OpenClawDeviceCommand.status.rawValue, OpenClawDeviceCommand.info.rawValue, "current.time"] {
            handlers[command] = { [weak self] request in
                guard let self else { throw NodeCapabilityRouter.RouterError.handlerUnavailable }
                return try await self.handleDeviceInvoke(request)
            }
        }

        // Watch (Catalyst-restricted)
        if !platform.isMacCatalyst {
            for command in [OpenClawWatchCommand.status.rawValue, OpenClawWatchCommand.notify.rawValue] {
                handlers[command] = { [weak self] request in
                    guard let self else { throw NodeCapabilityRouter.RouterError.handlerUnavailable }
                    return try await self.handleWatchInvoke(request)
                }
            }
        }

        // Photos
        handlers[OpenClawPhotosCommand.latest.rawValue] = { [weak self] request in
            guard let self else { throw NodeCapabilityRouter.RouterError.handlerUnavailable }
            return try await self.handlePhotosInvoke(request)
        }

        // Image background removal
        handlers[OpenClawImageCommand.removeBackground.rawValue] = { [weak self] request in
            guard let self else { throw NodeCapabilityRouter.RouterError.handlerUnavailable }
            return try await self.handleImageInvoke(request)
        }

        // Contacts
        for command in [OpenClawContactsCommand.search.rawValue, OpenClawContactsCommand.add.rawValue] {
            handlers[command] = { [weak self] request in
                guard let self else { throw NodeCapabilityRouter.RouterError.handlerUnavailable }
                return try await self.handleContactsInvoke(request)
            }
        }

        // Calendar
        for command in [OpenClawCalendarCommand.events.rawValue, OpenClawCalendarCommand.add.rawValue] {
            handlers[command] = { [weak self] request in
                guard let self else { throw NodeCapabilityRouter.RouterError.handlerUnavailable }
                return try await self.handleCalendarInvoke(request)
            }
        }

        // Reminders
        for command in [OpenClawRemindersCommand.list.rawValue, OpenClawRemindersCommand.add.rawValue] {
            handlers[command] = { [weak self] request in
                guard let self else { throw NodeCapabilityRouter.RouterError.handlerUnavailable }
                return try await self.handleRemindersInvoke(request)
            }
        }

        // Cron
        handlers[CronCommand.cron.rawValue] = { [weak self] request in
            guard let self else { throw NodeCapabilityRouter.RouterError.handlerUnavailable }
            return try await self.handleCronInvoke(request)
        }

        // Motion (Catalyst-restricted)
        if !platform.isMacCatalyst {
            for command in [OpenClawMotionCommand.activity.rawValue, OpenClawMotionCommand.pedometer.rawValue] {
                handlers[command] = { [weak self] request in
                    guard let self else { throw NodeCapabilityRouter.RouterError.handlerUnavailable }
                    return try await self.handleMotionInvoke(request)
                }
            }
        }

        // Speech
        handlers[OpenClawSpeechCommand.transcribe.rawValue] = { [weak self] request in
            guard let self else { throw NodeCapabilityRouter.RouterError.handlerUnavailable }
            return try await self.handleSpeechInvoke(request)
        }
    }

    // MARK: - Platform Helpers

    private static func unsupportedPlatformMessage(platform: PlatformProfile, command: String) -> String? {
        guard platform.isMacCatalyst,
              platform.catalystRestrictedCommands.contains(command)
        else {
            return nil
        }
        return "UNAVAILABLE: this capability is not supported in Mac Catalyst. 当前在 Mac Catalyst 环境受限。"
    }

    // MARK: - Notification Helpers

    private struct NotificationCallError: Error {
        let message: String
    }

    private final class NotificationInvokeLatch<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Result<T, NotificationCallError>, Never>?
        private var resumed = false

        func setContinuation(_ continuation: CheckedContinuation<Result<T, NotificationCallError>, Never>) {
            lock.lock()
            defer { self.lock.unlock() }
            self.continuation = continuation
        }

        func resume(_ response: Result<T, NotificationCallError>) {
            let continuation: CheckedContinuation<Result<T, NotificationCallError>, Never>?
            lock.lock()
            if resumed {
                lock.unlock()
                return
            }
            resumed = true
            continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(returning: response)
        }
    }

    private func requestNotificationAuthorizationIfNeeded() async -> NotificationAuthorizationStatus {
        let status = await notificationAuthorizationStatus()
        guard status == .notDetermined else { return status }

        _ = await runNotificationCall(timeoutSeconds: 2.0) { [notificationCenter] in
            _ = try await notificationCenter.requestAuthorization(options: [.alert, .sound, .badge])
        }
        return await notificationAuthorizationStatus()
    }

    private func notificationAuthorizationStatus() async -> NotificationAuthorizationStatus {
        let result = await runNotificationCall(timeoutSeconds: 1.5) { [notificationCenter] in
            await notificationCenter.authorizationStatus()
        }
        switch result {
        case let .success(status):
            return status
        case .failure:
            return .denied
        }
    }

    private func runNotificationCall<T: Sendable>(
        timeoutSeconds: Double,
        operation: @escaping @Sendable () async throws -> T
    ) async -> Result<T, NotificationCallError> {
        let latch = NotificationInvokeLatch<T>()
        var operationTask: Task<Void, Never>?
        var timeoutTask: Task<Void, Never>?

        defer {
            operationTask?.cancel()
            timeoutTask?.cancel()
        }

        let clamped = max(0.0, timeoutSeconds)
        return await withCheckedContinuation { (continuation: CheckedContinuation<Result<T, NotificationCallError>, Never>) in
            latch.setContinuation(continuation)
            operationTask = Task { @MainActor in
                do {
                    let value = try await operation()
                    latch.resume(.success(value))
                } catch {
                    latch.resume(.failure(NotificationCallError(message: error.localizedDescription)))
                }
            }
            timeoutTask = Task.detached {
                if clamped > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(clamped * 1_000_000_000))
                }
                latch.resume(.failure(NotificationCallError(message: "notification request timed out")))
            }
        }
    }

    // MARK: - Media Output Helpers

    private nonisolated func nextMediaOutputURL(prefix: String, suggestedExtension: String) throws -> URL {
        let ext = ToolInvocationHelpers.normalizedFileExtension(suggestedExtension)
        let directoryURL = try mediaOutputDirectoryURL()
        return directoryURL.appendingPathComponent("\(prefix)-\(UUID().uuidString).\(ext)")
    }

    private nonisolated func mediaOutputDirectoryURL() throws -> URL {
        let baseURL = activeAgentWorkspaceURL() ?? FileManager.default.temporaryDirectory
        let directoryURL = baseURL
            .appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return directoryURL
    }

    // MARK: - Handler Implementations

    private func handleLocationInvoke(_ request: BridgeInvokeRequest) async throws -> BridgeInvokeResponse {
        guard CLLocationManager.locationServicesEnabled() else {
            return BridgeInvokeResponse(
                id: request.id,
                ok: false,
                error: OpenClawNodeError(
                    code: .unavailable,
                    message: "LOCATION_DISABLED: enable Location Services in Settings"
                )
            )
        }

        let status = await locationService.ensureAuthorization(mode: .whileUsing)
        guard status == .authorizedAlways || status == .authorizedWhenInUse else {
            return BridgeInvokeResponse(
                id: request.id,
                ok: false,
                error: OpenClawNodeError(
                    code: .unavailable,
                    message: "LOCATION_PERMISSION_REQUIRED: grant Location permission"
                )
            )
        }

        let params = (try? ToolInvocationHelpers.decodeParams(OpenClawLocationGetParams.self, from: request.paramsJSON))
            ?? OpenClawLocationGetParams()
        let desired = params.desiredAccuracy ?? .precise
        let location = try await locationService.currentLocation(
            params: params,
            desiredAccuracy: desired,
            maxAgeMs: params.maxAgeMs,
            timeoutMs: params.timeoutMs
        )

        let payload = OpenClawLocationPayload(
            lat: location.coordinate.latitude,
            lon: location.coordinate.longitude,
            accuracyMeters: location.horizontalAccuracy,
            altitudeMeters: location.verticalAccuracy >= 0 ? location.altitude : nil,
            speedMps: location.speed >= 0 ? location.speed : nil,
            headingDeg: location.course >= 0 ? location.course : nil,
            timestamp: ISO8601DateFormatter().string(from: location.timestamp),
            isPrecise: locationService.accuracyAuthorization() == .fullAccuracy,
            source: nil
        )
        let altitude = payload.altitudeMeters.map { String(format: "%.1f", $0) } ?? "n/a"
        let speed = payload.speedMps.map { String(format: "%.2f", $0) } ?? "n/a"
        let heading = payload.headingDeg.map { String(format: "%.1f", $0) } ?? "n/a"
        let text = """
        ## Location
        - coordinates: \(String(format: "%.6f", payload.lat)), \(String(format: "%.6f", payload.lon))
        - accuracy_m: \(String(format: "%.1f", payload.accuracyMeters))
        - precise: \(payload.isPrecise ? "yes" : "no")
        - altitude_m: \(altitude)
        - speed_mps: \(speed)
        - heading_deg: \(heading)
        - timestamp: \(payload.timestamp)
        """
        return ToolInvocationHelpers.successResponse(id: request.id, payload: text)
    }

    private func handleCameraInvoke(_ request: BridgeInvokeRequest) async throws -> BridgeInvokeResponse {
        switch request.command {
        case OpenClawCameraCommand.list.rawValue:
            let devices = await cameraService.listDevices()
            let lines = devices.enumerated().map { index, device in
                "\(index + 1). \(device.name) (`\(device.position)`, \(device.deviceType)) id=\(device.id)"
            }
            let body = lines.isEmpty ? "No camera devices found." : lines.joined(separator: "\n")
            return BridgeInvokeResponse(id: request.id, ok: true, payload: "## Cameras\n\(body)")
        case OpenClawCameraCommand.snap.rawValue:
            let params = (try? ToolInvocationHelpers.decodeParams(OpenClawCameraSnapParams.self, from: request.paramsJSON))
                ?? OpenClawCameraSnapParams()
            let result = try await cameraService.snap(params: params)
            let mediaFile = try persistMediaData(
                result.data,
                result.format,
                "camera-snap"
            )
            let payload = ToolInvocationHelpers.composeTag(
                name: "media",
                attributes: [
                    ("tool", "camera_snap"),
                    ("format", result.format),
                    ("mime-type", ToolInvocationHelpers.mimeType(for: result.format)),
                    ("size-bytes", "\(mediaFile.sizeBytes)"),
                    ("width", "\(result.width)"),
                    ("height", "\(result.height)"),
                    ("path", mediaFile.path),
                ]
            )
            return ToolInvocationHelpers.successResponse(id: request.id, payload: payload)
        case OpenClawCameraCommand.clip.rawValue:
            let params = (try? ToolInvocationHelpers.decodeParams(OpenClawCameraClipParams.self, from: request.paramsJSON))
                ?? OpenClawCameraClipParams()
            let result = try await cameraService.clip(params: params)
            let mediaFile = try persistMediaData(
                result.data,
                result.format,
                "camera-clip"
            )
            let payload = ToolInvocationHelpers.composeTag(
                name: "media",
                attributes: [
                    ("tool", "camera_clip"),
                    ("format", result.format),
                    ("mime-type", ToolInvocationHelpers.mimeType(for: result.format)),
                    ("size-bytes", "\(mediaFile.sizeBytes)"),
                    ("duration-ms", "\(result.durationMs)"),
                    ("has-audio", result.hasAudio ? "1" : "0"),
                    ("path", mediaFile.path),
                ]
            )
            return ToolInvocationHelpers.successResponse(id: request.id, payload: payload)
        default:
            return ToolInvocationHelpers.invalidRequest(id: request.id, "unknown command")
        }
    }

    private func handleScreenRecordInvoke(_ request: BridgeInvokeRequest) async throws -> BridgeInvokeResponse {
        let params = (try? ToolInvocationHelpers.decodeParams(OpenClawScreenRecordParams.self, from: request.paramsJSON))
            ?? OpenClawScreenRecordParams()

        if let format = params.format, format.lowercased() != "mp4" {
            throw NSError(domain: "Screen", code: 30, userInfo: [
                NSLocalizedDescriptionKey: "INVALID_REQUEST: screen format must be mp4",
            ])
        }

        let outputURL = try nextMediaOutputURL(prefix: "screen-record", suggestedExtension: "mp4")
        let path = try await screenRecordingService.record(
            screenIndex: params.screenIndex,
            durationMs: params.durationMs,
            fps: params.fps,
            includeAudio: params.includeAudio,
            outPath: outputURL.path
        )
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.intValue ?? 0
        let payload = ToolInvocationHelpers.composeTag(
            name: "media",
            attributes: [
                ("tool", "screen_record"),
                ("format", "mp4"),
                ("mime-type", ToolInvocationHelpers.mimeType(for: "mp4")),
                ("size-bytes", "\(fileSize)"),
                ("duration-ms", "\(params.durationMs ?? 0)"),
                ("fps", "\(params.fps ?? 0)"),
                ("screen-index", "\(params.screenIndex ?? 0)"),
                ("has-audio", (params.includeAudio ?? true) ? "1" : "0"),
                ("path", path),
            ]
        )
        return ToolInvocationHelpers.successResponse(id: request.id, payload: payload)
    }

    private func handleSystemNotify(_ request: BridgeInvokeRequest) async throws -> BridgeInvokeResponse {
        struct MergedNotifyParams: Decodable {
            var message: String
            var title: String?
            var speech: Bool?
            var notificationSound: Bool?
            var priority: OpenClawNotificationPriority?

            enum CodingKeys: String, CodingKey {
                case message
                case title
                case speech
                case notificationSound = "notification_sound"
                case priority
            }
        }

        let params = try ToolInvocationHelpers.decodeParams(MergedNotifyParams.self, from: request.paramsJSON)
        let notifyParams = UserNotifyParams(
            message: params.message,
            title: params.title,
            speech: params.speech,
            notificationSound: params.notificationSound,
            priority: params.priority
        )
        do {
            _ = try await userNotifyService.notify(params: notifyParams)
            let payloadText = """
            Notification sent successfully.
            """
            return BridgeInvokeResponse(id: request.id, ok: true, payload: payloadText)
        } catch let error as UserNotifyServiceError {
            switch error {
            case .emptyNotification:
                return BridgeInvokeResponse(
                    id: request.id,
                    ok: false,
                    error: OpenClawNodeError(code: .invalidRequest, message: error.localizedDescription)
                )
            case .notificationPermissionDenied:
                return BridgeInvokeResponse(
                    id: request.id,
                    ok: false,
                    error: OpenClawNodeError(
                        code: .unavailable,
                        message: "NOT_AUTHORIZED: notifications. \(platform.notificationAuthorizationGuidance)"
                    )
                )
            case .notificationFailed, .speechFailed:
                return BridgeInvokeResponse(
                    id: request.id,
                    ok: false,
                    error: OpenClawNodeError(code: .unavailable, message: error.localizedDescription)
                )
            }
        }
    }

    private func handleWatchInvoke(_ request: BridgeInvokeRequest) async throws -> BridgeInvokeResponse {
        switch request.command {
        case OpenClawWatchCommand.status.rawValue:
            let status = await watchMessagingService.status()
            let payload = OpenClawWatchStatusPayload(
                supported: status.supported,
                paired: status.paired,
                appInstalled: status.appInstalled,
                reachable: status.reachable,
                activationState: status.activationState
            )
            let message = status.paired
                ? "Apple Watch is paired"
                : "No Apple Watch paired"
            let text = """
            ## Apple Watch Status
            - message: \(message)
            - supported: \(payload.supported ? "yes" : "no")
            - paired: \(payload.paired ? "yes" : "no")
            - app_installed: \(payload.appInstalled ? "yes" : "no")
            - reachable: \(payload.reachable ? "yes" : "no")
            - activation_state: \(payload.activationState)
            """
            return ToolInvocationHelpers.successResponse(id: request.id, payload: text)
        case OpenClawWatchCommand.notify.rawValue:
            let params = try ToolInvocationHelpers.decodeParams(OpenClawWatchNotifyParams.self, from: request.paramsJSON)
            let normalizedParams = Self.normalizeWatchNotifyParams(params)
            let title = normalizedParams.title
            let body = normalizedParams.body
            if title.isEmpty, body.isEmpty {
                return BridgeInvokeResponse(
                    id: request.id,
                    ok: false,
                    error: OpenClawNodeError(code: .invalidRequest, message: "INVALID_REQUEST: empty watch notification")
                )
            }

            do {
                let result = try await watchMessagingService.sendNotification(
                    id: request.id,
                    params: normalizedParams
                )
                let payload = OpenClawWatchNotifyPayload(
                    deliveredImmediately: result.deliveredImmediately,
                    queuedForDelivery: result.queuedForDelivery,
                    transport: result.transport
                )
                let message = result.deliveredImmediately
                    ? "Notification delivered to watch"
                    : "Notification queued for delivery"
                let text = """
                <watch-notify status="ok" delivered-immediately="\(payload.deliveredImmediately ? "1" : "0")" queued="\(payload.queuedForDelivery ? "1" : "0")" transport="\(ToolInvocationHelpers.xmlEscaped(payload.transport))" message="\(ToolInvocationHelpers.xmlEscaped(message))"/>
                """
                return ToolInvocationHelpers.successResponse(id: request.id, payload: text)
            } catch {
                return BridgeInvokeResponse(
                    id: request.id,
                    ok: false,
                    error: OpenClawNodeError(code: .unavailable, message: error.localizedDescription)
                )
            }
        default:
            return ToolInvocationHelpers.invalidRequest(id: request.id, "unknown command")
        }
    }

    private func handleDeviceInvoke(_ request: BridgeInvokeRequest) async throws -> BridgeInvokeResponse {
        switch request.command {
        case OpenClawDeviceCommand.status.rawValue:
            let payload = try await deviceStatusService.status()
            var parts: [String] = []
            if let level = payload.battery.level {
                parts.append("Battery: \(Int(level * 100))%")
            }
            let freeGB = Double(payload.storage.freeBytes) / (1024.0 * 1024.0 * 1024.0)
            let totalGB = Double(payload.storage.totalBytes) / (1024.0 * 1024.0 * 1024.0)
            parts.append(String(format: "Storage: %.1f/%.1f GB free", freeGB, totalGB))
            let message = parts.isEmpty ? "Device status retrieved" : parts.joined(separator: ", ")
            let text = """
            ## Device Status
            - summary: \(message)
            - battery_state: \(payload.battery.state.rawValue)
            - low_power_mode: \(payload.battery.lowPowerModeEnabled ? "on" : "off")
            - thermal_state: \(payload.thermal.state.rawValue)
            - network_status: \(payload.network.status.rawValue)
            - interfaces: \(payload.network.interfaces.map(\.rawValue).joined(separator: ", "))
            - uptime_seconds: \(Int(payload.uptimeSeconds))
            """
            return ToolInvocationHelpers.successResponse(id: request.id, payload: text)
        case OpenClawDeviceCommand.info.rawValue:
            let payload = deviceStatusService.info()
            let message = "\(payload.deviceName) running \(payload.systemName) \(payload.systemVersion)"
            let text = """
            ## Device Info
            - summary: \(message)
            - model_identifier: \(payload.modelIdentifier)
            - app_version: \(payload.appVersion) (\(payload.appBuild))
            - locale: \(payload.locale)
            """
            return ToolInvocationHelpers.successResponse(id: request.id, payload: text)
        case "current.time":
            struct RuntimeTimeParams: Decodable {
                var timezone: String?
                var locale: String?
            }

            let params = (try? ToolInvocationHelpers.decodeParams(RuntimeTimeParams.self, from: request.paramsJSON)) ?? RuntimeTimeParams()
            let requestedTimezone = params.timezone?.trimmingCharacters(in: .whitespacesAndNewlines)
            let requestedLocale = params.locale?.trimmingCharacters(in: .whitespacesAndNewlines)

            let timeZoneIdentifier = (requestedTimezone?.isEmpty == false)
                ? requestedTimezone!
                : TimeZone.autoupdatingCurrent.identifier
            guard let timeZone = TimeZone(identifier: timeZoneIdentifier) else {
                return BridgeInvokeResponse(
                    id: request.id,
                    ok: false,
                    error: OpenClawNodeError(code: .invalidRequest, message: "INVALID_REQUEST: unknown timezone")
                )
            }

            let localeIdentifier = (requestedLocale?.isEmpty == false)
                ? requestedLocale!
                : Locale.autoupdatingCurrent.identifier
            let locale = Locale(identifier: localeIdentifier)
            let now = Date()
            let unixMs = Int64(now.timeIntervalSince1970 * 1000)

            let isoFormatter = ISO8601DateFormatter()
            isoFormatter.timeZone = timeZone
            isoFormatter.formatOptions = [.withInternetDateTime]
            let iso8601 = isoFormatter.string(from: now)

            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second, .weekday], from: now)
            let weekday = components.weekday.map { index in
                guard index >= 1, index <= calendar.weekdaySymbols.count else { return "" }
                return calendar.weekdaySymbols[index - 1]
            } ?? ""

            let text = """
            ## Runtime Time
            - iso8601: \(iso8601)
            - unix_ms: \(unixMs)
            - timezone: \(timeZone.identifier)
            - locale: \(locale.identifier)
            - date: \(components.year ?? 0)-\(String(format: "%02d", components.month ?? 0))-\(String(format: "%02d", components.day ?? 0))
            - time: \(String(format: "%02d", components.hour ?? 0)):\(String(format: "%02d", components.minute ?? 0)):\(String(format: "%02d", components.second ?? 0))
            - weekday: \(weekday)
            """
            return ToolInvocationHelpers.successResponse(id: request.id, payload: text)
        default:
            return ToolInvocationHelpers.invalidRequest(id: request.id, "unknown command")
        }
    }

    private func handlePhotosInvoke(_ request: BridgeInvokeRequest) async throws -> BridgeInvokeResponse {
        let params = (try? ToolInvocationHelpers.decodeParams(OpenClawPhotosLatestParams.self, from: request.paramsJSON))
            ?? OpenClawPhotosLatestParams()
        let mediaPayload = try await photosService.latest(params: params)
        let photoTags = try mediaPayload.photos.enumerated().map { index, photo in
            let mediaFile = try persistMediaData(
                photo.data,
                photo.format,
                "photo"
            )
            return ToolInvocationHelpers.composeTag(
                name: "photo",
                attributes: [
                    ("index", "\(index + 1)"),
                    ("format", photo.format),
                    ("mime-type", ToolInvocationHelpers.mimeType(for: photo.format)),
                    ("size-bytes", "\(mediaFile.sizeBytes)"),
                    ("width", "\(photo.width)"),
                    ("height", "\(photo.height)"),
                    ("created-at", photo.createdAt ?? ""),
                    ("path", mediaFile.path),
                ]
            )
        }

        let count = photoTags.count
        let message = count == 0
            ? "No photos found"
            : "Retrieved \(count) photo\(count == 1 ? "" : "s")"
        let payload = ToolInvocationHelpers.composeBlock(
            name: "photos",
            attributes: [("count", "\(count)"), ("message", message)],
            children: photoTags
        )
        return ToolInvocationHelpers.successResponse(id: request.id, payload: payload)
    }

    private func handleImageInvoke(_ request: BridgeInvokeRequest) async throws -> BridgeInvokeResponse {
        switch request.command {
        case OpenClawImageCommand.removeBackground.rawValue:
            let params = try ToolInvocationHelpers.decodeParams(OpenClawImageRemoveBackgroundParams.self, from: request.paramsJSON)
            let payload = try await imageBackgroundRemovalService.removeBackground(
                params: params,
                fileSystemService: fileSystemService
            )
            let message = "Removed background -> \(payload.outputPath)"
            let text = """
            <image-remove-background status="ok" format="\(payload.format)" width="\(payload.width)" height="\(payload.height)" bytes="\(payload.bytes)" input="\(ToolInvocationHelpers.xmlEscaped(payload.inputPath))" output="\(ToolInvocationHelpers.xmlEscaped(payload.outputPath))" message="\(ToolInvocationHelpers.xmlEscaped(message))"/>
            """
            return ToolInvocationHelpers.successResponse(id: request.id, payload: text)
        default:
            return ToolInvocationHelpers.invalidRequest(id: request.id, "unknown command")
        }
    }

    private func handleContactsInvoke(_ request: BridgeInvokeRequest) async throws -> BridgeInvokeResponse {
        switch request.command {
        case OpenClawContactsCommand.search.rawValue:
            let params = (try? ToolInvocationHelpers.decodeParams(OpenClawContactsSearchParams.self, from: request.paramsJSON))
                ?? OpenClawContactsSearchParams()
            let payload = try await contactsService.search(params: params)
            let count = payload.contacts.count
            let message = count == 0
                ? "No contacts found"
                : "Found \(count) contact\(count == 1 ? "" : "s")"
            let contactLines = payload.contacts.map { contact in
                let phone = contact.phoneNumbers.first ?? ""
                let email = contact.emails.first ?? ""
                return "- \(contact.displayName) | phone: \(phone) | email: \(email) | id: \(contact.identifier)"
            }
            let body = contactLines.isEmpty ? "- (empty)" : contactLines.joined(separator: "\n")
            let text = "## Contacts Search\n- summary: \(message)\n\(body)"
            return ToolInvocationHelpers.successResponse(id: request.id, payload: text)
        case OpenClawContactsCommand.add.rawValue:
            let params = try ToolInvocationHelpers.decodeParams(OpenClawContactsAddParams.self, from: request.paramsJSON)
            let payload = try await contactsService.add(params: params)
            let message = "Added contact: \(payload.contact.displayName)"
            let c = payload.contact
            let text = """
            ## Contact Added
            - summary: \(message)
            - name: \(c.displayName)
            - phones: \(c.phoneNumbers.joined(separator: ", "))
            - emails: \(c.emails.joined(separator: ", "))
            - id: \(c.identifier)
            """
            return ToolInvocationHelpers.successResponse(id: request.id, payload: text)
        default:
            return ToolInvocationHelpers.invalidRequest(id: request.id, "unknown command")
        }
    }

    private func handleCalendarInvoke(_ request: BridgeInvokeRequest) async throws -> BridgeInvokeResponse {
        switch request.command {
        case OpenClawCalendarCommand.events.rawValue:
            let params = (try? ToolInvocationHelpers.decodeParams(OpenClawCalendarEventsParams.self, from: request.paramsJSON))
                ?? OpenClawCalendarEventsParams()
            let payload = try await calendarService.events(params: params)
            let count = payload.events.count
            let message = count == 0
                ? "No events found"
                : "Found \(count) event\(count == 1 ? "" : "s")"
            let lines = payload.events.map { event in
                "- \(event.startISO) → \(event.endISO) | \(event.title) | all_day=\(event.isAllDay ? "yes" : "no")"
            }
            let text = "## Calendar Events\n- summary: \(message)\n\(lines.isEmpty ? "- (empty)" : lines.joined(separator: "\n"))"
            return ToolInvocationHelpers.successResponse(id: request.id, payload: text)
        case OpenClawCalendarCommand.add.rawValue:
            let params = try ToolInvocationHelpers.decodeParams(OpenClawCalendarAddParams.self, from: request.paramsJSON)
            let payload = try await calendarService.add(params: params)
            let text = """
            ## Calendar Event Created
            - title: \(payload.event.title)
            - start: \(payload.event.startISO)
            - end: \(payload.event.endISO)
            - all_day: \(payload.event.isAllDay ? "yes" : "no")
            """
            return ToolInvocationHelpers.successResponse(id: request.id, payload: text)
        default:
            return ToolInvocationHelpers.invalidRequest(id: request.id, "unknown command")
        }
    }

    private func handleRemindersInvoke(_ request: BridgeInvokeRequest) async throws -> BridgeInvokeResponse {
        switch request.command {
        case OpenClawRemindersCommand.list.rawValue:
            let params = (try? ToolInvocationHelpers.decodeParams(OpenClawRemindersListParams.self, from: request.paramsJSON))
                ?? OpenClawRemindersListParams()
            let payload = try await remindersService.list(params: params)
            let count = payload.reminders.count
            let message = count == 0
                ? "No reminders found"
                : "Found \(count) reminder\(count == 1 ? "" : "s")"
            let lines = payload.reminders.map { reminder in
                "- \(reminder.title) | due: \(reminder.dueISO ?? "none") | completed: \(reminder.completed ? "yes" : "no") | id: \(reminder.identifier)"
            }
            let text = "## Reminders\n- summary: \(message)\n\(lines.isEmpty ? "- (empty)" : lines.joined(separator: "\n"))"
            return ToolInvocationHelpers.successResponse(id: request.id, payload: text)
        case OpenClawRemindersCommand.add.rawValue:
            let params = try ToolInvocationHelpers.decodeParams(OpenClawRemindersAddParams.self, from: request.paramsJSON)
            let payload = try await remindersService.add(params: params)
            let text = """
            ## Reminder Created
            - title: \(payload.reminder.title)
            - due: \(payload.reminder.dueISO ?? "none")
            - id: \(payload.reminder.identifier)
            """
            return ToolInvocationHelpers.successResponse(id: request.id, payload: text)
        default:
            return ToolInvocationHelpers.invalidRequest(id: request.id, "unknown command")
        }
    }

    private func handleCronInvoke(_ request: BridgeInvokeRequest) async throws -> BridgeInvokeResponse {
        struct CronParams: Decodable {
            var action: String
            var message: String?
            var kind: String?
            var agentId: String?
            var agent_id: String?
            var at: String?
            var everySeconds: Int?
            var every_seconds: Int?
            var id: String?
            var jobId: String?
            var job_id: String?
        }

        let params = try ToolInvocationHelpers.decodeParams(CronParams.self, from: request.paramsJSON)
        let action = params.action.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        switch action {
        case "add":
            guard let message = AppConfig.nonEmpty(params.message) else {
                return BridgeInvokeResponse(
                    id: request.id,
                    ok: false,
                    error: OpenClawNodeError(code: .invalidRequest, message: "INVALID_REQUEST: message is required for add")
                )
            }
            let kind: CronJobKind
            if let kindStr = AppConfig.nonEmpty(params.kind) {
                switch kindStr.lowercased() {
                case "heartbeat": kind = .heartbeat
                default: kind = .notify
                }
            } else {
                kind = .notify
            }
            let agentID = AppConfig.nonEmpty(params.agentId) ?? AppConfig.nonEmpty(params.agent_id)
            let result = try await cronService.add(
                message: message,
                atISO: AppConfig.nonEmpty(params.at),
                everySeconds: params.everySeconds ?? params.every_seconds,
                kind: kind,
                agentID: agentID
            )
            let text = "## Cron Job Added\n- id: \(result.id)\n- message: \(result.message)\n- kind: \(result.kind)\n- at: \(result.at ?? "none")\n- every_seconds: \(result.everySeconds.map { "\($0)" } ?? "none")"
            return ToolInvocationHelpers.successResponse(id: request.id, payload: text)

        case "list":
            let result = try await cronService.list()
            let lines = result.jobs.map { job in
                "- [\(job.id)] \(job.kind) | \(job.message) | at=\(job.at ?? "none") | every=\(job.everySeconds.map { "\($0)s" } ?? "none")"
            }
            let body = lines.isEmpty ? "- (empty)" : lines.joined(separator: "\n")
            let text = "## Cron Jobs\n- total: \(result.jobs.count)\n\(body)"
            return ToolInvocationHelpers.successResponse(id: request.id, payload: text)

        case "remove":
            let jobID = AppConfig.nonEmpty(params.id) ?? AppConfig.nonEmpty(params.jobId) ?? AppConfig.nonEmpty(params.job_id)
            guard let jobID else {
                return BridgeInvokeResponse(
                    id: request.id,
                    ok: false,
                    error: OpenClawNodeError(code: .invalidRequest, message: "INVALID_REQUEST: id is required for remove")
                )
            }
            let result = try await cronService.remove(id: jobID)
            let text = result.removed
                ? "## Cron Job Removed\n- id: \(jobID)"
                : "## Cron Job Not Found\n- id: \(jobID)"
            return ToolInvocationHelpers.successResponse(id: request.id, payload: text)

        default:
            return BridgeInvokeResponse(
                id: request.id,
                ok: false,
                error: OpenClawNodeError(code: .invalidRequest, message: "INVALID_REQUEST: unknown cron action '\(action)'")
            )
        }
    }

    private func handleMotionInvoke(_ request: BridgeInvokeRequest) async throws -> BridgeInvokeResponse {
        switch request.command {
        case OpenClawMotionCommand.activity.rawValue:
            let params = (try? ToolInvocationHelpers.decodeParams(OpenClawMotionActivityParams.self, from: request.paramsJSON))
                ?? OpenClawMotionActivityParams()
            let payload = try await motionService.activities(params: params)
            let lines = payload.activities.map { activity in
                let type: String
                if activity.isWalking { type = "walking" }
                else if activity.isRunning { type = "running" }
                else if activity.isCycling { type = "cycling" }
                else if activity.isAutomotive { type = "automotive" }
                else if activity.isStationary { type = "stationary" }
                else { type = "unknown" }
                return "- \(activity.startISO) → \(activity.endISO) | type=\(type) | confidence=\(activity.confidence)"
            }
            let body = lines.isEmpty ? "- (empty)" : lines.joined(separator: "\n")
            let text = "## Motion Activity\n- summary: \(payload.activities.count) record(s)\n\(body)"
            return ToolInvocationHelpers.successResponse(id: request.id, payload: text)
        case OpenClawMotionCommand.pedometer.rawValue:
            let params = try ToolInvocationHelpers.decodeParams(OpenClawPedometerParams.self, from: request.paramsJSON)
            let payload = try await motionService.pedometer(params: params)
            let text = """
            ## Pedometer
            - start: \(payload.startISO)
            - end: \(payload.endISO)
            - steps: \(payload.steps.map { "\($0)" } ?? "n/a")
            - distance_m: \(payload.distanceMeters.map { String(format: "%.1f", $0) } ?? "n/a")
            - floors_ascended: \(payload.floorsAscended.map { "\($0)" } ?? "n/a")
            - floors_descended: \(payload.floorsDescended.map { "\($0)" } ?? "n/a")
            """
            return ToolInvocationHelpers.successResponse(id: request.id, payload: text)
        default:
            return ToolInvocationHelpers.invalidRequest(id: request.id, "unknown command")
        }
    }

    private func handleSpeechInvoke(_ request: BridgeInvokeRequest) async throws -> BridgeInvokeResponse {
        switch request.command {
        case OpenClawSpeechCommand.transcribe.rawValue:
            let params = try ToolInvocationHelpers.decodeParams(OpenClawSpeechTranscribeParams.self, from: request.paramsJSON)
            let payload = try await speechService.transcribe(params: params)
            let text = "## Speech Transcription\n- file: \(params.filePath)\n- locale: \(payload.locale)\n- text: \(payload.text)"
            return ToolInvocationHelpers.successResponse(id: request.id, payload: text)
        default:
            return ToolInvocationHelpers.invalidRequest(id: request.id, "unknown command")
        }
    }

    // MARK: - Watch Param Normalization

    private static func normalizeWatchNotifyParams(_ params: OpenClawWatchNotifyParams) -> OpenClawWatchNotifyParams {
        var params = params
        params.title = trimmedOrNil(params.title) ?? ""
        params.body = trimmedOrNil(params.body) ?? ""
        params.actions = normalizeWatchActions(params.actions)
        return params
    }

    private static func normalizeWatchActions(_ actions: [OpenClawWatchAction]?) -> [OpenClawWatchAction]? {
        guard let actions else { return nil }
        return actions.compactMap { action -> OpenClawWatchAction? in
            guard let id = trimmedOrNil(action.id),
                  let label = trimmedOrNil(action.label)
            else { return nil }
            return OpenClawWatchAction(
                id: id,
                label: label,
                style: action.style
            )
        }
    }

    private static func trimmedOrNil(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private func makeTool(
    functionName: String,
    command: String,
    description: String,
    schema: [String: Any] = [:],
    isReadOnly: Bool = false,
    isDestructive: Bool = false,
    isConcurrencySafe: Bool = true,
    maxResultSizeChars: Int? = nil
) -> ToolDefinition {
    ToolDefinition(
        functionName: functionName,
        command: command,
        description: description,
        parametersSchema: AnyCodable(schema),
        isReadOnly: isReadOnly,
        isDestructive: isDestructive,
        isConcurrencySafe: isConcurrencySafe,
        maxResultSizeChars: maxResultSizeChars
    )
}
