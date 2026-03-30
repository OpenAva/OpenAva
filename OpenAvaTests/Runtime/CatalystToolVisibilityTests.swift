import XCTest
@testable import OpenAva

final class CatalystToolVisibilityTests: XCTestCase {
    func testCatalystProfileFiltersWatchAndMotionTools() {
        let definitions = DeviceToolDefinitions(platform: .macCatalyst).toolDefinitions()
        let names = Set(definitions.map(\.functionName))

        XCTAssertFalse(names.contains("watch_status"))
        XCTAssertFalse(names.contains("watch_notify"))
        XCTAssertFalse(names.contains("motion_activity"))
        XCTAssertFalse(names.contains("motion_pedometer"))

        XCTAssertTrue(names.contains("camera_snap"))
        XCTAssertTrue(names.contains("notify_user"))
        XCTAssertTrue(names.contains("device_info"))
    }

    func testCatalystProfileAddsPlatformNotesForLimitedCapabilities() {
        let definitions = DeviceToolDefinitions(platform: .macCatalyst).toolDefinitions()
        let byName = Dictionary(uniqueKeysWithValues: definitions.map { ($0.functionName, $0) })

        let cameraSnapDescription = byName["camera_snap"]?.description ?? ""
        XCTAssertTrue(cameraSnapDescription.contains("Platform note:"))

        let deviceInfoDescription = byName["device_info"]?.description ?? ""
        XCTAssertFalse(deviceInfoDescription.contains("Platform note:"))
    }

    func testIOSProfileKeepsWatchAndMotionToolsWithoutPlatformNotes() {
        let definitions = DeviceToolDefinitions(platform: .iOS).toolDefinitions()
        let names = Set(definitions.map(\.functionName))

        XCTAssertTrue(names.contains("watch_status"))
        XCTAssertTrue(names.contains("watch_notify"))
        XCTAssertTrue(names.contains("motion_activity"))
        XCTAssertTrue(names.contains("motion_pedometer"))

        let byName = Dictionary(uniqueKeysWithValues: definitions.map { ($0.functionName, $0) })
        let cameraSnapDescription = byName["camera_snap"]?.description ?? ""
        XCTAssertFalse(cameraSnapDescription.contains("Platform note:"))
    }
}
