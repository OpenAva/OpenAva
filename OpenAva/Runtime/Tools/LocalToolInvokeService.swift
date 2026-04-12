import ChatClient
import CoreLocation
import Foundation
import OpenClawKit
import OpenClawProtocol
import UserNotifications

@MainActor
final class LocalToolInvokeService: @unchecked Sendable {
    enum InvocationContext {
        /// Session identifier propagated from chat layer for tool state isolation.
        @TaskLocal static var sessionID: String?
        @TaskLocal static var teamContext: TeamInvocationContext?
    }

    struct TeamInvocationContext {
        let teamName: String
        let memberID: String
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

    static func makeDefault(workspaceRootURL: URL? = nil, runtimeRootURL: URL? = nil, modelConfig: AppConfig.LLMModel? = nil) -> LocalToolInvokeService {
        let builtInSkillRoots = AgentSkillsLoader.builtInSkillsRoot().map { [$0] } ?? []
        let notificationCenter = LiveNotificationCenter()
        let cameraService = CameraController()
        let screenRecordingService = ScreenRecordService()
        let locationService = LocationService()
        let deviceStatusService = DeviceStatusService()
        let watchMessagingService = WatchMessagingService()
        let photosService = PhotoLibraryService()
        let imageBackgroundRemovalService = ImageBackgroundRemovalService()
        let contactsService = ContactsService()
        let calendarService = CalendarService()
        let remindersService = RemindersService()
        let motionService = MotionService()
        let userNotifyService = UserNotifyService(notificationCenter: notificationCenter)
        let speechService = SpeechService(baseDirectoryURL: workspaceRootURL)
        let cronService = CronService()
        let fileSystemService = FileSystemService(
            baseDirectoryURL: workspaceRootURL,
            additionalReadableRootURLs: builtInSkillRoots
        )

        let service = LocalToolInvokeService(
            cameraService: cameraService,
            screenRecordingService: screenRecordingService,
            locationService: locationService,
            deviceStatusService: deviceStatusService,
            watchMessagingService: watchMessagingService,
            photosService: photosService,
            imageBackgroundRemovalService: imageBackgroundRemovalService,
            contactsService: contactsService,
            calendarService: calendarService,
            remindersService: remindersService,
            motionService: motionService,
            userNotifyService: userNotifyService,
            speechService: speechService,
            cronService: cronService,
            notificationCenter: notificationCenter,
            webFetchService: WebFetchService(),
            webSearchService: WebSearchService(),
            imageSearchService: ImageSearchService(),
            youTubeTranscriptService: YouTubeTranscriptService(),
            webViewToolService: WebViewService.shared,
            javaScriptService: JavaScriptService(),
            textImageRenderService: TextImageRenderService(),
            fileSystemService: fileSystemService,
            modelConfig: modelConfig,
            weatherService: WeatherService(),
            yahooFinanceService: YahooFinanceService(),
            aShareMarketService: AShareMarketService(),
            workspaceRootURL: workspaceRootURL,
            runtimeRootURL: runtimeRootURL
        )

        // Register all tools with the registry once the service is fully initialized.
        Task { @MainActor [weak service] in
            await service?.registerProvidersWithRegistry()
        }

        return service
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

        // Inject closures into self-registering providers
        Task { [weak self] in
            await self?.webFetchService.setPromptProcessor { [weak self] result, prompt in
                guard let self else {
                    return "The fetched content did not produce a response for the requested prompt."
                }
                return try await self.applyPromptToWebFetchResult(result, prompt: prompt)
            }
        }
        javaScriptService.toolInvoker = { [weak self] request in
            guard let self else {
                return BridgeInvokeResponse(
                    id: request.id,
                    ok: false,
                    error: OpenClawNodeError(code: .unavailable, message: "UNAVAILABLE: local tool handler unavailable")
                )
            }
            return await self.handle(request)
        }
        textImageRenderService.mediaPersister = { [weak self] data, suggestedExtension, prefix in
            guard let self else {
                throw NSError(domain: "LocalToolInvokeService", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "UNAVAILABLE: media persister unavailable",
                ])
            }
            let file = try self.persistMediaData(data, suggestedExtension: suggestedExtension, prefix: prefix)
            return TextImageRenderService.PersistedMediaFile(path: file.path, sizeBytes: file.sizeBytes)
        }
    }

    // MARK: - Tool Registry Registration

    /// Register all providers with the tool registry.
    /// Called during `registerAllTools()` from `ToolRegistration.swift`.
    func registerProvidersWithRegistry() async {
        let registry = ToolRegistry.shared

        // Device tools (location, camera, screen, notify, device, watch, photos, image,
        // contacts, calendar, reminders, cron, motion, speech)
        let deviceProvider = DeviceToolDefinitions(
            cameraService: cameraService,
            screenRecordingService: screenRecordingService,
            locationService: locationService,
            deviceStatusService: deviceStatusService,
            watchMessagingService: watchMessagingService,
            photosService: photosService,
            imageBackgroundRemovalService: imageBackgroundRemovalService,
            contactsService: contactsService,
            calendarService: calendarService,
            remindersService: remindersService,
            motionService: motionService,
            userNotifyService: userNotifyService,
            speechService: speechService,
            cronService: cronService,
            notificationCenter: notificationCenter,
            fileSystemService: fileSystemService,
            persistMediaData: { [weak self] data, ext, prefix in
                guard let self else {
                    throw NSError(domain: "LocalToolInvokeService", code: 1, userInfo: [
                        NSLocalizedDescriptionKey: "UNAVAILABLE: media persister unavailable",
                    ])
                }
                let file = try self.persistMediaData(data, suggestedExtension: ext, prefix: prefix)
                return DeviceToolDefinitions.MediaFile(path: file.path, sizeBytes: file.sizeBytes)
            },
            activeAgentWorkspaceURL: { [weak self] in
                self?.activeAgentWorkspaceURL()
            }
        )
        await registry.register(provider: deviceProvider)

        // Web tools
        await registry.register(provider: webFetchService)
        await registry.register(provider: webSearchService)
        await registry.register(provider: imageSearchService)
        await registry.register(provider: youTubeTranscriptService)
        await registry.register(provider: webViewToolService)
        await registry.register(provider: javaScriptService)
        await registry.register(provider: textImageRenderService)

        // File system tools
        await registry.register(provider: fileSystemService)

        // Memory tools
        let memoryProvider = MemoryToolDefinitions()
        var memoryHandlers: [String: ToolHandler] = [:]
        memoryProvider.registerHandlers(
            into: &memoryHandlers,
            runtimeRootURL: runtimeRootURL,
            activeRuntimeRootURLProvider: { [weak self] in
                self?.activeAgentRuntimeRootURL()
            }
        )
        for (command, handler) in memoryHandlers {
            await registry.registerHandler(command: command, handler: handler)
        }
        await registry.register(provider: memoryProvider)

        // Sub agent tools
        let subAgentProvider = SubAgentToolDefinitions()
        var subAgentHandlers: [String: ToolHandler] = [:]
        subAgentProvider.registerHandlers(
            into: &subAgentHandlers,
            workspaceRootURL: workspaceRootURL,
            modelConfig: modelConfig,
            toolInvoker: { [weak self] request, sessionID in
                guard let self else {
                    return BridgeInvokeResponse(
                        id: request.id,
                        ok: false,
                        error: OpenClawNodeError(code: .unavailable, message: "UNAVAILABLE: local tool handler unavailable")
                    )
                }
                return await self.handle(request, sessionID: sessionID)
            }
        )
        for (command, handler) in subAgentHandlers {
            await registry.registerHandler(command: command, handler: handler)
        }
        await registry.register(provider: subAgentProvider)

        // Team / swarm tools
        let teamProvider = TeamToolDefinitions()
        var teamHandlers: [String: ToolHandler] = [:]
        teamProvider.registerHandlers(
            into: &teamHandlers,
            toolContextProvider: { [weak self] in
                TeamSwarmCoordinator.ToolContext(
                    sessionID: Self.InvocationContext.sessionID,
                    senderMemberID: Self.InvocationContext.teamContext?.memberID
                )
            }
        )
        for (command, handler) in teamHandlers {
            await registry.registerHandler(command: command, handler: handler)
        }
        await registry.register(provider: teamProvider)

        // Skill tools
        let skillProvider = SkillToolDefinitions()
        var skillHandlers: [String: ToolHandler] = [:]
        skillProvider.registerHandlers(
            into: &skillHandlers,
            workspaceRootURL: workspaceRootURL,
            modelConfig: modelConfig,
            toolInvoker: { [weak self] request, sessionID in
                guard let self else {
                    return BridgeInvokeResponse(
                        id: request.id,
                        ok: false,
                        error: OpenClawNodeError(code: .unavailable, message: "UNAVAILABLE: local tool handler unavailable")
                    )
                }
                return await self.handle(request, sessionID: sessionID)
            }
        )
        for (command, handler) in skillHandlers {
            await registry.registerHandler(command: command, handler: handler)
        }
        await registry.register(provider: skillProvider)

        // Weather tool
        await registry.register(provider: weatherService)

        // Yahoo Finance tool
        await registry.register(provider: yahooFinanceService)

        // A-share market tool
        await registry.register(provider: aShareMarketService)
    }

    // MARK: - Request Dispatch

    func handle(_ request: BridgeInvokeRequest) async -> BridgeInvokeResponse {
        guard let handler = await ToolRegistry.shared.handler(forCommand: request.command) else {
            return Self.invalidRequest(id: request.id, "unknown command")
        }

        do {
            return try await handler(request)
        } catch let error as NodeCapabilityRouter.RouterError {
            switch error {
            case .unknownCommand:
                return Self.invalidRequest(id: request.id, "unknown command")
            case .handlerUnavailable:
                return Self.unavailableResponse(id: request.id, "UNAVAILABLE: local tool handler unavailable")
            }
        } catch {
            return Self.unavailableResponse(id: request.id, error.localizedDescription)
        }
    }

    func handle(_ request: BridgeInvokeRequest, sessionID: String?) async -> BridgeInvokeResponse {
        await InvocationContext.$sessionID.withValue(sessionID) {
            await self.handle(request)
        }
    }

    func handle(
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

    // MARK: - WebFetch Prompt Processing

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

    // MARK: - Media Persistence

    private struct PersistedMediaFile {
        let path: String
        let sizeBytes: Int
    }

    private nonisolated func persistMediaData(_ data: Data, suggestedExtension: String, prefix: String) throws -> PersistedMediaFile {
        let ext = ToolInvocationHelpers.normalizedFileExtension(suggestedExtension)
        let fileURL = try nextMediaOutputURL(prefix: prefix, suggestedExtension: ext)
        try data.write(to: fileURL, options: .atomic)
        return PersistedMediaFile(path: fileURL.path, sizeBytes: data.count)
    }

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

    private nonisolated func activeAgentWorkspaceURL() -> URL? {
        AgentStore.load().activeAgent?.workspaceURL
    }

    private nonisolated func activeAgentRuntimeRootURL() -> URL? {
        AgentStore.load().activeAgent?.runtimeURL ?? runtimeRootURL?.standardizedFileURL
    }

    // MARK: - Response Helpers

    private static func invalidRequest(id: String, _ message: String) -> BridgeInvokeResponse {
        BridgeInvokeResponse(id: id, ok: false, error: OpenClawNodeError(code: .invalidRequest, message: "INVALID_REQUEST: \(message)"))
    }

    private static func unavailableResponse(id: String, _ message: String) -> BridgeInvokeResponse {
        BridgeInvokeResponse(id: id, ok: false, error: OpenClawNodeError(code: .unavailable, message: message))
    }
}
