import CoreLocation
import OpenClawKit
import XCTest
@testable import OpenAva

final class ToolDefinitionSemanticsTests: XCTestCase {
    @MainActor
    private func makeRuntime(locationService: (any LocationServicing)? = nil) -> ToolRuntime {
        ToolRuntime(
            cameraService: StubCameraService(),
            screenRecordingService: StubScreenRecordingService(),
            locationService: locationService ?? StubLocationService(),
            deviceStatusService: StubDeviceStatusService(),
            watchMessagingService: StubWatchMessagingService(),
            photosService: StubPhotosService(),
            imageBackgroundRemovalService: StubImageBackgroundRemovalService(),
            contactsService: StubContactsService(),
            calendarService: StubCalendarService(),
            remindersService: StubRemindersService(),
            motionService: StubMotionService(),
            userNotifyService: StubUserNotifyService(),
            speechService: StubSpeechService(),
            cronService: StubCronService(),
            notificationCenter: StubNotificationCenter(),
            webFetchService: WebFetchService(),
            webSearchService: WebSearchService(),
            imageSearchService: ImageSearchService(),
            youTubeTranscriptService: YouTubeTranscriptService(),
            webViewToolService: WebViewService.shared,
            javaScriptService: JavaScriptService(),
            textImageRenderService: TextImageRenderService(),
            fileSystemService: FileSystemService()
        )
    }

    func testArxivSearchDefinitionExposesReadOnlySemantics() {
        let definitions = ArxivSearchService().toolDefinitions()
        let byName = Dictionary(uniqueKeysWithValues: definitions.map { ($0.functionName, $0) })

        XCTAssertEqual(byName["arxiv_search"]?.isReadOnly, true)
        XCTAssertEqual(byName["arxiv_search"]?.isDestructive, false)
        XCTAssertEqual(byName["arxiv_search"]?.isConcurrencySafe, true)
        XCTAssertEqual(byName["arxiv_search"]?.maxResultSizeChars, 24 * 1024)
    }

    func testFileSystemDefinitionsExposeReadOnlyAndMutableSemantics() async {
        let definitions = await FileSystemService().toolDefinitions()
        let byName = Dictionary(uniqueKeysWithValues: definitions.map { ($0.functionName, $0) })

        XCTAssertEqual(byName["fs_read"]?.isReadOnly, true)
        XCTAssertEqual(byName["fs_read"]?.isConcurrencySafe, true)
        XCTAssertEqual(byName["fs_read"]?.maxResultSizeChars, 48 * 1024)

        XCTAssertEqual(byName["fs_write"]?.isReadOnly, false)
        XCTAssertEqual(byName["fs_write"]?.isDestructive, true)
        XCTAssertEqual(byName["fs_write"]?.isConcurrencySafe, false)

        XCTAssertEqual(byName["fs_grep"]?.isReadOnly, true)
        XCTAssertEqual(byName["fs_grep"]?.isConcurrencySafe, true)
        XCTAssertEqual(byName["fs_grep"]?.maxResultSizeChars, 24 * 1024)
    }

    func testExplicitSemanticsAreUsedDirectly() {
        let weather = ToolDefinition(
            functionName: "weather_get",
            command: "weather.get",
            description: "",
            parametersSchema: .init([:] as [String: Any]),
            isReadOnly: true,
            isConcurrencySafe: true
        )
        XCTAssertTrue(weather.isReadOnly)
        XCTAssertTrue(weather.isConcurrencySafe)
        XCTAssertFalse(weather.isDestructive)

        let memoryForget = ToolDefinition(
            functionName: "memory_forget",
            command: "memory.forget",
            description: "",
            parametersSchema: .init([:] as [String: Any]),
            isReadOnly: false,
            isDestructive: true,
            isConcurrencySafe: false
        )
        XCTAssertFalse(memoryForget.isReadOnly)
        XCTAssertTrue(memoryForget.isDestructive)
        XCTAssertFalse(memoryForget.isConcurrencySafe)
    }

    func testMemoryDefinitionsExposeClaudeStyleSemantics() {
        let definitions = MemoryTools().toolDefinitions()
        let byName = Dictionary(uniqueKeysWithValues: definitions.map { ($0.functionName, $0) })

        XCTAssertEqual(byName["memory_recall"]?.isReadOnly, true)
        XCTAssertEqual(byName["memory_recall"]?.isConcurrencySafe, true)
        XCTAssertEqual(byName["memory_transcript_search"]?.isReadOnly, true)
        XCTAssertEqual(byName["memory_upsert"]?.isDestructive, true)
        XCTAssertEqual(byName["memory_forget"]?.isDestructive, true)
    }

    @MainActor
    func testJavaScriptDefinitionExposesScriptPathSchema() throws {
        let definitions = JavaScriptService().toolDefinitions()
        let byName = Dictionary(uniqueKeysWithValues: definitions.map { ($0.functionName, $0) })

        let definition = try XCTUnwrap(byName["javascript_execute"])
        XCTAssertEqual(definition.isReadOnly, false)
        XCTAssertEqual(definition.isDestructive, false)
        XCTAssertEqual(definition.isConcurrencySafe, false)

        let schema = try XCTUnwrap(definition.parametersSchema.value as? [String: Any])
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        XCTAssertNotNil(properties["script_path"])

        let variants = try XCTUnwrap(schema["oneOf"] as? [[String: Any]])
        XCTAssertEqual(variants.count, 2)
    }

    func testToolRegistryDefinitionLookupPreservesMetadata() async {
        final class TestProvider: ToolDefinitionProvider {
            func toolDefinitions() -> [ToolDefinition] {
                [
                    ToolDefinition(
                        functionName: "tool_test",
                        command: "tool.test",
                        description: "",
                        parametersSchema: .init([:] as [String: Any]),
                        isReadOnly: true,
                        isDestructive: false,
                        isConcurrencySafe: true,
                        maxResultSizeChars: 1024
                    ),
                ]
            }
        }

        let registry = ToolRegistry.shared
        await registry.clear()

        await registry.register(provider: TestProvider())

        let definition = await registry.definition(forFunctionName: "tool_test")
        await MainActor.run {
            XCTAssertEqual(definition?.command, "tool.test")
            XCTAssertEqual(definition?.isReadOnly, true)
            XCTAssertEqual(definition?.isDestructive, false)
            XCTAssertEqual(definition?.isConcurrencySafe, true)
            XCTAssertEqual(definition?.maxResultSizeChars, 1024)
        }

        await registry.clear()
    }

    func testSkillHandlerWorksWithoutRetainingProviderInstance() async throws {
        let workspaceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tool-registry-skill-tests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let skillDirectory = workspaceURL
            .appendingPathComponent("skills", isDirectory: true)
            .appendingPathComponent("alpha", isDirectory: true)
        let skillFileURL = skillDirectory.appendingPathComponent("SKILL.md", isDirectory: false)

        try FileManager.default.createDirectory(at: skillDirectory, withIntermediateDirectories: true)
        try "Use this skill to help with alpha tasks.".write(to: skillFileURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: workspaceURL) }

        let registry = ToolRegistry.shared
        await registry.clear()
        await registry.register(provider: SkillTools(), context: ToolHandlerRegistrationContext(workspaceRootURL: workspaceURL))

        guard let handler = await registry.handler(forCommand: "skill.invoke") else {
            XCTFail("Expected skill.invoke handler to be registered")
            return
        }

        let response = try await handler(
            BridgeInvokeRequest(
                id: UUID().uuidString,
                command: "skill.invoke",
                paramsJSON: #"{"name":"alpha"}"#
            )
        )

        XCTAssertTrue(response.ok)
        XCTAssertTrue(response.payload?.contains("## Skill Invocation") == true)

        await registry.clear()
    }

    @MainActor
    func testCurrentTimeToolWorksThroughToolRuntime() async {
        let runtime = makeRuntime()
        let response = await runtime.handle(
            BridgeInvokeRequest(
                id: UUID().uuidString,
                command: "current.time",
                paramsJSON: nil
            )
        )

        XCTAssertTrue(response.ok)
        XCTAssertTrue(response.payload?.contains("## Runtime Time") == true)
        XCTAssertTrue(response.payload?.contains("- timezone:") == true)
    }

    @MainActor
    func testLocationToolReturnsAgeMetadata() async {
        let location = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 37.33182, longitude: -122.03118),
            altitude: 15,
            horizontalAccuracy: 8,
            verticalAccuracy: 6,
            course: 180,
            speed: 1.25,
            timestamp: Date()
        )
        let runtime = makeRuntime(locationService: StubLocationService(result: .success(location)))

        let response = await runtime.handle(
            BridgeInvokeRequest(
                id: UUID().uuidString,
                command: "location.get",
                paramsJSON: #"{"timeoutMs":200,"desiredAccuracy":"balanced"}"#
            )
        )

        XCTAssertTrue(response.ok)
        XCTAssertTrue(response.payload?.contains("## Location") == true)
        XCTAssertTrue(response.payload?.contains("- age_ms:") == true)
        XCTAssertTrue(response.payload?.contains("- accuracy_m: 8.0") == true)
    }

    @MainActor
    func testLocationToolTimeoutUsesNormalizedTimeoutMessage() async {
        let runtime = makeRuntime(locationService: StubLocationService(result: .failure(LocationService.Error.timeout)))

        let response = await runtime.handle(
            BridgeInvokeRequest(
                id: UUID().uuidString,
                command: "location.get",
                paramsJSON: #"{"timeoutMs":200}"#
            )
        )

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error?.message, "LOCATION_TIMEOUT: unable to determine location within 1000ms")
    }
}

private enum StubToolError: Error {
    case unexpectedCall
}

private struct StubCameraService: CameraServicing {
    func listDevices() async -> [CameraController.CameraDeviceInfo] {
        []
    }

    func snap(params _: OpenClawCameraSnapParams) async throws -> CameraSnapMediaResult {
        throw StubToolError.unexpectedCall
    }

    func clip(params _: OpenClawCameraClipParams) async throws -> CameraClipMediaResult {
        throw StubToolError.unexpectedCall
    }
}

private struct StubScreenRecordingService: ScreenRecordingServicing {
    func record(screenIndex _: Int?, durationMs _: Int?, fps _: Double?, includeAudio _: Bool?, outPath _: String?) async throws -> String {
        throw StubToolError.unexpectedCall
    }
}

@MainActor
private final class StubLocationService: LocationServicing {
    enum Result {
        case success(CLLocation)
        case failure(Swift.Error)
    }

    private let authorization: CLAuthorizationStatus
    private let accuracy: CLAccuracyAuthorization
    private let result: Result

    init(
        authorization: CLAuthorizationStatus = .authorizedWhenInUse,
        accuracy: CLAccuracyAuthorization = .fullAccuracy,
        result: Result = .success(CLLocation(latitude: 0, longitude: 0))
    ) {
        self.authorization = authorization
        self.accuracy = accuracy
        self.result = result
    }

    func authorizationStatus() -> CLAuthorizationStatus {
        authorization
    }

    func accuracyAuthorization() -> CLAccuracyAuthorization {
        accuracy
    }

    func ensureAuthorization(mode _: OpenClawLocationMode) async -> CLAuthorizationStatus {
        authorization
    }

    func currentLocation(params _: OpenClawLocationGetParams, desiredAccuracy _: OpenClawLocationAccuracy, maxAgeMs _: Int?, timeoutMs _: Int?) async throws -> CLLocation {
        switch result {
        case let .success(location):
            return location
        case let .failure(error):
            throw error
        }
    }

    func startLocationUpdates(desiredAccuracy _: OpenClawLocationAccuracy, significantChangesOnly _: Bool) -> AsyncStream<CLLocation> {
        AsyncStream { continuation in continuation.finish() }
    }

    func stopLocationUpdates() {}
    func startMonitoringSignificantLocationChanges(onUpdate _: @escaping @Sendable (CLLocation) -> Void) {}
    func stopMonitoringSignificantLocationChanges() {}
}

@MainActor
private final class StubDeviceStatusService: DeviceStatusServicing {
    func status() async throws -> OpenClawDeviceStatusPayload {
        throw StubToolError.unexpectedCall
    }

    func info() -> OpenClawDeviceInfoPayload {
        OpenClawDeviceInfoPayload(
            deviceName: "Test Device",
            modelIdentifier: "test-model",
            systemName: "iOS",
            systemVersion: "1.0",
            appVersion: "1.0",
            appBuild: "1",
            locale: "en_US"
        )
    }
}

private final class StubWatchMessagingService: WatchMessagingServicing {
    func status() async -> WatchMessagingStatus {
        WatchMessagingStatus(supported: false, paired: false, appInstalled: false, reachable: false, activationState: "inactive")
    }

    func setReplyHandler(_: (@Sendable (WatchQuickReplyEvent) -> Void)?) {}
    func sendNotification(id _: String, params _: OpenClawWatchNotifyParams) async throws -> WatchNotificationSendResult {
        throw StubToolError.unexpectedCall
    }
}

private struct StubPhotosService: PhotosServicing {
    func latest(params _: OpenClawPhotosLatestParams) async throws -> PhotosLatestMediaPayload {
        throw StubToolError.unexpectedCall
    }
}

private struct StubImageBackgroundRemovalService: ImageBackgroundRemoving {
    func removeBackground(params _: OpenClawImageRemoveBackgroundParams, fileSystemService _: FileSystemService) async throws -> OpenClawImageRemoveBackgroundPayload {
        throw StubToolError.unexpectedCall
    }
}

private struct StubContactsService: ContactsServicing {
    func search(params _: OpenClawContactsSearchParams) async throws -> OpenClawContactsSearchPayload {
        throw StubToolError.unexpectedCall
    }

    func add(params _: OpenClawContactsAddParams) async throws -> OpenClawContactsAddPayload {
        throw StubToolError.unexpectedCall
    }
}

private struct StubCalendarService: CalendarServicing {
    func events(params _: OpenClawCalendarEventsParams) async throws -> OpenClawCalendarEventsPayload {
        throw StubToolError.unexpectedCall
    }

    func add(params _: OpenClawCalendarAddParams) async throws -> OpenClawCalendarAddPayload {
        throw StubToolError.unexpectedCall
    }
}

private struct StubRemindersService: RemindersServicing {
    func list(params _: OpenClawRemindersListParams) async throws -> OpenClawRemindersListPayload {
        throw StubToolError.unexpectedCall
    }

    func add(params _: OpenClawRemindersAddParams) async throws -> OpenClawRemindersAddPayload {
        throw StubToolError.unexpectedCall
    }
}

private struct StubMotionService: MotionServicing {
    func activities(params _: OpenClawMotionActivityParams) async throws -> OpenClawMotionActivityPayload {
        throw StubToolError.unexpectedCall
    }

    func pedometer(params _: OpenClawPedometerParams) async throws -> OpenClawPedometerPayload {
        throw StubToolError.unexpectedCall
    }
}

@MainActor
private final class StubUserNotifyService: UserNotifyServicing {
    func notify(params _: UserNotifyParams) async throws -> UserNotifyExecutionResult {
        UserNotifyExecutionResult(messageId: "test", spoke: false)
    }
}

@MainActor
private final class StubSpeechService: SpeechServicing {
    func transcribe(params _: OpenClawSpeechTranscribeParams) async throws -> OpenClawSpeechTranscribePayload {
        throw StubToolError.unexpectedCall
    }
}

private struct StubCronService: CronServicing {
    func add(message _: String, atISO _: String?, everySeconds _: Int?, kind _: CronJobKind, agentID _: String?) async throws -> CronJobPayload {
        throw StubToolError.unexpectedCall
    }

    func list() async throws -> CronListPayload {
        throw StubToolError.unexpectedCall
    }

    func remove(id _: String) async throws -> CronRemovePayload {
        throw StubToolError.unexpectedCall
    }
}

private struct StubNotificationCenter: NotificationCentering {
    func authorizationStatus() async -> NotificationAuthorizationStatus {
        .authorized
    }

    func requestAuthorization(options _: UNAuthorizationOptions) async throws -> Bool {
        true
    }

    func add(_: UNNotificationRequest) async throws {}
}
