import ChatClient
import CoreLocation
import Foundation
import OpenClawKit
import OpenClawProtocol
import UserNotifications

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

@MainActor
final class LocalToolInvokeService: @unchecked Sendable {
    private enum InvocationContext {
        /// Session identifier propagated from chat layer for tool state isolation.
        @TaskLocal static var sessionID: String?
        @TaskLocal static var teamContext: TeamInvocationContext?
    }

    private struct TeamInvocationContext {
        let teamName: String
        let memberID: String
    }

    private static var isMacCatalyst: Bool {
        #if targetEnvironment(macCatalyst)
            true
        #else
            false
        #endif
    }

    private static var catalystRestrictedCommands: Set<String> {
        [
            OpenClawWatchCommand.status.rawValue,
            OpenClawWatchCommand.notify.rawValue,
            OpenClawMotionCommand.activity.rawValue,
            OpenClawMotionCommand.pedometer.rawValue,
        ]
    }

    private static func unsupportedPlatformMessage(for command: String) -> String? {
        guard isMacCatalyst,
              catalystRestrictedCommands.contains(command)
        else {
            return nil
        }
        return "UNAVAILABLE: this capability is not supported in Mac Catalyst. 当前在 Mac Catalyst 环境受限。"
    }

    private static var notificationAuthorizationGuidance: String {
        #if targetEnvironment(macCatalyst)
            "请在 macOS 系统设置 > 通知 > OpenAva 中开启通知权限。"
        #else
            "请在 iOS 设置 > 通知 > OpenAva 中开启通知权限。"
        #endif
    }

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
    private let webFetchService: WebFetchService
    private let webSearchService: WebSearchService
    private let imageSearchService: ImageSearchService
    private let youTubeTranscriptService: YouTubeTranscriptService
    private let webViewToolService: WebViewService
    private let javaScriptService: JavaScriptService
    private let textImageRenderService: TextImageRenderService
    private let fileSystemService: FileSystemService
    private let workspaceRootURL: URL?
    private let runtimeRootURL: URL?
    private let modelConfig: AppConfig.LLMModel?
    private let weatherService: WeatherService
    private let yahooFinanceService: YahooFinanceService
    private let aShareMarketService: AShareMarketService

    private lazy var capabilityRouter: NodeCapabilityRouter = self.buildCapabilityRouter()

    static func makeDefault(workspaceRootURL: URL? = nil, runtimeRootURL: URL? = nil, modelConfig: AppConfig.LLMModel? = nil) -> LocalToolInvokeService {
        // Register all tools on first initialization
        Task { @MainActor in
            await registerAllTools()
        }

        let builtInSkillRoots = AgentSkillsLoader.builtInSkillsRoot().map { [$0] } ?? []
        let notificationCenter = LiveNotificationCenter()

        return LocalToolInvokeService(
            cameraService: CameraController(),
            screenRecordingService: ScreenRecordService(),
            locationService: LocationService(),
            deviceStatusService: DeviceStatusService(),
            watchMessagingService: WatchMessagingService(),
            photosService: PhotoLibraryService(),
            imageBackgroundRemovalService: ImageBackgroundRemovalService(),
            contactsService: ContactsService(),
            calendarService: CalendarService(),
            remindersService: RemindersService(),
            motionService: MotionService(),
            userNotifyService: UserNotifyService(notificationCenter: notificationCenter),
            speechService: SpeechService(baseDirectoryURL: workspaceRootURL),
            cronService: CronService(),
            notificationCenter: notificationCenter,
            webFetchService: WebFetchService(),
            webSearchService: WebSearchService(),
            imageSearchService: ImageSearchService(),
            youTubeTranscriptService: YouTubeTranscriptService(),
            webViewToolService: WebViewService.shared,
            javaScriptService: JavaScriptService(),
            textImageRenderService: TextImageRenderService(),
            fileSystemService: FileSystemService(
                baseDirectoryURL: workspaceRootURL,
                additionalReadableRootURLs: builtInSkillRoots
            ),
            modelConfig: modelConfig,
            weatherService: WeatherService(),
            yahooFinanceService: YahooFinanceService(),
            aShareMarketService: AShareMarketService(),
            workspaceRootURL: workspaceRootURL,
            runtimeRootURL: runtimeRootURL
        )
    }

    init(
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
        webFetchService: WebFetchService,
        webSearchService: WebSearchService,
        imageSearchService: ImageSearchService,
        youTubeTranscriptService: YouTubeTranscriptService,
        webViewToolService: WebViewService,
        javaScriptService: JavaScriptService,
        textImageRenderService: TextImageRenderService,
        fileSystemService: FileSystemService,
        modelConfig: AppConfig.LLMModel? = nil,
        weatherService: WeatherService = WeatherService(),
        yahooFinanceService: YahooFinanceService = YahooFinanceService(),
        aShareMarketService: AShareMarketService = AShareMarketService(),
        workspaceRootURL: URL? = nil,
        runtimeRootURL: URL? = nil
    ) {
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
        self.webFetchService = webFetchService
        self.webSearchService = webSearchService
        self.imageSearchService = imageSearchService
        self.youTubeTranscriptService = youTubeTranscriptService
        self.webViewToolService = webViewToolService
        self.javaScriptService = javaScriptService
        self.textImageRenderService = textImageRenderService
        self.fileSystemService = fileSystemService
        self.workspaceRootURL = workspaceRootURL
        self.runtimeRootURL = runtimeRootURL
        self.modelConfig = modelConfig
        self.weatherService = weatherService
        self.yahooFinanceService = yahooFinanceService
        self.aShareMarketService = aShareMarketService
        TeamSwarmCoordinator.shared.configure(
            runtimeRootURL: runtimeRootURL,
            workspaceRootURL: workspaceRootURL,
            modelConfig: modelConfig
        )
    }

    func handle(_ request: BridgeInvokeRequest) async -> BridgeInvokeResponse {
        if let message = Self.unsupportedPlatformMessage(for: request.command) {
            return BridgeInvokeResponse(
                id: request.id,
                ok: false,
                error: OpenClawNodeError(code: .unavailable, message: message)
            )
        }

        do {
            return try await capabilityRouter.handle(request)
        } catch let error as NodeCapabilityRouter.RouterError {
            switch error {
            case .unknownCommand:
                return BridgeInvokeResponse(
                    id: request.id,
                    ok: false,
                    error: OpenClawNodeError(code: .invalidRequest, message: "INVALID_REQUEST: unknown command")
                )
            case .handlerUnavailable:
                return BridgeInvokeResponse(
                    id: request.id,
                    ok: false,
                    error: OpenClawNodeError(code: .unavailable, message: "UNAVAILABLE: local tool handler unavailable")
                )
            }
        } catch {
            return BridgeInvokeResponse(
                id: request.id,
                ok: false,
                error: OpenClawNodeError(code: .unavailable, message: error.localizedDescription)
            )
        }
    }

    func handle(_ request: BridgeInvokeRequest, sessionID: String?) async -> BridgeInvokeResponse {
        await InvocationContext.$sessionID.withValue(sessionID) {
            await self.handle(request)
        }
    }

    private func handle(
        _ request: BridgeInvokeRequest,
        sessionID: String?,
        teamContext: TeamInvocationContext?
    ) async -> BridgeInvokeResponse {
        await InvocationContext.$sessionID.withValue(sessionID) {
            await InvocationContext.$teamContext.withValue(teamContext) {
                await self.handle(request)
            }
        }
    }

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

        // Actively request location permission on first use instead of failing fast.
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

        let params = (try? Self.decodeParams(OpenClawLocationGetParams.self, from: request.paramsJSON))
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
        return BridgeInvokeResponse(id: request.id, ok: true, payload: text)
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
            let params = (try? Self.decodeParams(OpenClawCameraSnapParams.self, from: request.paramsJSON))
                ?? OpenClawCameraSnapParams()
            let result = try await cameraService.snap(params: params)
            let mediaFile = try persistMediaData(
                result.data,
                suggestedExtension: result.format,
                prefix: "camera-snap"
            )
            let payload = Self.composeTag(
                name: "media",
                attributes: [
                    ("tool", "camera_snap"),
                    ("format", result.format),
                    ("mime-type", Self.mimeType(for: result.format)),
                    ("size-bytes", "\(mediaFile.sizeBytes)"),
                    ("width", "\(result.width)"),
                    ("height", "\(result.height)"),
                    ("path", mediaFile.path),
                ]
            )
            return BridgeInvokeResponse(id: request.id, ok: true, payload: payload)
        case OpenClawCameraCommand.clip.rawValue:
            let params = (try? Self.decodeParams(OpenClawCameraClipParams.self, from: request.paramsJSON))
                ?? OpenClawCameraClipParams()
            let result = try await cameraService.clip(params: params)
            let mediaFile = try persistMediaData(
                result.data,
                suggestedExtension: result.format,
                prefix: "camera-clip"
            )
            let payload = Self.composeTag(
                name: "media",
                attributes: [
                    ("tool", "camera_clip"),
                    ("format", result.format),
                    ("mime-type", Self.mimeType(for: result.format)),
                    ("size-bytes", "\(mediaFile.sizeBytes)"),
                    ("duration-ms", "\(result.durationMs)"),
                    ("has-audio", result.hasAudio ? "1" : "0"),
                    ("path", mediaFile.path),
                ]
            )
            return BridgeInvokeResponse(id: request.id, ok: true, payload: payload)
        default:
            return BridgeInvokeResponse(
                id: request.id,
                ok: false,
                error: OpenClawNodeError(code: .invalidRequest, message: "INVALID_REQUEST: unknown command")
            )
        }
    }

    private func handleScreenRecordInvoke(_ request: BridgeInvokeRequest) async throws -> BridgeInvokeResponse {
        let params = (try? Self.decodeParams(OpenClawScreenRecordParams.self, from: request.paramsJSON))
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
        let payload = Self.composeTag(
            name: "media",
            attributes: [
                ("tool", "screen_record"),
                ("format", "mp4"),
                ("mime-type", Self.mimeType(for: "mp4")),
                ("size-bytes", "\(fileSize)"),
                ("duration-ms", "\(params.durationMs ?? 0)"),
                ("fps", "\(params.fps ?? 0)"),
                ("screen-index", "\(params.screenIndex ?? 0)"),
                ("has-audio", (params.includeAudio ?? true) ? "1" : "0"),
                ("path", path),
            ]
        )
        return BridgeInvokeResponse(id: request.id, ok: true, payload: payload)
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

        let params = try Self.decodeParams(MergedNotifyParams.self, from: request.paramsJSON)
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
                        message: "NOT_AUTHORIZED: notifications. \(Self.notificationAuthorizationGuidance)"
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
            return BridgeInvokeResponse(id: request.id, ok: true, payload: text)
        case OpenClawWatchCommand.notify.rawValue:
            let params = try Self.decodeParams(OpenClawWatchNotifyParams.self, from: request.paramsJSON)
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
                <watch-notify status="ok" delivered-immediately="\(payload.deliveredImmediately ? "1" : "0")" queued="\(payload.queuedForDelivery ? "1" : "0")" transport="\(Self.xmlEscaped(payload.transport))" message="\(Self.xmlEscaped(message))"/>
                """
                return BridgeInvokeResponse(id: request.id, ok: true, payload: text)
            } catch {
                return BridgeInvokeResponse(
                    id: request.id,
                    ok: false,
                    error: OpenClawNodeError(code: .unavailable, message: error.localizedDescription)
                )
            }
        default:
            return BridgeInvokeResponse(
                id: request.id,
                ok: false,
                error: OpenClawNodeError(code: .invalidRequest, message: "INVALID_REQUEST: unknown command")
            )
        }
    }

    private func handleDeviceInvoke(_ request: BridgeInvokeRequest) async throws -> BridgeInvokeResponse {
        switch request.command {
        case OpenClawDeviceCommand.status.rawValue:
            let payload = try await deviceStatusService.status()
            // Generate human-readable message from device status
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
            return BridgeInvokeResponse(id: request.id, ok: true, payload: text)
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
            return BridgeInvokeResponse(id: request.id, ok: true, payload: text)
        case "current.time":
            struct RuntimeTimeParams: Decodable {
                var timezone: String?
                var locale: String?
            }

            let params = (try? Self.decodeParams(RuntimeTimeParams.self, from: request.paramsJSON)) ?? RuntimeTimeParams()
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

            // Use a fixed Gregorian calendar for stable date fields across locales.
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
            return BridgeInvokeResponse(id: request.id, ok: true, payload: text)
        default:
            return BridgeInvokeResponse(
                id: request.id,
                ok: false,
                error: OpenClawNodeError(code: .invalidRequest, message: "INVALID_REQUEST: unknown command")
            )
        }
    }

    private func handlePhotosInvoke(_ request: BridgeInvokeRequest) async throws -> BridgeInvokeResponse {
        let params = (try? Self.decodeParams(OpenClawPhotosLatestParams.self, from: request.paramsJSON))
            ?? OpenClawPhotosLatestParams()
        let mediaPayload = try await photosService.latest(params: params)
        let photoTags = try mediaPayload.photos.enumerated().map { index, photo in
            let mediaFile = try persistMediaData(
                photo.data,
                suggestedExtension: photo.format,
                prefix: "photo"
            )
            return Self.composeTag(
                name: "photo",
                attributes: [
                    ("index", "\(index + 1)"),
                    ("format", photo.format),
                    ("mime-type", Self.mimeType(for: photo.format)),
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
        let payload = Self.composeBlock(
            name: "photos",
            attributes: [("count", "\(count)"), ("message", message)],
            children: photoTags
        )
        return BridgeInvokeResponse(id: request.id, ok: true, payload: payload)
    }

    private func handleImageInvoke(_ request: BridgeInvokeRequest) async throws -> BridgeInvokeResponse {
        switch request.command {
        case OpenClawImageCommand.removeBackground.rawValue:
            let params = try Self.decodeParams(OpenClawImageRemoveBackgroundParams.self, from: request.paramsJSON)
            let payload = try await imageBackgroundRemovalService.removeBackground(
                params: params,
                fileSystemService: fileSystemService
            )
            let message = "Removed background -> \(payload.outputPath)"
            let text = """
            <image-remove-background status="ok" format="\(payload.format)" width="\(payload.width)" height="\(payload.height)" bytes="\(payload.bytes)" input="\(Self.xmlEscaped(payload.inputPath))" output="\(Self.xmlEscaped(payload.outputPath))" message="\(Self.xmlEscaped(message))"/>
            """
            return BridgeInvokeResponse(id: request.id, ok: true, payload: text)
        default:
            return BridgeInvokeResponse(
                id: request.id,
                ok: false,
                error: OpenClawNodeError(code: .invalidRequest, message: "INVALID_REQUEST: unknown command")
            )
        }
    }

    private func handleContactsInvoke(_ request: BridgeInvokeRequest) async throws -> BridgeInvokeResponse {
        switch request.command {
        case OpenClawContactsCommand.search.rawValue:
            let params = (try? Self.decodeParams(OpenClawContactsSearchParams.self, from: request.paramsJSON))
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
            return BridgeInvokeResponse(id: request.id, ok: true, payload: text)
        case OpenClawContactsCommand.add.rawValue:
            let params = try Self.decodeParams(OpenClawContactsAddParams.self, from: request.paramsJSON)
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
            return BridgeInvokeResponse(id: request.id, ok: true, payload: text)
        default:
            return BridgeInvokeResponse(
                id: request.id,
                ok: false,
                error: OpenClawNodeError(code: .invalidRequest, message: "INVALID_REQUEST: unknown command")
            )
        }
    }

    private func handleCalendarInvoke(_ request: BridgeInvokeRequest) async throws -> BridgeInvokeResponse {
        switch request.command {
        case OpenClawCalendarCommand.events.rawValue:
            let params = (try? Self.decodeParams(OpenClawCalendarEventsParams.self, from: request.paramsJSON))
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
            return BridgeInvokeResponse(id: request.id, ok: true, payload: text)
        case OpenClawCalendarCommand.add.rawValue:
            let params = try Self.decodeParams(OpenClawCalendarAddParams.self, from: request.paramsJSON)
            let payload = try await calendarService.add(params: params)
            let message = "Added event: \(payload.event.title)"
            let event = payload.event
            let text = """
            ## Calendar Event Added
            - summary: \(message)
            - start: \(event.startISO)
            - end: \(event.endISO)
            - calendar: \(event.calendarTitle ?? "")
            - id: \(event.identifier)
            """
            return BridgeInvokeResponse(id: request.id, ok: true, payload: text)
        default:
            return BridgeInvokeResponse(
                id: request.id,
                ok: false,
                error: OpenClawNodeError(code: .invalidRequest, message: "INVALID_REQUEST: unknown command")
            )
        }
    }

    private func handleRemindersInvoke(_ request: BridgeInvokeRequest) async throws -> BridgeInvokeResponse {
        switch request.command {
        case OpenClawRemindersCommand.list.rawValue:
            let params = (try? Self.decodeParams(OpenClawRemindersListParams.self, from: request.paramsJSON))
                ?? OpenClawRemindersListParams()
            let payload = try await remindersService.list(params: params)
            let count = payload.reminders.count
            let incomplete = payload.reminders.filter { !$0.completed }.count
            let completed = count - incomplete
            let message = count == 0
                ? "No reminders found"
                : "Found \(count) reminder\(count == 1 ? "" : "s") (\(incomplete) incomplete, \(completed) completed)"
            let lines = payload.reminders.map { reminder in
                "- [\(reminder.completed ? "x" : " ")] \(reminder.title) | due=\(reminder.dueISO ?? "") | list=\(reminder.listName ?? "")"
            }
            let text = "## Reminders\n- summary: \(message)\n\(lines.isEmpty ? "- (empty)" : lines.joined(separator: "\n"))"
            return BridgeInvokeResponse(id: request.id, ok: true, payload: text)
        case OpenClawRemindersCommand.add.rawValue:
            let params = try Self.decodeParams(OpenClawRemindersAddParams.self, from: request.paramsJSON)
            let payload = try await remindersService.add(params: params)
            let message = "Added reminder: \(payload.reminder.title)"
            let reminder = payload.reminder
            let text = """
            ## Reminder Added
            - summary: \(message)
            - due: \(reminder.dueISO ?? "")
            - completed: \(reminder.completed ? "yes" : "no")
            - list: \(reminder.listName ?? "")
            - id: \(reminder.identifier)
            """
            return BridgeInvokeResponse(id: request.id, ok: true, payload: text)
        default:
            return BridgeInvokeResponse(
                id: request.id,
                ok: false,
                error: OpenClawNodeError(code: .invalidRequest, message: "INVALID_REQUEST: unknown command")
            )
        }
    }

    private func handleCronInvoke(_ request: BridgeInvokeRequest) async throws -> BridgeInvokeResponse {
        let params: CronParams
        do {
            params = try Self.decodeParams(CronParams.self, from: request.paramsJSON)
        } catch {
            return BridgeInvokeResponse(
                id: request.id,
                ok: false,
                error: OpenClawNodeError(
                    code: .invalidRequest,
                    message: "INVALID_REQUEST: failed to decode cron params"
                )
            )
        }

        do {
            switch params.action {
            case .add:
                let status = await requestNotificationAuthorizationIfNeeded()
                guard status == .authorized || status == .provisional || status == .ephemeral else {
                    return BridgeInvokeResponse(
                        id: request.id,
                        ok: false,
                        error: OpenClawNodeError(
                            code: .unavailable,
                            message: "NOT_AUTHORIZED: notifications. \(Self.notificationAuthorizationGuidance)"
                        )
                    )
                }

                let payload = try await CronAddPayload(job: cronService.add(
                    message: params.message ?? "",
                    atISO: params.at,
                    everySeconds: params.everySeconds,
                    kind: params.kind,
                    agentID: params.agentID
                ))
                let scheduleMessage: String
                if payload.job.schedule == "at", let at = payload.job.at {
                    scheduleMessage = "Scheduled at \(at)"
                } else if payload.job.schedule == "every", let every = payload.job.everySeconds {
                    scheduleMessage = "Scheduled every \(every)s"
                } else {
                    scheduleMessage = "Scheduled cron job"
                }
                let text = """
                ## Cron Added
                - summary: \(scheduleMessage)
                - id: \(payload.job.id)
                - kind: \(payload.job.kind.rawValue)
                - agent_id: \(payload.job.agentID ?? "")
                - message: \(payload.job.message)
                - schedule: \(payload.job.schedule)
                - next_run: \(payload.job.nextRunISO ?? "")
                """
                return BridgeInvokeResponse(id: request.id, ok: true, payload: text)

            case .list:
                let payload = try await cronService.list()
                let count = payload.jobs.count
                let message = count == 0
                    ? "No scheduled cron jobs"
                    : "Found \(count) scheduled cron job\(count == 1 ? "" : "s")"
                let lines = payload.jobs.map { job in
                    "- id=\(job.id) | kind=\(job.kind.rawValue) | agent_id=\(job.agentID ?? "") | schedule=\(job.schedule) | next=\(job.nextRunISO ?? "") | message=\(job.message)"
                }
                let text = "## Cron Jobs\n- summary: \(message)\n\(lines.isEmpty ? "- (empty)" : lines.joined(separator: "\n"))"
                return BridgeInvokeResponse(id: request.id, ok: true, payload: text)

            case .remove:
                let id = params.id?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !id.isEmpty else {
                    return BridgeInvokeResponse(
                        id: request.id,
                        ok: false,
                        error: OpenClawNodeError(code: .invalidRequest, message: "INVALID_REQUEST: id is required")
                    )
                }
                let payload = try await cronService.remove(id: id)
                let message = payload.removed
                    ? "Removed cron job \(payload.id)"
                    : "Cron job \(payload.id) not found"
                let text = "<cron-remove id=\"\(Self.xmlEscaped(payload.id))\" removed=\"\(payload.removed ? "1" : "0")\" message=\"\(Self.xmlEscaped(message))\"/>"
                return BridgeInvokeResponse(id: request.id, ok: true, payload: text)
            }
        } catch let error as CronServiceError {
            switch error {
            case let .invalidRequest(message):
                return BridgeInvokeResponse(
                    id: request.id,
                    ok: false,
                    error: OpenClawNodeError(code: .invalidRequest, message: "INVALID_REQUEST: \(message)")
                )
            case let .schedulingFailed(message):
                return BridgeInvokeResponse(
                    id: request.id,
                    ok: false,
                    error: OpenClawNodeError(code: .unavailable, message: "CRON_SCHEDULING_FAILED: \(message)")
                )
            }
        }
    }

    private func handleMotionInvoke(_ request: BridgeInvokeRequest) async throws -> BridgeInvokeResponse {
        switch request.command {
        case OpenClawMotionCommand.activity.rawValue:
            let params = (try? Self.decodeParams(OpenClawMotionActivityParams.self, from: request.paramsJSON))
                ?? OpenClawMotionActivityParams()
            let payload = try await motionService.activities(params: params)
            let count = payload.activities.count
            let message = count == 0
                ? "No activity data"
                : "Retrieved \(count) activity record\(count == 1 ? "" : "s")"
            let lines = payload.activities.map { activity in
                let modes = [
                    activity.isWalking ? "walking" : nil,
                    activity.isRunning ? "running" : nil,
                    activity.isCycling ? "cycling" : nil,
                    activity.isAutomotive ? "automotive" : nil,
                    activity.isStationary ? "stationary" : nil,
                    activity.isUnknown ? "unknown" : nil,
                ].compactMap { $0 }.joined(separator: ",")
                return "- \(activity.startISO) → \(activity.endISO) | confidence=\(activity.confidence) | modes=\(modes)"
            }
            let text = "## Motion Activity\n- summary: \(message)\n\(lines.isEmpty ? "- (empty)" : lines.joined(separator: "\n"))"
            return BridgeInvokeResponse(id: request.id, ok: true, payload: text)
        case OpenClawMotionCommand.pedometer.rawValue:
            let params = (try? Self.decodeParams(OpenClawPedometerParams.self, from: request.paramsJSON))
                ?? OpenClawPedometerParams()
            let payload = try await motionService.pedometer(params: params)
            let message = payload.steps != nil
                ? "Steps: \(payload.steps!)"
                : "Pedometer data retrieved"
            let text = """
            ## Pedometer
            - summary: \(message)
            - start: \(payload.startISO)
            - end: \(payload.endISO)
            - steps: \(payload.steps.map(String.init) ?? "")
            - distance_m: \(payload.distanceMeters.map { String(format: "%.1f", $0) } ?? "")
            - floors_up: \(payload.floorsAscended.map(String.init) ?? "")
            - floors_down: \(payload.floorsDescended.map(String.init) ?? "")
            """
            return BridgeInvokeResponse(id: request.id, ok: true, payload: text)
        default:
            return BridgeInvokeResponse(
                id: request.id,
                ok: false,
                error: OpenClawNodeError(code: .invalidRequest, message: "INVALID_REQUEST: unknown command")
            )
        }
    }

    private func handleSpeechInvoke(_ request: BridgeInvokeRequest) async throws -> BridgeInvokeResponse {
        switch request.command {
        case OpenClawSpeechCommand.transcribe.rawValue:
            let params = try Self.decodeParams(OpenClawSpeechTranscribeParams.self, from: request.paramsJSON)
            let payload = try await speechService.transcribe(params: params)
            let segmentCount = payload.segments.count
            let message = payload.text.isEmpty
                ? "No speech recognized"
                : "Transcribed \(segmentCount) segment\(segmentCount == 1 ? "" : "s")"
            let segmentLines = payload.segments.prefix(20).enumerated().map { index, segment in
                "- \(index + 1). [\(String(format: "%.2f", segment.startSeconds))s +\(String(format: "%.2f", segment.durationSeconds))s, conf=\(String(format: "%.2f", segment.confidence))] \(segment.text)"
            }
            let text = "## Speech Transcript\n- summary: \(message)\n- locale: \(payload.locale)\n- file: \(payload.filePath)\n\(segmentLines.joined(separator: "\n"))\n\n### Full Text\n\(payload.text)"
            return BridgeInvokeResponse(id: request.id, ok: true, payload: text)
        default:
            return BridgeInvokeResponse(
                id: request.id,
                ok: false,
                error: OpenClawNodeError(code: .invalidRequest, message: "INVALID_REQUEST: unknown command")
            )
        }
    }

    /// Handle web fetch requests
    private func handleWebFetchInvoke(_ request: BridgeInvokeRequest) async throws -> BridgeInvokeResponse {
        struct Params: Codable {
            let url: String
            let prompt: String
        }

        let params = try Self.decodeParams(Params.self, from: request.paramsJSON)
        guard let prompt = AppConfig.nonEmpty(params.prompt) else {
            return BridgeInvokeResponse(
                id: request.id,
                ok: false,
                error: OpenClawNodeError(code: .invalidRequest, message: "INVALID_REQUEST: prompt is required")
            )
        }

        guard let url = URL(string: params.url)
        else {
            return BridgeInvokeResponse(
                id: request.id,
                ok: false,
                error: OpenClawNodeError(code: .invalidRequest, message: "INVALID_REQUEST: invalid URL")
            )
        }

        let result = try await webFetchService.fetch(url: url)
        let processedResult = try await applyPromptToWebFetchResult(result, prompt: prompt)
        return BridgeInvokeResponse(id: request.id, ok: true, payload: result.asPromptResultText(prompt: prompt, processedResult: processedResult))
    }

    private func applyPromptToWebFetchResult(_ result: WebFetchResult, prompt: String) async throws -> String {
        guard let modelConfig else {
            throw NSError(domain: "LocalToolInvokeService.WebFetch", code: 1, userInfo: [NSLocalizedDescriptionKey: "UNAVAILABLE: no configured model for web fetch prompt processing"])
        }

        let client = LLMChatClient(modelConfig: modelConfig)
        let response = try await client.chat(
            body: ChatRequestBody(
                messages: [
                    .system(content: .text(Self.webFetchProcessingSystemPrompt)),
                    .user(content: .text(Self.webFetchProcessingUserPrompt(result: result, prompt: prompt))),
                ]
            )
        )

        let text = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return AppConfig.nonEmpty(text) ?? "The fetched content did not produce a response for the requested prompt."
    }

    private static var webFetchProcessingSystemPrompt: String {
        """
        You are processing content already fetched from the public web for a tool call.
        Answer only from the provided content.
        If the content is insufficient, say that clearly instead of guessing.
        Be concise, direct, and structured when helpful.
        """
    }

    private static func webFetchProcessingUserPrompt(result: WebFetchResult, prompt: String) -> String {
        let title = AppConfig.nonEmpty(result.title) ?? ""
        let warning = AppConfig.nonEmpty(result.warning) ?? ""
        return """
        Task:
        \(prompt)

        Fetched Page Metadata:
        - URL: \(result.url)
        - Final URL: \(result.finalUrl)
        - Status: \(result.status)
        - Content-Type: \(result.contentType)
        - Title: \(title)
        - Extractor: \(result.extractor)
        - Truncated: \(result.truncated ? "yes" : "no")
        - Warning: \(warning)

        Fetched Content:
        \(result.text)
        """
    }

    /// Dispatch all web_view* commands to the appropriate WebViewService method.
    private func handleWebViewInvoke(_ request: BridgeInvokeRequest) async throws -> BridgeInvokeResponse {
        let sessionID = normalizedWebViewSessionID()
        switch request.command {
        case "web_view":
            struct Params: Codable { let url: String }
            let params = try Self.decodeParams(Params.self, from: request.paramsJSON)
            let rawURL = params.url.trimmingCharacters(in: .whitespacesAndNewlines)
            let expandedPath = (rawURL as NSString).expandingTildeInPath
            let resolvedURL: URL?
            if expandedPath.hasPrefix("/") {
                // Treat absolute paths as local files for easier tool usage.
                resolvedURL = URL(fileURLWithPath: expandedPath)
            } else if let parsedURL = URL(string: rawURL), parsedURL.scheme != nil {
                resolvedURL = parsedURL
            } else {
                resolvedURL = nil
            }

            guard let url = resolvedURL else {
                return BridgeInvokeResponse(
                    id: request.id, ok: false,
                    error: OpenClawNodeError(code: .invalidRequest, message: "INVALID_REQUEST: invalid URL")
                )
            }
            let result = try await webViewToolService.openAndSnapshot(url: url, sessionID: sessionID)
            let lines = result.elements.joined(separator: "\n")
            let text = "## Web View\n- title: \(result.title ?? "")\n- url: \(result.finalUrl)\n- elements: \(result.count)\n\(lines)"
            return BridgeInvokeResponse(id: request.id, ok: true, payload: text)

        case "web_view_snapshot":
            let result = try await webViewToolService.snapshot(sessionID: sessionID)
            let lines = result.elements.joined(separator: "\n")
            let text = "## Web Snapshot\n- title: \(result.title ?? "")\n- url: \(result.finalUrl)\n- elements: \(result.count)\n\(lines)"
            return BridgeInvokeResponse(id: request.id, ok: true, payload: text)

        case "web_view_click":
            struct Params: Codable { let ref: String }
            let params = try Self.decodeParams(Params.self, from: request.paramsJSON)
            let result = try await webViewToolService.click(sessionID: sessionID, ref: params.ref)
            let text = "<web-action kind=\"click\" ok=\"\(result.ok ? "1" : "0")\" message=\"\(Self.xmlEscaped(result.message))\" url=\"\(Self.xmlEscaped(result.url ?? ""))\" title=\"\(Self.xmlEscaped(result.title ?? ""))\"/>"
            return BridgeInvokeResponse(id: request.id, ok: true, payload: text)

        case "web_view_type":
            struct Params: Codable { let ref: String; let text: String; let submit: Bool? }
            let params = try Self.decodeParams(Params.self, from: request.paramsJSON)
            let result = try await webViewToolService.type(sessionID: sessionID, ref: params.ref, text: params.text, submit: params.submit ?? false)
            let text = "<web-action kind=\"type\" ok=\"\(result.ok ? "1" : "0")\" message=\"\(Self.xmlEscaped(result.message))\" url=\"\(Self.xmlEscaped(result.url ?? ""))\" title=\"\(Self.xmlEscaped(result.title ?? ""))\"/>"
            return BridgeInvokeResponse(id: request.id, ok: true, payload: text)

        case "web_view_scroll":
            struct Params: Codable { let direction: String; let amount: Int? }
            let params = try Self.decodeParams(Params.self, from: request.paramsJSON)
            let result = try await webViewToolService.scroll(sessionID: sessionID, direction: params.direction, amount: params.amount ?? 300)
            let text = "<web-action kind=\"scroll\" ok=\"\(result.ok ? "1" : "0")\" message=\"\(Self.xmlEscaped(result.message))\" url=\"\(Self.xmlEscaped(result.url ?? ""))\" title=\"\(Self.xmlEscaped(result.title ?? ""))\"/>"
            return BridgeInvokeResponse(id: request.id, ok: true, payload: text)

        case "web_view_select":
            struct Params: Codable { let ref: String; let value: String }
            let params = try Self.decodeParams(Params.self, from: request.paramsJSON)
            let result = try await webViewToolService.selectOption(sessionID: sessionID, ref: params.ref, value: params.value)
            let text = "<web-action kind=\"select\" ok=\"\(result.ok ? "1" : "0")\" message=\"\(Self.xmlEscaped(result.message))\" url=\"\(Self.xmlEscaped(result.url ?? ""))\" title=\"\(Self.xmlEscaped(result.title ?? ""))\"/>"
            return BridgeInvokeResponse(id: request.id, ok: true, payload: text)

        case "web_view_navigate":
            struct Params: Codable { let direction: String }
            let params = try Self.decodeParams(Params.self, from: request.paramsJSON)
            let result = try await webViewToolService.navigate(sessionID: sessionID, direction: params.direction)
            let text = "<web-action kind=\"navigate\" ok=\"\(result.ok ? "1" : "0")\" message=\"\(Self.xmlEscaped(result.message))\" url=\"\(Self.xmlEscaped(result.url ?? ""))\" title=\"\(Self.xmlEscaped(result.title ?? ""))\"/>"
            return BridgeInvokeResponse(id: request.id, ok: true, payload: text)

        case "web_view_close":
            webViewToolService.close(sessionID: sessionID)
            return BridgeInvokeResponse(id: request.id, ok: true, payload: "Web view closed.")

        case "web_view_read":
            struct Params: Codable { let maxLength: Int? }
            let params = (try? Self.decodeParams(Params.self, from: request.paramsJSON)) ?? Params(maxLength: nil)
            let result = try await webViewToolService.readMarkdown(sessionID: sessionID, maxLength: params.maxLength ?? 120_000)
            let text = "## Web Page Read\n- title: \(result.title ?? "")\n- url: \(result.finalUrl)\n- length: \(result.length)\n\n\(result.markdown)"
            return BridgeInvokeResponse(id: request.id, ok: true, payload: text)

        default:
            return BridgeInvokeResponse(
                id: request.id, ok: false,
                error: OpenClawNodeError(code: .invalidRequest, message: "Unknown web_view command: \(request.command)")
            )
        }
    }

    private func handleJavaScriptInvoke(_ request: BridgeInvokeRequest) async throws -> BridgeInvokeResponse {
        struct Params: Decodable {
            let code: String
            let input: AnyCodable?
            let allowedTools: [String]?
            let sessionID: String?
            let timeoutMs: Int?

            enum CodingKeys: String, CodingKey {
                case code
                case input
                case allowedTools = "allowed_tools"
                case sessionID = "session_id"
                case timeoutMs = "timeout_ms"
            }
        }

        let params = try Self.decodeParams(Params.self, from: request.paramsJSON)
        let sessionID = InvocationContext.sessionID
        let allowedTools = JavaScriptService.normalizedAllowedTools(from: params.allowedTools)
        let timeoutMs = JavaScriptService.clampedTimeoutMs(params.timeoutMs)

        let payload = try await javaScriptService.execute(
            request: .init(
                code: params.code,
                input: params.input,
                allowedTools: allowedTools,
                sessionID: params.sessionID,
                timeoutMs: timeoutMs
            )
        ) { [weak self] functionName, argumentsJSON in
            guard let self else {
                return BridgeInvokeResponse(
                    id: UUID().uuidString,
                    ok: false,
                    error: OpenClawNodeError(code: .unavailable, message: "UNAVAILABLE: local tool handler unavailable")
                )
            }

            guard let command = await ToolRegistry.shared.command(forFunctionName: functionName) else {
                return BridgeInvokeResponse(
                    id: UUID().uuidString,
                    ok: false,
                    error: OpenClawNodeError(code: .invalidRequest, message: "INVALID_REQUEST: unknown tool function '\(functionName)'")
                )
            }

            let nestedRequest = BridgeInvokeRequest(
                id: UUID().uuidString,
                command: command,
                paramsJSON: argumentsJSON
            )
            return await self.handle(nestedRequest, sessionID: sessionID)
        }

        return try BridgeInvokeResponse(
            id: request.id,
            ok: true,
            payload: Self.encodePayload(payload)
        )
    }

    /// Render plain text into social-media-ready image cards.
    private func handleTextImageRenderInvoke(_ request: BridgeInvokeRequest) async throws -> BridgeInvokeResponse {
        struct Params: Codable {
            let text: String
            let title: String?
            let theme: String?
            let width: Int?
            let aspectRatio: String?
            let maxPages: Int?
        }

        let params = try Self.decodeParams(Params.self, from: request.paramsJSON)
        let result = try textImageRenderService.render(
            request: TextImageRenderService.Request(
                text: params.text,
                title: params.title,
                theme: params.theme,
                width: params.width,
                aspectRatio: params.aspectRatio,
                maxPages: params.maxPages
            )
        )

        var mediaTags: [String] = []
        for page in result.pages {
            let mediaFile = try persistMediaData(
                page.data,
                suggestedExtension: page.format,
                prefix: "text-card-p\(page.index)"
            )
            mediaTags.append(
                Self.composeTag(
                    name: "media",
                    attributes: [
                        ("tool", "text_image_render"),
                        ("page", "\(page.index)"),
                        ("total-pages", "\(page.total)"),
                        ("format", page.format),
                        ("mime-type", Self.mimeType(for: page.format)),
                        ("size-bytes", "\(mediaFile.sizeBytes)"),
                        ("width", "\(page.width)"),
                        ("height", "\(page.height)"),
                        ("path", mediaFile.path),
                    ]
                )
            )
        }

        let payload = Self.composeBlock(
            name: "text-image-render",
            attributes: [
                ("pages", "\(result.pages.count)"),
                ("truncated", result.truncated ? "1" : "0"),
                ("theme", result.theme),
            ],
            children: mediaTags
        )

        return BridgeInvokeResponse(id: request.id, ok: true, payload: payload)
    }

    private func normalizedWebViewSessionID() -> String {
        let trimmed = (InvocationContext.sessionID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "default" : trimmed
    }

    /// Handle web search requests
    private func handleWebSearchInvoke(_ request: BridgeInvokeRequest) async throws -> BridgeInvokeResponse {
        struct Params: Codable {
            let query: String
            let topK: Int?
            let fetchTopK: Int?
            let lang: String?
            let safeSearch: String?
        }

        let params = try Self.decodeParams(Params.self, from: request.paramsJSON)
        let query = params.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return BridgeInvokeResponse(
                id: request.id,
                ok: false,
                error: OpenClawNodeError(code: .invalidRequest, message: "INVALID_REQUEST: query is required")
            )
        }

        let result = try await webSearchService.search(
            query: query,
            topK: params.topK ?? 8,
            fetchTopK: params.fetchTopK ?? 3,
            lang: params.lang ?? "zh-CN",
            safeSearch: params.safeSearch ?? "moderate"
        )
        let lines = result.results.map { item in
            "\(item.rank). [\(item.title)](\(item.link)) — \(item.summary)"
        }
        let sourceLine = result.sourceStatus.map { "\($0.source):\($0.count)" }.joined(separator: ", ")
        let text = "## Web Search\n- query: \(result.query)\n- total: \(result.total)\n- sources: \(sourceLine)\n\n\(lines.joined(separator: "\n"))"
        return BridgeInvokeResponse(id: request.id, ok: true, payload: text)
    }

    /// Handle free-to-use image search requests.
    private func handleImageSearchInvoke(_ request: BridgeInvokeRequest) async throws -> BridgeInvokeResponse {
        struct Params: Codable {
            let query: String
            let topK: Int?
            let minWidth: Int?
            let minHeight: Int?
            let orientation: String?
            let safeSearch: Bool?
        }

        let params = try Self.decodeParams(Params.self, from: request.paramsJSON)
        let query = params.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return BridgeInvokeResponse(
                id: request.id,
                ok: false,
                error: OpenClawNodeError(code: .invalidRequest, message: "INVALID_REQUEST: query is required")
            )
        }

        let result = try await imageSearchService.search(
            query: query,
            topK: params.topK ?? 8,
            minWidth: params.minWidth ?? 1024,
            minHeight: params.minHeight ?? 720,
            orientation: params.orientation ?? "any",
            safeSearch: params.safeSearch ?? true
        )
        let lines = result.results.enumerated().map { index, item in
            "\(index + 1). \(item.title)\n   - image: \(item.imageURL)\n   - size: \(item.width)x\(item.height)\n   - provider: \(item.provider), license: \(item.license)"
        }
        let text = "## Image Search\n- query: \(result.query)\n- total: \(result.total)\n- filters: min=\(result.minWidth)x\(result.minHeight), orientation=\(result.orientation)\n\n\(lines.joined(separator: "\n"))"
        return BridgeInvokeResponse(id: request.id, ok: true, payload: text)
    }

    /// Handle YouTube transcript fetch requests.
    private func handleYouTubeTranscriptInvoke(_ request: BridgeInvokeRequest) async throws -> BridgeInvokeResponse {
        struct Params: Codable {
            let input: String
            let preferredLanguage: String?
            let maxSegments: Int?
            let format: String?
        }

        let params = try Self.decodeParams(Params.self, from: request.paramsJSON)
        let normalizedInput = params.input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedInput.isEmpty else {
            return BridgeInvokeResponse(
                id: request.id,
                ok: false,
                error: OpenClawNodeError(code: .invalidRequest, message: "INVALID_REQUEST: input is required")
            )
        }

        let result = try await youTubeTranscriptService.fetchTranscript(
            input: normalizedInput,
            preferredLanguage: params.preferredLanguage,
            maxSegments: params.maxSegments ?? 500
        )

        let header = "## YouTube Transcript\n- video_id: \(result.videoID)\n- title: \(result.title ?? "")\n- language: \(result.language)\n- track: \(result.trackName)\n- segments: \(result.segmentCount)\n- summary: \(result.message)"
        let text: String
        switch params.format ?? "transcript" {
        case "segments":
            let segmentLines = result.segments.enumerated().map { index, segment in
                "\(index + 1). [\(String(format: "%.2f", segment.startSeconds))s +\(String(format: "%.2f", segment.durationSeconds))s] \(segment.text)"
            }
            let body = segmentLines.isEmpty ? "- (empty)" : segmentLines.joined(separator: "\n")
            text = "\(header)\n\n\(body)"
        default: // "transcript"
            let transcriptBody = result.transcript.isEmpty ? "- (empty)" : result.transcript
            text = "\(header)\n\n### Transcript\n\(transcriptBody)"
        }
        return BridgeInvokeResponse(id: request.id, ok: true, payload: text)
    }

    /// Handle file system requests
    private func handleFileSystemInvoke(_ request: BridgeInvokeRequest) async throws -> BridgeInvokeResponse {
        func resolvedPathText(_ path: String) async throws -> String {
            let metadata = try await fileSystemService.pathMetadata(path: path)
            return metadata.resolvedPath
        }

        func conciseListText(for result: DirectoryListResult, resolvedPath: String) -> String {
            if result.items.isEmpty {
                return "Empty: \(resolvedPath)"
            }

            let itemLines = result.items.map { item in
                item.isDirectory ? "  \(item.name)/" : "  \(item.name)"
            }

            return ([resolvedPath] + itemLines).joined(separator: "\n")
        }

        switch request.command {
        case "fs.read":
            struct Params: Codable {
                let path: String
                let startLine: Int?
                let endLine: Int?
            }
            let params = try Self.decodeParams(Params.self, from: request.paramsJSON)
            let result = try await fileSystemService.readFile(
                path: params.path,
                startLine: params.startLine,
                endLine: params.endLine
            )
            var text = result.content
            if result.truncated {
                text += "\n\n... (truncated — file is \(result.totalChars) chars, limit 128000)"
            }
            return BridgeInvokeResponse(id: request.id, ok: true, payload: text)

        case "fs.write":
            struct Params: Codable {
                let path: String
                let content: String
                let createDirectories: Bool?
            }
            let params = try Self.decodeParams(Params.self, from: request.paramsJSON)
            let result = try await fileSystemService.writeFile(
                path: params.path,
                content: params.content,
                createDirectories: params.createDirectories ?? true
            )
            let resolvedPath = try await resolvedPathText(params.path)
            let verb = result.created ? "created" : "updated"
            let text = "OK: \(verb) \(result.size) bytes -> \(resolvedPath)"
            return BridgeInvokeResponse(id: request.id, ok: true, payload: text)

        case "fs.replace":
            struct Params: Codable {
                let path: String
                let oldText: String
                let newText: String
            }
            let params = try Self.decodeParams(Params.self, from: request.paramsJSON)
            let result = try await fileSystemService.replaceInFile(
                path: params.path,
                oldText: params.oldText,
                newText: params.newText
            )
            let resolvedPath = try await resolvedPathText(params.path)
            let text = "OK: replaced \(result.occurrences) occurrence\(result.occurrences == 1 ? "" : "s") -> \(resolvedPath)"
            return BridgeInvokeResponse(id: request.id, ok: true, payload: text)

        case "fs.append":
            struct Params: Codable {
                let path: String
                let content: String
            }
            let params = try Self.decodeParams(Params.self, from: request.paramsJSON)
            let result = try await fileSystemService.appendToFile(
                path: params.path,
                content: params.content
            )
            let resolvedPath = try await resolvedPathText(params.path)
            let text = "OK: appended \(result.appendedSize) bytes -> \(resolvedPath)"
            return BridgeInvokeResponse(id: request.id, ok: true, payload: text)

        case "fs.list":
            struct Params: Codable {
                let path: String
            }
            let params = try Self.decodeParams(Params.self, from: request.paramsJSON)
            let result = try await fileSystemService.listDirectory(path: params.path)
            let resolvedPath = try await resolvedPathText(params.path)
            let text = conciseListText(for: result, resolvedPath: resolvedPath)
            return BridgeInvokeResponse(id: request.id, ok: true, payload: text)

        case "fs.mkdir":
            struct Params: Codable {
                let path: String
                let recursive: Bool?
                let ifNotExists: Bool?
            }
            let params = try Self.decodeParams(Params.self, from: request.paramsJSON)
            let result = try await fileSystemService.makeDirectory(
                path: params.path,
                recursive: params.recursive ?? true,
                ifNotExists: params.ifNotExists ?? true
            )
            let resolvedPath = try await resolvedPathText(params.path)
            let verb = result.created ? "created" : "already exists"
            let text = "OK: \(verb) directory -> \(resolvedPath)"
            return BridgeInvokeResponse(id: request.id, ok: true, payload: text)

        case "fs.delete":
            struct Params: Codable {
                let path: String
            }
            let params = try Self.decodeParams(Params.self, from: request.paramsJSON)
            let result = try await fileSystemService.delete(path: params.path)
            let resolvedPath = try await resolvedPathText(params.path)
            let text = "OK: deleted -> \(resolvedPath)"
            return BridgeInvokeResponse(id: request.id, ok: true, payload: text)

        case "fs.find":
            struct Params: Codable {
                let glob: String
                let path: String?
                let recursive: Bool?
            }
            let params = try Self.decodeParams(Params.self, from: request.paramsJSON)
            let result = try await fileSystemService.findFiles(
                glob: params.glob,
                path: params.path ?? ".",
                recursive: params.recursive ?? true
            )
            let itemLines = result.items.map { item in
                "[FILE] \(item.path) (\(item.size ?? 0) bytes)"
            }
            let text = itemLines.isEmpty ? "No files matching '\(result.pattern)'" : itemLines.joined(separator: "\n")
            return BridgeInvokeResponse(id: request.id, ok: true, payload: text)

        case "fs.grep":
            struct Params: Codable {
                let pattern: String
                let path: String?
                let recursive: Bool?
                let isRegex: Bool?
                let caseInsensitive: Bool?
            }
            let params = try Self.decodeParams(Params.self, from: request.paramsJSON)
            let result = try await fileSystemService.grep(
                pattern: params.pattern,
                path: params.path ?? ".",
                recursive: params.recursive ?? true,
                isRegex: params.isRegex ?? true,
                caseInsensitive: params.caseInsensitive ?? true
            )
            let matchLines = result.matches.map { match in
                "\(match.path):\(match.lineNumber): \(match.line)"
            }
            let text = matchLines.isEmpty ? "No matches for '\(result.pattern)'" : matchLines.joined(separator: "\n")
            return BridgeInvokeResponse(id: request.id, ok: true, payload: text)

        default:
            return BridgeInvokeResponse(
                id: request.id,
                ok: false,
                error: OpenClawNodeError(code: .invalidRequest, message: "INVALID_REQUEST: unknown command")
            )
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

    private func buildCapabilityRouter() -> NodeCapabilityRouter {
        var handlers: [String: NodeCapabilityRouter.Handler] = [:]

        func register(_ commands: [String], handler: @escaping NodeCapabilityRouter.Handler) {
            for command in commands {
                handlers[command] = handler
            }
        }

        register([OpenClawLocationCommand.get.rawValue]) { [weak self] request in
            guard let self else { throw NodeCapabilityRouter.RouterError.handlerUnavailable }
            return try await self.handleLocationInvoke(request)
        }

        register([
            OpenClawCameraCommand.list.rawValue,
            OpenClawCameraCommand.snap.rawValue,
            OpenClawCameraCommand.clip.rawValue,
        ]) { [weak self] request in
            guard let self else { throw NodeCapabilityRouter.RouterError.handlerUnavailable }
            return try await self.handleCameraInvoke(request)
        }

        register([OpenClawScreenCommand.record.rawValue]) { [weak self] request in
            guard let self else { throw NodeCapabilityRouter.RouterError.handlerUnavailable }
            return try await self.handleScreenRecordInvoke(request)
        }

        register([OpenClawSystemCommand.notify.rawValue]) { [weak self] request in
            guard let self else { throw NodeCapabilityRouter.RouterError.handlerUnavailable }
            return try await self.handleSystemNotify(request)
        }

        register([
            OpenClawDeviceCommand.status.rawValue,
            OpenClawDeviceCommand.info.rawValue,
            "current.time",
        ]) { [weak self] request in
            guard let self else { throw NodeCapabilityRouter.RouterError.handlerUnavailable }
            return try await self.handleDeviceInvoke(request)
        }

        if !Self.isMacCatalyst {
            register([
                OpenClawWatchCommand.status.rawValue,
                OpenClawWatchCommand.notify.rawValue,
            ]) { [weak self] request in
                guard let self else { throw NodeCapabilityRouter.RouterError.handlerUnavailable }
                return try await self.handleWatchInvoke(request)
            }
        }

        register([OpenClawPhotosCommand.latest.rawValue]) { [weak self] request in
            guard let self else { throw NodeCapabilityRouter.RouterError.handlerUnavailable }
            return try await self.handlePhotosInvoke(request)
        }

        register([OpenClawImageCommand.removeBackground.rawValue]) { [weak self] request in
            guard let self else { throw NodeCapabilityRouter.RouterError.handlerUnavailable }
            return try await self.handleImageInvoke(request)
        }

        register([
            OpenClawContactsCommand.search.rawValue,
            OpenClawContactsCommand.add.rawValue,
        ]) { [weak self] request in
            guard let self else { throw NodeCapabilityRouter.RouterError.handlerUnavailable }
            return try await self.handleContactsInvoke(request)
        }

        register([
            OpenClawCalendarCommand.events.rawValue,
            OpenClawCalendarCommand.add.rawValue,
        ]) { [weak self] request in
            guard let self else { throw NodeCapabilityRouter.RouterError.handlerUnavailable }
            return try await self.handleCalendarInvoke(request)
        }

        register([
            OpenClawRemindersCommand.list.rawValue,
            OpenClawRemindersCommand.add.rawValue,
        ]) { [weak self] request in
            guard let self else { throw NodeCapabilityRouter.RouterError.handlerUnavailable }
            return try await self.handleRemindersInvoke(request)
        }

        register([CronCommand.cron.rawValue]) { [weak self] request in
            guard let self else { throw NodeCapabilityRouter.RouterError.handlerUnavailable }
            return try await self.handleCronInvoke(request)
        }

        if !Self.isMacCatalyst {
            register([
                OpenClawMotionCommand.activity.rawValue,
                OpenClawMotionCommand.pedometer.rawValue,
            ]) { [weak self] request in
                guard let self else { throw NodeCapabilityRouter.RouterError.handlerUnavailable }
                return try await self.handleMotionInvoke(request)
            }
        }

        register([OpenClawSpeechCommand.transcribe.rawValue]) { [weak self] request in
            guard let self else { throw NodeCapabilityRouter.RouterError.handlerUnavailable }
            return try await self.handleSpeechInvoke(request)
        }

        // Web fetch tool
        register(["web.fetch"]) { [weak self] request in
            guard let self else { throw NodeCapabilityRouter.RouterError.handlerUnavailable }
            return try await self.handleWebFetchInvoke(request)
        }

        // Floating web view tools: navigate, snapshot, interactions, read, close.
        register([
            "web_view", "web_view_snapshot", "web_view_click", "web_view_type",
            "web_view_scroll", "web_view_select", "web_view_navigate", "web_view_close", "web_view_read",
        ]) { [weak self] request in
            guard let self else { throw NodeCapabilityRouter.RouterError.handlerUnavailable }
            return try await self.handleWebViewInvoke(request)
        }

        register(["javascript.execute"]) { [weak self] request in
            guard let self else { throw NodeCapabilityRouter.RouterError.handlerUnavailable }
            return try await self.handleJavaScriptInvoke(request)
        }

        // Text-to-image social card rendering tool.
        register(["text.image.render"]) { [weak self] request in
            guard let self else { throw NodeCapabilityRouter.RouterError.handlerUnavailable }
            return try await self.handleTextImageRenderInvoke(request)
        }

        // Web search tool
        register(["web.search"]) { [weak self] request in
            guard let self else { throw NodeCapabilityRouter.RouterError.handlerUnavailable }
            return try await self.handleWebSearchInvoke(request)
        }

        // Free image search tool
        register(["image.search"]) { [weak self] request in
            guard let self else { throw NodeCapabilityRouter.RouterError.handlerUnavailable }
            return try await self.handleImageSearchInvoke(request)
        }

        // YouTube transcript tool
        register(["youtube.transcript"]) { [weak self] request in
            guard let self else { throw NodeCapabilityRouter.RouterError.handlerUnavailable }
            return try await self.handleYouTubeTranscriptInvoke(request)
        }

        // File system tools
        register(["fs.read", "fs.write", "fs.list", "fs.mkdir", "fs.delete", "fs.replace", "fs.append", "fs.find", "fs.grep"]) { [weak self] request in
            guard let self else { throw NodeCapabilityRouter.RouterError.handlerUnavailable }
            return try await self.handleFileSystemInvoke(request)
        }

        // Skill tool
        register(["skill.invoke"]) { [weak self] request in
            guard let self else { throw NodeCapabilityRouter.RouterError.handlerUnavailable }
            return try await self.handleSkillInvoke(request)
        }

        // Memory tools
        register(["memory.recall", "memory.upsert", "memory.forget", "memory.transcript_search"]) { [weak self] request in
            guard let self else { throw NodeCapabilityRouter.RouterError.handlerUnavailable }
            return try await self.handleMemoryInvoke(request)
        }

        // Weather tool
        register(["weather.get"]) { [weak self] request in
            guard let self else { throw NodeCapabilityRouter.RouterError.handlerUnavailable }
            return try await self.handleWeatherInvoke(request)
        }

        // Yahoo Finance tool
        register(["finance.yahoo"]) { [weak self] request in
            guard let self else { throw NodeCapabilityRouter.RouterError.handlerUnavailable }
            return try await self.handleYahooFinanceInvoke(request)
        }

        // China A-share market tool
        register(["finance.a_share"]) { [weak self] request in
            guard let self else { throw NodeCapabilityRouter.RouterError.handlerUnavailable }
            return try await self.handleAShareMarketInvoke(request)
        }

        // Sub agent tools
        register(["subagent.run", "subagent.status", "subagent.cancel"]) { [weak self] request in
            guard let self else { throw NodeCapabilityRouter.RouterError.handlerUnavailable }
            return try await self.handleSubAgentInvoke(request)
        }

        // Team / swarm tools
        register([
            "team.status", "team.message.send", "team.plan.approve",
            "team.task.create", "team.task.list", "team.task.get", "team.task.update",
        ]) { [weak self] request in
            guard let self else { throw NodeCapabilityRouter.RouterError.handlerUnavailable }
            return try await self.handleTeamInvoke(request)
        }

        return NodeCapabilityRouter(handlers: handlers)
    }

    private func currentTeamToolContext() -> TeamSwarmCoordinator.ToolContext {
        TeamSwarmCoordinator.ToolContext(
            sessionID: InvocationContext.sessionID,
            senderMemberID: InvocationContext.teamContext?.memberID
        )
    }

    private func handleSubAgentInvoke(_ request: BridgeInvokeRequest) async throws -> BridgeInvokeResponse {
        struct RunParams: Decodable {
            let description: String
            let prompt: String
            let subagentType: String?
            let runInBackground: Bool?

            enum CodingKeys: String, CodingKey {
                case description
                case prompt
                case subagentType = "subagent_type"
                case runInBackground = "run_in_background"
            }
        }

        struct TaskParams: Decodable {
            let taskID: String

            enum CodingKeys: String, CodingKey {
                case taskID = "task_id"
            }
        }

        switch request.command {
        case "subagent.run":
            let params = try Self.decodeParams(RunParams.self, from: request.paramsJSON)
            guard let prompt = AppConfig.nonEmpty(params.prompt),
                  let description = AppConfig.nonEmpty(params.description)
            else {
                return BridgeInvokeResponse(
                    id: request.id,
                    ok: false,
                    error: OpenClawNodeError(code: .invalidRequest, message: "INVALID_REQUEST: description and prompt are required")
                )
            }
            guard let modelConfig else {
                return BridgeInvokeResponse(
                    id: request.id,
                    ok: false,
                    error: OpenClawNodeError(code: .unavailable, message: "UNAVAILABLE: no configured model for sub agent execution")
                )
            }
            let definition = SubAgentRegistry.definition(for: params.subagentType) ?? SubAgentRegistry.generalPurpose
            let sessionID = InvocationContext.sessionID

            if params.runInBackground == true {
                let record = await SubAgentTaskStore.shared.create(
                    agentType: definition.agentType,
                    description: description,
                    prompt: prompt,
                    parentSessionID: sessionID
                )
                let task = Task { @MainActor [weak self] in
                    guard let self else { return }
                    do {
                        let output = try await SubAgentRunner.run(
                            prompt: prompt,
                            definition: definition,
                            workspaceRootURL: workspaceRootURL,
                            modelConfig: modelConfig,
                            executeTool: { [weak self] nestedRequest in
                                guard let self else {
                                    return BridgeInvokeResponse(
                                        id: nestedRequest.id,
                                        ok: false,
                                        error: OpenClawNodeError(code: .unavailable, message: "UNAVAILABLE: local tool handler unavailable")
                                    )
                                }
                                return await self.handle(nestedRequest, sessionID: sessionID)
                            }
                        )
                        await SubAgentTaskStore.shared.markCompleted(taskID: record.id, result: output.content)
                    } catch {
                        await SubAgentTaskStore.shared.markFailed(taskID: record.id, errorDescription: error.localizedDescription)
                    }
                }
                await SubAgentTaskStore.shared.attach(task: task, for: record.id)
                let payload = [
                    "## Sub Agent Task",
                    "- task_id: \(record.id)",
                    "- agent: \(record.agentType)",
                    "- description: \(record.description)",
                    "- status: \(record.status.rawValue)",
                ].joined(separator: "\n")
                return BridgeInvokeResponse(id: request.id, ok: true, payload: payload)
            }

            let output = try await SubAgentRunner.run(
                prompt: prompt,
                definition: definition,
                workspaceRootURL: workspaceRootURL,
                modelConfig: modelConfig,
                executeTool: { [weak self] nestedRequest in
                    guard let self else {
                        return BridgeInvokeResponse(
                            id: nestedRequest.id,
                            ok: false,
                            error: OpenClawNodeError(code: .unavailable, message: "UNAVAILABLE: local tool handler unavailable")
                        )
                    }
                    return await self.handle(nestedRequest, sessionID: sessionID)
                }
            )
            let payload = [
                "## Sub Agent Result",
                "- agent: \(output.agentType)",
                "- turns: \(output.totalTurns)",
                "- tool_calls: \(output.totalToolCalls)",
                "- duration_ms: \(output.durationMs)",
                "",
                output.content,
            ].joined(separator: "\n")
            return BridgeInvokeResponse(id: request.id, ok: true, payload: payload)

        case "subagent.status":
            let params = try Self.decodeParams(TaskParams.self, from: request.paramsJSON)
            guard let record = await SubAgentTaskStore.shared.record(taskID: params.taskID) else {
                return BridgeInvokeResponse(
                    id: request.id,
                    ok: false,
                    error: OpenClawNodeError(code: .invalidRequest, message: "NOT_FOUND: sub agent task not found")
                )
            }
            let payload = [
                "## Sub Agent Status",
                "- task_id: \(record.id)",
                "- agent: \(record.agentType)",
                "- status: \(record.status.rawValue)",
                "- updated_at: \(ISO8601DateFormatter().string(from: record.updatedAt))",
                record.result.map { "\n\($0)" } ?? record.errorDescription.map { "\nError: \($0)" } ?? "",
            ].joined(separator: "\n")
            return BridgeInvokeResponse(id: request.id, ok: true, payload: payload)

        case "subagent.cancel":
            let params = try Self.decodeParams(TaskParams.self, from: request.paramsJSON)
            let cancelled = await SubAgentTaskStore.shared.cancel(taskID: params.taskID)
            let payload = cancelled
                ? "Sub agent task \(params.taskID) cancelled."
                : "Sub agent task \(params.taskID) is not running."
            return BridgeInvokeResponse(id: request.id, ok: true, payload: payload)

        default:
            return BridgeInvokeResponse(
                id: request.id,
                ok: false,
                error: OpenClawNodeError(code: .invalidRequest, message: "INVALID_REQUEST: unknown sub agent command")
            )
        }
    }

    private func handleTeamInvoke(_ request: BridgeInvokeRequest) async throws -> BridgeInvokeResponse {
        struct TeamNameParams: Decodable {
            let teamName: String?

            enum CodingKeys: String, CodingKey {
                case teamName = "team_name"
            }
        }

        struct MessageParams: Decodable {
            let to: String
            let message: String
            let teamName: String?
            let messageType: String?

            enum CodingKeys: String, CodingKey {
                case to
                case message
                case teamName = "team_name"
                case messageType = "message_type"
            }
        }

        struct ApproveParams: Decodable {
            let sessionID: String?
            let name: String?
            let teamName: String?
            let feedback: String?

            enum CodingKeys: String, CodingKey {
                case sessionID = "session_id"
                case name
                case teamName = "team_name"
                case feedback
            }
        }

        struct TaskCreateParams: Decodable {
            let title: String
            let detail: String?
            let teamName: String?

            enum CodingKeys: String, CodingKey {
                case title
                case detail
                case teamName = "team_name"
            }
        }

        struct TaskGetParams: Decodable {
            let taskID: Int
            let teamName: String?

            enum CodingKeys: String, CodingKey {
                case taskID = "task_id"
                case teamName = "team_name"
            }
        }

        struct TaskUpdateParams: Decodable {
            let taskID: Int
            let title: String?
            let detail: String?
            let owner: String?
            let status: String?
            let teamName: String?

            enum CodingKeys: String, CodingKey {
                case taskID = "task_id"
                case title
                case detail
                case owner
                case status
                case teamName = "team_name"
            }
        }

        let context = currentTeamToolContext()

        switch request.command {
        case "team.status":
            let params = try Self.decodeParams(TeamNameParams.self, from: request.paramsJSON)
            guard let snapshot = TeamSwarmCoordinator.shared.snapshot(teamName: params.teamName, context: context) else {
                return BridgeInvokeResponse(
                    id: request.id,
                    ok: false,
                    error: OpenClawNodeError(code: .invalidRequest, message: "TEAM_NOT_FOUND")
                )
            }
            let payload = renderTeamStatus(snapshot)
            return BridgeInvokeResponse(id: request.id, ok: true, payload: payload)

        case "team.message.send":
            let params = try Self.decodeParams(MessageParams.self, from: request.paramsJSON)
            try TeamSwarmCoordinator.shared.sendMessage(
                to: params.to,
                message: params.message,
                messageType: AppConfig.nonEmpty(params.messageType) ?? "message",
                teamName: params.teamName,
                context: context
            )
            return BridgeInvokeResponse(id: request.id, ok: true, payload: "Message sent to \(params.to).")

        case "team.plan.approve":
            let params = try Self.decodeParams(ApproveParams.self, from: request.paramsJSON)
            let member = try TeamSwarmCoordinator.shared.approvePlan(
                sessionID: params.sessionID,
                memberName: params.name,
                teamName: params.teamName,
                feedback: params.feedback,
                context: context
            )
            return BridgeInvokeResponse(id: request.id, ok: true, payload: "Approved plan for \(member.name).")

        case "team.task.create":
            let params = try Self.decodeParams(TaskCreateParams.self, from: request.paramsJSON)
            let task = try TeamSwarmCoordinator.shared.createTask(title: params.title, detail: params.detail, teamName: params.teamName, context: context)
            return BridgeInvokeResponse(id: request.id, ok: true, payload: renderTask(task, heading: "Task Created"))

        case "team.task.list":
            let params = try Self.decodeParams(TeamNameParams.self, from: request.paramsJSON)
            let tasks = try TeamSwarmCoordinator.shared.listTasks(teamName: params.teamName, context: context)
            let lines = tasks.map { renderTaskLine($0) }
            let payload = (["## Team Tasks"] + (lines.isEmpty ? ["No tasks."] : lines)).joined(separator: "\n")
            return BridgeInvokeResponse(id: request.id, ok: true, payload: payload)

        case "team.task.get":
            let params = try Self.decodeParams(TaskGetParams.self, from: request.paramsJSON)
            let task = try TeamSwarmCoordinator.shared.getTask(id: params.taskID, teamName: params.teamName, context: context)
            return BridgeInvokeResponse(id: request.id, ok: true, payload: renderTask(task, heading: "Task"))

        case "team.task.update":
            let params = try Self.decodeParams(TaskUpdateParams.self, from: request.paramsJSON)
            let status = params.status.flatMap { TeamSwarmCoordinator.TaskStatus(rawValue: $0) }
            let task = try TeamSwarmCoordinator.shared.updateTask(
                id: params.taskID,
                teamName: params.teamName,
                title: params.title,
                detail: params.detail,
                status: status,
                owner: params.owner,
                context: context
            )
            return BridgeInvokeResponse(id: request.id, ok: true, payload: renderTask(task, heading: "Task Updated"))

        default:
            return BridgeInvokeResponse(
                id: request.id,
                ok: false,
                error: OpenClawNodeError(code: .invalidRequest, message: "INVALID_REQUEST: unknown team command")
            )
        }
    }

    private func renderTeamStatus(_ snapshot: TeamSwarmCoordinator.TeamSnapshot) -> String {
        let team = snapshot.team
        let pendingPermissions = snapshot.pendingPermissions
        var lines = [
            "## Team Status",
            "- team_name: \(team.name)",
            team.description.map { "- description: \($0)" },
            team.leadAgentID.map { "- lead_agent_id: \($0)" },
            "- lead_session_id: \(team.leadSessionID)",
            "- created_at: \(iso8601(team.createdAt))",
            "- updated_at: \(iso8601(team.updatedAt))",
            "- pending_permission_requests: \(pendingPermissions.count)",
            "- lead_mailbox_unread: \(snapshot.leadUnreadCount)",
            snapshot.leadMailboxPreview.map { "- lead_mailbox_preview: \($0)" },
            "",
            "### Members",
        ].compactMap { $0 }
        if team.members.isEmpty {
            lines.append("- none")
        } else {
            lines.append(contentsOf: team.members.map { member in
                let backend = member.backendType?.rawValue ?? "in-process"
                let queued = member.queuedMessageCount ?? 0
                let planMode = member.planModeRequired ? "required" : "off"
                let preview = member.lastMailboxPreview ?? "none"
                let error = member.lastError ?? "none"
                return "- \(member.name) | status=\(member.status.rawValue) | agent_type=\(member.agentType) | backend=\(backend) | plan_mode=\(planMode) | queued=\(queued) | session_id=\(member.sessionID) | inbox=\(preview) | error=\(error)"
            })
        }

        if let allowedPaths = team.allowedPaths, !allowedPaths.isEmpty {
            lines.append("")
            lines.append("### Shared Allowed Paths")
            lines.append(contentsOf: allowedPaths.map { rule in
                "- \(rule.path) | tool=\(rule.toolName) | added_by=\(rule.addedBy) | added_at=\(iso8601(rule.addedAt))"
            })
        }

        if !pendingPermissions.isEmpty {
            lines.append("")
            lines.append("### Pending Permissions")
            lines.append(contentsOf: pendingPermissions.map { request in
                "- \(request.workerName) | kind=\(request.kind) | tool=\(request.toolName) | status=\(request.status.rawValue) | created_at=\(iso8601(request.createdAt)) | \(request.description)"
            })
        }
        lines.append("")
        lines.append("### Tasks")
        if team.tasks.isEmpty {
            lines.append("- none")
        } else {
            lines.append(contentsOf: team.tasks.sorted { $0.id < $1.id }.map { task in
                var line = renderTaskLine(task)
                if let detail = task.detail, !detail.isEmpty {
                    line += " | detail=\(detail)"
                }
                return line
            })
        }
        return lines.joined(separator: "\n")
    }

    private func renderTask(_ task: TeamSwarmCoordinator.TeamTask, heading: String) -> String {
        [
            "## \(heading)",
            "- id: \(task.id)",
            "- title: \(task.title)",
            task.detail.map { "- detail: \($0)" },
            "- status: \(task.status.rawValue)",
            "- owner: \(task.owner ?? "unassigned")",
        ].compactMap { $0 }.joined(separator: "\n")
    }

    private func renderTaskLine(_ task: TeamSwarmCoordinator.TeamTask) -> String {
        "- [#\(task.id)] \(task.status.rawValue) | owner=\(task.owner ?? "unassigned") | \(task.title)"
    }

    private func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private func handleSkillInvoke(_ request: BridgeInvokeRequest) async throws -> BridgeInvokeResponse {
        struct InvokeParams: Decodable {
            let name: String?
            let task: String?
        }

        switch request.command {
        case "skill.invoke":
            let params = try Self.decodeParams(InvokeParams.self, from: request.paramsJSON)
            guard let name = AppConfig.nonEmpty(params.name) else {
                return BridgeInvokeResponse(
                    id: request.id,
                    ok: false,
                    error: OpenClawNodeError(code: .invalidRequest, message: "INVALID_REQUEST: name is required")
                )
            }

            guard let skill = AgentSkillsLoader.resolveSkill(
                named: name,
                visibility: .all,
                workspaceRootURL: workspaceRootURL
            ) else {
                return BridgeInvokeResponse(
                    id: request.id,
                    ok: false,
                    error: OpenClawNodeError(code: .invalidRequest, message: "NOT_FOUND: skill '\(name)' not found")
                )
            }

            guard let body = AgentSkillsLoader.skillBody(for: skill), !body.isEmpty else {
                return BridgeInvokeResponse(
                    id: request.id,
                    ok: false,
                    error: OpenClawNodeError(code: .unavailable, message: "UNAVAILABLE: skill '\(skill.name)' has empty content")
                )
            }

            let task = AppConfig.nonEmpty(params.task)

            switch skill.executionContext {
            case .inline:
                return BridgeInvokeResponse(
                    id: request.id,
                    ok: true,
                    payload: inlineSkillPayload(skill: skill, task: task, body: body)
                )

            case .fork:
                guard let task else {
                    return BridgeInvokeResponse(
                        id: request.id,
                        ok: false,
                        error: OpenClawNodeError(code: .invalidRequest, message: "INVALID_REQUEST: task is required for fork-context skills")
                    )
                }
                guard let modelConfig else {
                    return BridgeInvokeResponse(
                        id: request.id,
                        ok: false,
                        error: OpenClawNodeError(code: .unavailable, message: "UNAVAILABLE: no configured model for fork-context skill execution")
                    )
                }
                guard let definition = forkedSkillDefinition(for: skill) else {
                    return BridgeInvokeResponse(
                        id: request.id,
                        ok: false,
                        error: OpenClawNodeError(code: .invalidRequest, message: "INVALID_REQUEST: unsupported agent '\(skill.agent ?? "")' for skill '\(skill.name)'")
                    )
                }

                let sessionID = InvocationContext.sessionID
                let output = try await SubAgentRunner.run(
                    prompt: forkedSkillPrompt(skill: skill, task: task, body: body),
                    definition: definition,
                    workspaceRootURL: workspaceRootURL,
                    modelConfig: modelConfig,
                    executeTool: { [weak self] nestedRequest in
                        guard let self else {
                            return BridgeInvokeResponse(
                                id: nestedRequest.id,
                                ok: false,
                                error: OpenClawNodeError(code: .unavailable, message: "UNAVAILABLE: local tool handler unavailable")
                            )
                        }
                        return await self.handle(nestedRequest, sessionID: sessionID)
                    }
                )

                let payload = [
                    "## Skill Fork Result",
                    "- skill: \(skill.displayName) (`\(skill.name)`)",
                    "- agent: \(output.agentType)",
                    "- turns: \(output.totalTurns)",
                    "- tool_calls: \(output.totalToolCalls)",
                    "- duration_ms: \(output.durationMs)",
                    "",
                    output.content,
                ].joined(separator: "\n")
                return BridgeInvokeResponse(id: request.id, ok: true, payload: payload)
            }

        default:
            return BridgeInvokeResponse(
                id: request.id,
                ok: false,
                error: OpenClawNodeError(code: .invalidRequest, message: "INVALID_REQUEST: unknown skill command")
            )
        }
    }

    private func inlineSkillPayload(skill: AgentSkillsLoader.SkillDefinition, task: String?, body: String) -> String {
        var lines = [
            "## Skill Invocation",
            "- skill: \(skill.displayName) (`\(skill.name)`)",
            "- execution_context: \(skill.executionContext.rawValue)",
        ]

        if let whenToUse = skill.whenToUse {
            lines.append("- when_to_use: \(whenToUse)")
        }
        if !skill.allowedTools.isEmpty {
            lines.append("- allowed_tools: \(skill.allowedTools.joined(separator: ", "))")
        }
        if let effort = skill.effort {
            lines.append("- effort: \(effort)")
        }

        lines.append("")
        if let task {
            lines.append("## Requested Task")
            lines.append(task)
            lines.append("")
        }
        lines.append("## Skill Instructions")
        lines.append(body)
        return lines.joined(separator: "\n")
    }

    private func forkedSkillDefinition(for skill: AgentSkillsLoader.SkillDefinition) -> SubAgentDefinition? {
        let baseDefinition: SubAgentDefinition
        if let agent = AppConfig.nonEmpty(skill.agent) {
            guard let resolved = SubAgentRegistry.definition(for: agent) else {
                return nil
            }
            baseDefinition = resolved
        } else {
            baseDefinition = SubAgentRegistry.generalPurpose
        }

        let toolPolicy: SubAgentDefinition.ToolPolicy
        if !skill.allowedTools.isEmpty {
            toolPolicy = .custom(Set(skill.allowedTools))
        } else {
            toolPolicy = baseDefinition.toolPolicy
        }

        var systemPromptParts = [baseDefinition.systemPrompt]
        systemPromptParts.append("You are executing the OpenAva skill '\(skill.displayName)' (id=\(skill.name)). Follow the skill instructions and return only the final result to the parent agent.")
        if let whenToUse = skill.whenToUse {
            systemPromptParts.append("When-to-use guidance: \(whenToUse)")
        }
        if let effort = skill.effort {
            systemPromptParts.append("Requested execution effort: \(effort). Use deeper reasoning when the task complexity justifies it.")
        }

        return SubAgentDefinition(
            agentType: baseDefinition.agentType,
            description: baseDefinition.description,
            systemPrompt: systemPromptParts.joined(separator: "\n\n"),
            toolPolicy: toolPolicy,
            disallowedFunctionNames: baseDefinition.disallowedFunctionNames.union(["skill_invoke"]),
            maxTurns: baseDefinition.maxTurns,
            supportsBackground: baseDefinition.supportsBackground
        )
    }

    private func forkedSkillPrompt(skill: AgentSkillsLoader.SkillDefinition, task: String, body: String) -> String {
        var lines = [
            "## Requested Task",
            task,
            "",
            "## Skill Metadata",
            "- skill: \(skill.displayName) (`\(skill.name)`)",
            "- execution_context: \(skill.executionContext.rawValue)",
        ]

        if let whenToUse = skill.whenToUse {
            lines.append("- when_to_use: \(whenToUse)")
        }
        if !skill.allowedTools.isEmpty {
            lines.append("- allowed_tools: \(skill.allowedTools.joined(separator: ", "))")
        }
        if let effort = skill.effort {
            lines.append("- effort: \(effort)")
        }

        lines.append("")
        lines.append("## Skill Instructions")
        lines.append(body)
        return lines.joined(separator: "\n")
    }

    private func handleMemoryInvoke(_ request: BridgeInvokeRequest) async throws -> BridgeInvokeResponse {
        switch request.command {
        case "memory.recall":
            return try await handleMemoryRecallInvoke(request)
        case "memory.upsert":
            return try await handleMemoryUpsertInvoke(request)
        case "memory.forget":
            return try await handleMemoryForgetInvoke(request)
        case "memory.transcript_search":
            return try await handleMemoryTranscriptSearchInvoke(request)
        default:
            return BridgeInvokeResponse(
                id: request.id,
                ok: false,
                error: OpenClawNodeError(code: .invalidRequest, message: "INVALID_REQUEST: unknown memory command")
            )
        }
    }

    private func handleMemoryRecallInvoke(_ request: BridgeInvokeRequest) async throws -> BridgeInvokeResponse {
        struct Params: Decodable {
            var query: String
            var limit: Int?
        }

        let params = try Self.decodeParams(Params.self, from: request.paramsJSON)
        guard let runtimeRootURL = activeAgentRuntimeRootURL() else {
            return BridgeInvokeResponse(
                id: request.id,
                ok: false,
                error: OpenClawNodeError(code: .unavailable, message: "UNAVAILABLE: no active agent runtime")
            )
        }

        let store = AgentMemoryStore(runtimeRootURL: runtimeRootURL)
        let hits = try await store.recall(query: params.query, limit: min(max(params.limit ?? 5, 1), 20))
        let lines = hits.map { hit in
            """
            - [\(hit.entry.type.rawValue)] \(hit.entry.name) (slug=\(hit.entry.slug), score=\(hit.score))
              - description: \(hit.entry.description)
              - file: \(hit.entry.fileURL.path)
              - content: \(hit.entry.content.replacingOccurrences(of: "\n", with: " "))
            """
        }
        let text = lines.isEmpty
            ? "## Memory Recall\n- query: \(params.query)\n- summary: no matching durable memories"
            : "## Memory Recall\n- query: \(params.query)\n- summary: found \(hits.count) durable memory hit(s)\n\(lines.joined(separator: "\n"))"
        return BridgeInvokeResponse(id: request.id, ok: true, payload: text)
    }

    private func handleMemoryUpsertInvoke(_ request: BridgeInvokeRequest) async throws -> BridgeInvokeResponse {
        struct Params: Decodable {
            var name: String
            var type: String
            var description: String
            var content: String
            var slug: String?
        }

        let params = try Self.decodeParams(Params.self, from: request.paramsJSON)
        guard let runtimeRootURL = activeAgentRuntimeRootURL() else {
            return BridgeInvokeResponse(
                id: request.id,
                ok: false,
                error: OpenClawNodeError(code: .unavailable, message: "UNAVAILABLE: no active agent runtime")
            )
        }
        guard let type = AgentMemoryStore.MemoryType(rawValue: params.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) else {
            return BridgeInvokeResponse(
                id: request.id,
                ok: false,
                error: OpenClawNodeError(code: .invalidRequest, message: "INVALID_REQUEST: type must be user, feedback, project, or reference")
            )
        }

        let store = AgentMemoryStore(runtimeRootURL: runtimeRootURL)
        let entry = try await store.upsert(
            name: params.name,
            type: type,
            description: params.description,
            content: params.content,
            slug: params.slug
        )
        let text = "## Memory Upsert\n- status: updated\n- type: \(entry.type.rawValue)\n- slug: \(entry.slug)\n- file: \(entry.fileURL.path)"
        return BridgeInvokeResponse(id: request.id, ok: true, payload: text)
    }

    private func handleMemoryForgetInvoke(_ request: BridgeInvokeRequest) async throws -> BridgeInvokeResponse {
        struct Params: Decodable {
            var slug: String
        }

        let params = try Self.decodeParams(Params.self, from: request.paramsJSON)
        guard let runtimeRootURL = activeAgentRuntimeRootURL() else {
            return BridgeInvokeResponse(
                id: request.id,
                ok: false,
                error: OpenClawNodeError(code: .unavailable, message: "UNAVAILABLE: no active agent runtime")
            )
        }

        let store = AgentMemoryStore(runtimeRootURL: runtimeRootURL)
        let removed = try await store.forget(slug: params.slug)
        let text = removed
            ? "## Memory Forget\n- status: removed\n- slug: \(params.slug)"
            : "## Memory Forget\n- status: not_found\n- slug: \(params.slug)"
        return BridgeInvokeResponse(id: request.id, ok: true, payload: text)
    }

    private func handleMemoryTranscriptSearchInvoke(_ request: BridgeInvokeRequest) async throws -> BridgeInvokeResponse {
        struct Params: Decodable {
            var query: String
            var sessionID: String?
            var caseInsensitive: Bool?
            var limit: Int?
        }

        let params = try Self.decodeParams(Params.self, from: request.paramsJSON)
        guard let runtimeRootURL = activeAgentRuntimeRootURL() else {
            return BridgeInvokeResponse(
                id: request.id,
                ok: false,
                error: OpenClawNodeError(code: .unavailable, message: "UNAVAILABLE: no active agent runtime")
            )
        }

        let service = AgentTranscriptSearchService(runtimeRootURL: runtimeRootURL)
        let hits = try service.search(
            query: params.query,
            sessionID: params.sessionID,
            limit: min(max(params.limit ?? 20, 1), 100),
            caseInsensitive: params.caseInsensitive ?? true
        )
        let lines = hits.map { hit in
            "- session=\(hit.sessionID) type=\(hit.entryType) line=\(hit.lineNumber) file=\(hit.fileURL.path)\n  \(hit.snippet)"
        }
        let body = lines.isEmpty ? "- (empty)" : lines.joined(separator: "\n")
        let text = "## Memory Transcript Search\n- query: \(params.query)\n- hits: \(hits.count)\n\(body)"
        return BridgeInvokeResponse(id: request.id, ok: true, payload: text)
    }

    private func activeAgentWorkspaceURL() -> URL? {
        AgentStore.load().activeAgent?.workspaceURL
    }

    private func activeAgentRuntimeRootURL() -> URL? {
        AgentStore.load().activeAgent?.runtimeURL ?? runtimeRootURL?.standardizedFileURL
    }

    private func handleWeatherInvoke(_ request: BridgeInvokeRequest) async throws -> BridgeInvokeResponse {
        struct WeatherParams: Decodable {
            var location: String?
            var latitude: Double?
            var longitude: Double?
            var forecastDays: Int?
            var temperatureUnit: String?
        }

        let params = (try? Self.decodeParams(WeatherParams.self, from: request.paramsJSON)) ?? WeatherParams()
        let result = try await weatherService.fetchWeather(
            location: params.location,
            latitude: params.latitude,
            longitude: params.longitude,
            forecastDays: params.forecastDays ?? 1,
            temperatureUnit: params.temperatureUnit ?? "celsius"
        )
        let current = result.current
        let forecastLines = (result.forecast ?? []).map { day in
            "- \(day.date): \(day.condition), \(day.temperatureMin)~\(day.temperatureMax)\(current.temperatureUnit), precip=\(day.precipitationSum)mm"
        }
        let forecastText = forecastLines.isEmpty ? "- (none)" : forecastLines.joined(separator: "\n")
        let text = """
        ## Weather
        - location: \(result.location) (\(result.latitude), \(result.longitude))
        - timezone: \(result.timezone)
        - now: \(current.condition), \(current.temperature)\(current.temperatureUnit), feels \(current.apparentTemperature)\(current.temperatureUnit)
        - humidity: \(current.humidity)%
        - wind: \(current.windSpeed) \(current.windSpeedUnit), direction \(current.windDirection)°

        ### Forecast
        \(forecastText)
        """
        return BridgeInvokeResponse(id: request.id, ok: true, payload: text)
    }

    private func handleYahooFinanceInvoke(_ request: BridgeInvokeRequest) async throws -> BridgeInvokeResponse {
        struct YahooFinanceParams: Decodable {
            var action: String
            var symbols: [String]?
            var symbol: String?
            var range: String?
            var interval: String?
            var includePrePost: Bool?
            var modules: [String]?
            var query: String?
            var quotesCount: Int?
            var newsCount: Int?
        }

        let params = try Self.decodeParams(YahooFinanceParams.self, from: request.paramsJSON)
        let action = params.action.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        switch action {
        case "quote":
            let result = try await yahooFinanceService.fetchQuotes(symbols: params.symbols ?? [])
            let lines = result.quotes.map { quote in
                let price = quote.regularMarketPrice.map { "\($0)" } ?? ""
                let change = quote.regularMarketChangePercent.map { String(format: "%.2f%%", $0) } ?? ""
                return "- \(quote.symbol): \(price) \(quote.currency ?? "") (\(change))"
            }
            let text = "## Yahoo Finance Quotes\n- symbols: \(result.symbols.joined(separator: ", "))\n- count: \(result.count)\n\(lines.isEmpty ? "- (empty)" : lines.joined(separator: "\n"))"
            return BridgeInvokeResponse(id: request.id, ok: true, payload: text)
        case "chart":
            guard let symbol = params.symbol else {
                return BridgeInvokeResponse(
                    id: request.id,
                    ok: false,
                    error: OpenClawNodeError(code: .invalidRequest, message: "INVALID_REQUEST: symbol is required for chart action")
                )
            }
            let result = try await yahooFinanceService.fetchChart(
                symbol: symbol,
                range: params.range ?? "1mo",
                interval: params.interval ?? "1d",
                includePrePost: params.includePrePost ?? false
            )
            let samples = Array(result.points.prefix(10)).map { point in
                "- ts=\(point.timestamp) o=\(point.open.map { "\($0)" } ?? "") h=\(point.high.map { "\($0)" } ?? "") l=\(point.low.map { "\($0)" } ?? "") c=\(point.close.map { "\($0)" } ?? "") v=\(point.volume.map { "\($0)" } ?? "")"
            }
            let text = "## Yahoo Finance Chart\n- symbol: \(result.symbol)\n- range: \(result.range)\n- interval: \(result.interval)\n- points: \(result.points.count)\n\(samples.joined(separator: "\n"))"
            return BridgeInvokeResponse(id: request.id, ok: true, payload: text)
        case "summary":
            guard let symbol = params.symbol else {
                return BridgeInvokeResponse(
                    id: request.id,
                    ok: false,
                    error: OpenClawNodeError(code: .invalidRequest, message: "INVALID_REQUEST: symbol is required for summary action")
                )
            }
            let result = try await yahooFinanceService.fetchSummary(symbol: symbol, modules: params.modules ?? [])
            let text = "## Yahoo Finance Summary\n- symbol: \(result.symbol)\n- modules: \(result.modules.joined(separator: ", "))\n- note: raw summary object is omitted to keep context concise; call specific modules if needed."
            return BridgeInvokeResponse(id: request.id, ok: true, payload: text)
        case "search":
            guard let query = params.query else {
                return BridgeInvokeResponse(
                    id: request.id,
                    ok: false,
                    error: OpenClawNodeError(code: .invalidRequest, message: "INVALID_REQUEST: query is required for search action")
                )
            }
            let result = try await yahooFinanceService.search(
                query: query,
                quotesCount: params.quotesCount ?? 8,
                newsCount: params.newsCount ?? 6
            )
            let quoteLines = result.quotes.map { quote in
                "- \(quote.symbol ?? "") | \(quote.shortname ?? quote.longname ?? "") | \(quote.exchDisp ?? "")"
            }
            let newsLines = result.news.map { news in
                "- \(news.title ?? "") (\(news.publisher ?? "")) \(news.link ?? "")"
            }
            let text = "## Yahoo Finance Search\n- query: \(result.query)\n\n### Quotes\n\(quoteLines.isEmpty ? "- (empty)" : quoteLines.joined(separator: "\n"))\n\n### News\n\(newsLines.isEmpty ? "- (empty)" : newsLines.joined(separator: "\n"))"
            return BridgeInvokeResponse(id: request.id, ok: true, payload: text)
        default:
            return BridgeInvokeResponse(
                id: request.id,
                ok: false,
                error: OpenClawNodeError(code: .invalidRequest, message: "INVALID_REQUEST: action must be one of quote, chart, summary, search")
            )
        }
    }

    private func handleAShareMarketInvoke(_ request: BridgeInvokeRequest) async throws -> BridgeInvokeResponse {
        struct AShareMarketParams: Decodable {
            var codes: [String]
            var minute: Bool?
            var json: Bool?
        }

        let params = try Self.decodeParams(AShareMarketParams.self, from: request.paramsJSON)
        let normalizedCodes = params.codes
            .map(AShareMarketService.cleanCode(_:))
            .filter { !$0.isEmpty }
        guard !normalizedCodes.isEmpty else {
            return BridgeInvokeResponse(
                id: request.id,
                ok: false,
                error: OpenClawNodeError(code: .invalidRequest, message: "INVALID_REQUEST: codes must contain at least one stock code")
            )
        }

        let includeMinute = params.minute ?? false
        let results = try await aShareMarketService.analyzeStocks(codes: normalizedCodes, includeMinute: includeMinute)

        if params.json ?? false {
            return try BridgeInvokeResponse(id: request.id, ok: true, payload: Self.encodePayload(results))
        }

        var blocks: [String] = []
        for result in results {
            if let error = result.error {
                blocks.append("错误: \(error)")
                continue
            }
            guard let realtime = result.realtime else {
                blocks.append("错误: 无法获取 \(result.code) 的行情数据")
                continue
            }

            var text = AShareMarketService.formatRealtime(realtime)
            if includeMinute {
                if let analysis = result.minuteAnalysis {
                    text += AShareMarketService.formatMinuteAnalysis(analysis)
                } else if let minuteError = result.minuteError {
                    text += "\n\n【分时量能分析】\n  错误: \(minuteError)"
                }
            }
            blocks.append(text)
        }

        return BridgeInvokeResponse(id: request.id, ok: true, payload: blocks.joined(separator: "\n\n"))
    }

    private struct PersistedMediaFile {
        let path: String
        let sizeBytes: Int
    }

    /// Persist media data under the active workspace so generated artifacts stay discoverable.
    private func persistMediaData(_ data: Data, suggestedExtension: String, prefix: String) throws -> PersistedMediaFile {
        let ext = Self.normalizedFileExtension(suggestedExtension)
        let fileURL = try nextMediaOutputURL(prefix: prefix, suggestedExtension: ext)
        try data.write(to: fileURL, options: .atomic)
        return PersistedMediaFile(path: fileURL.path, sizeBytes: data.count)
    }

    /// Keep tool-generated media in one workspace-scoped directory.
    private func nextMediaOutputURL(prefix: String, suggestedExtension: String) throws -> URL {
        let ext = Self.normalizedFileExtension(suggestedExtension)
        let directoryURL = try mediaOutputDirectoryURL()
        return directoryURL.appendingPathComponent("\(prefix)-\(UUID().uuidString).\(ext)")
    }

    /// Resolve and create the workspace-level directory used by media tools.
    private func mediaOutputDirectoryURL() throws -> URL {
        let baseURL = activeAgentWorkspaceURL() ?? FileManager.default.temporaryDirectory
        let directoryURL = baseURL
            .appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return directoryURL
    }

    /// Keep extension values safe and predictable for generated temporary file paths.
    private static func normalizedFileExtension(_ raw: String) -> String {
        let filtered = raw.lowercased().filter { $0.isLetter || $0.isNumber }
        return filtered.isEmpty ? "bin" : filtered
    }

    /// Map media extensions to standard MIME types for downstream consumers.
    private static func mimeType(for format: String) -> String {
        switch format.lowercased() {
        case "jpg", "jpeg":
            return "image/jpeg"
        case "png":
            return "image/png"
        case "mp4":
            return "video/mp4"
        case "mov":
            return "video/quicktime"
        default:
            return "application/octet-stream"
        }
    }

    /// Build a compact XML-like one-line tag to keep tool payloads simple and readable.
    private static func composeTag(name: String, attributes: [(String, String)]) -> String {
        let attrs = attributes
            .filter { !$0.1.isEmpty }
            .map { key, value in
                "\(key)=\"\(xmlEscaped(value))\""
            }
            .joined(separator: " ")
        return attrs.isEmpty ? "<\(name)/>" : "<\(name) \(attrs)/>"
    }

    /// Build a compact XML-like block for list payloads.
    private static func composeBlock(name: String, attributes: [(String, String)], children: [String]) -> String {
        let start = composeTag(name: name, attributes: attributes)
        guard !children.isEmpty else {
            return start.replacingOccurrences(of: "/>", with: "></\(name)>")
        }
        let open = start.replacingOccurrences(of: "/>", with: ">")
        let body = children.joined(separator: "\n")
        return "\(open)\n\(body)\n</\(name)>"
    }

    /// Escape reserved characters so XML-like output stays machine-readable.
    private static func xmlEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private static func decodeParams<T: Decodable>(_ type: T.Type, from json: String?) throws -> T {
        guard let json, let data = json.data(using: .utf8) else {
            throw NSError(domain: "LocalToolInvokeService", code: 20, userInfo: [
                NSLocalizedDescriptionKey: "INVALID_REQUEST: paramsJSON required",
            ])
        }
        return try JSONDecoder().decode(type, from: data)
    }

    private static func encodePayload(_ obj: some Encodable) throws -> String {
        let data = try JSONEncoder().encode(obj)
        guard let json = String(bytes: data, encoding: .utf8) else {
            throw NSError(domain: "LocalToolInvokeService", code: 21, userInfo: [
                NSLocalizedDescriptionKey: "Failed to encode payload as UTF-8",
            ])
        }
        return json
    }

    /// Wrap OpenClaw payload with a message field for UI display
    private static func encodePayloadWithMessage(_ payload: some Encodable, message: String) throws -> String {
        // Encode payload to JSON
        let payloadData = try JSONEncoder().encode(payload)
        guard var payloadDict = try JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
            throw NSError(domain: "LocalToolInvokeService", code: 22, userInfo: [
                NSLocalizedDescriptionKey: "Failed to convert payload to dictionary",
            ])
        }

        // Add message field
        payloadDict["message"] = message

        // Encode back to JSON string
        let resultData = try JSONSerialization.data(withJSONObject: payloadDict)
        guard let json = String(data: resultData, encoding: .utf8) else {
            throw NSError(domain: "LocalToolInvokeService", code: 23, userInfo: [
                NSLocalizedDescriptionKey: "Failed to encode result as UTF-8",
            ])
        }
        return json
    }

    private static func normalizeWatchNotifyParams(_ params: OpenClawWatchNotifyParams) -> OpenClawWatchNotifyParams {
        var normalized = params
        normalized.title = params.title.trimmingCharacters(in: .whitespacesAndNewlines)
        normalized.body = params.body.trimmingCharacters(in: .whitespacesAndNewlines)
        normalized.promptId = Self.trimmedOrNil(params.promptId)
        normalized.sessionKey = Self.trimmedOrNil(params.sessionKey)
        normalized.kind = Self.trimmedOrNil(params.kind)
        normalized.details = Self.trimmedOrNil(params.details)
        normalized.priority = Self.normalizedWatchPriority(params.priority, risk: params.risk)
        normalized.risk = Self.normalizedWatchRisk(params.risk, priority: normalized.priority)

        let normalizedActions = Self.normalizeWatchActions(
            params.actions,
            kind: normalized.kind,
            promptId: normalized.promptId
        )
        normalized.actions = normalizedActions.isEmpty ? nil : normalizedActions
        return normalized
    }

    private static func normalizeWatchActions(
        _ actions: [OpenClawWatchAction]?,
        kind: String?,
        promptId: String?
    ) -> [OpenClawWatchAction] {
        let provided = (actions ?? []).compactMap { action -> OpenClawWatchAction? in
            let id = action.id.trimmingCharacters(in: .whitespacesAndNewlines)
            let label = action.label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, !label.isEmpty else { return nil }
            return OpenClawWatchAction(
                id: id,
                label: label,
                style: Self.trimmedOrNil(action.style)
            )
        }
        if !provided.isEmpty {
            return Array(provided.prefix(4))
        }

        guard promptId?.isEmpty == false else {
            return []
        }

        let normalizedKind = kind?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if normalizedKind.contains("approval") || normalizedKind.contains("approve") {
            return [
                OpenClawWatchAction(id: "approve", label: "Approve"),
                OpenClawWatchAction(id: "decline", label: "Decline", style: "destructive"),
                OpenClawWatchAction(id: "open_phone", label: "Open iPhone"),
                OpenClawWatchAction(id: "escalate", label: "Escalate"),
            ]
        }

        return [
            OpenClawWatchAction(id: "done", label: "Done"),
            OpenClawWatchAction(id: "snooze_10m", label: "Snooze 10m"),
            OpenClawWatchAction(id: "open_phone", label: "Open iPhone"),
            OpenClawWatchAction(id: "escalate", label: "Escalate"),
        ]
    }

    private static func normalizedWatchRisk(
        _ risk: OpenClawWatchRisk?,
        priority: OpenClawNotificationPriority?
    ) -> OpenClawWatchRisk? {
        if let risk { return risk }
        switch priority {
        case .passive:
            return .low
        case .active:
            return .medium
        case .timeSensitive:
            return .high
        case nil:
            return nil
        }
    }

    private static func normalizedWatchPriority(
        _ priority: OpenClawNotificationPriority?,
        risk: OpenClawWatchRisk?
    ) -> OpenClawNotificationPriority? {
        if let priority { return priority }
        switch risk {
        case .low:
            return .passive
        case .medium:
            return .active
        case .high:
            return .timeSensitive
        case nil:
            return nil
        }
    }

    private static func trimmedOrNil(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}
