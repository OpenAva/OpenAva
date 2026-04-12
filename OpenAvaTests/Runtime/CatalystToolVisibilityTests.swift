import XCTest
@testable import OpenAva

@MainActor
final class CatalystToolVisibilityTests: XCTestCase {
    func testCatalystProfileFiltersWatchAndMotionTools() {
        let definitions = makeDeviceTools(platform: .macCatalyst).toolDefinitions()
        let names = Set(definitions.map(\.functionName))

        XCTAssertFalse(names.contains("watch_status"))
        XCTAssertFalse(names.contains("watch_notify"))
        XCTAssertFalse(names.contains("motion_activity"))
        XCTAssertFalse(names.contains("motion_pedometer"))

        XCTAssertTrue(names.contains("camera_snap"))
        XCTAssertTrue(names.contains("notify_user"))
        XCTAssertTrue(names.contains("device_info"))
    }

    func testCatalystProfileKeepsLimitedCapabilitiesVisibleWithoutDescriptionNotes() {
        let definitions = makeDeviceTools(platform: .macCatalyst).toolDefinitions()
        let byName = Dictionary(uniqueKeysWithValues: definitions.map { ($0.functionName, $0) })

        XCTAssertTrue(DeviceTools.PlatformProfile.macCatalyst.limitedFunctionNames.contains("camera_snap"))
        XCTAssertFalse(DeviceTools.PlatformProfile.macCatalyst.limitedFunctionNames.contains("device_info"))

        let cameraSnapDescription = byName["camera_snap"]?.description ?? ""
        XCTAssertFalse(cameraSnapDescription.contains("Platform note:"))

        let deviceInfoDescription = byName["device_info"]?.description ?? ""
        XCTAssertFalse(deviceInfoDescription.contains("Platform note:"))
    }

    func testIOSProfileKeepsWatchAndMotionToolsWithoutPlatformNotes() {
        let definitions = makeDeviceTools(platform: .iOS).toolDefinitions()
        let names = Set(definitions.map(\.functionName))

        XCTAssertTrue(names.contains("watch_status"))
        XCTAssertTrue(names.contains("watch_notify"))
        XCTAssertTrue(names.contains("motion_activity"))
        XCTAssertTrue(names.contains("motion_pedometer"))

        let byName = Dictionary(uniqueKeysWithValues: definitions.map { ($0.functionName, $0) })
        let cameraSnapDescription = byName["camera_snap"]?.description ?? ""
        XCTAssertFalse(cameraSnapDescription.contains("Platform note:"))
    }

    private func makeDeviceTools(platform: DeviceTools.PlatformProfile) -> DeviceTools {
        let notificationCenter = LiveNotificationCenter()
        return DeviceTools(
            platform: platform,
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
            speechService: SpeechService(),
            cronService: CronService(),
            notificationCenter: notificationCenter,
            fileSystemService: FileSystemService(),
            persistMediaData: { _, _, _ in DeviceTools.MediaFile(path: "", sizeBytes: 0) },
            activeAgentWorkspaceURL: { nil }
        )
    }
}
