import Foundation
import XCTest
@testable import OpenAva

final class HeartbeatSupportTests: XCTestCase {
    func testBuildPromptEmbedsHeartbeatMarkdownAndAckToken() {
        let prompt = HeartbeatSupport.buildPrompt(heartbeatMarkdown: "- Check reminders")

        XCTAssertTrue(prompt.contains("<HEARTBEAT_MD>"))
        XCTAssertTrue(prompt.contains("- Check reminders"))
        XCTAssertTrue(prompt.contains(HeartbeatSupport.ackToken))
    }

    func testSuppressesExactAckToken() {
        XCTAssertTrue(HeartbeatSupport.shouldSuppressAssistantMessage("HEARTBEAT_OK"))
    }

    func testSuppressesAckTokenWithShortTrailingText() {
        XCTAssertTrue(HeartbeatSupport.shouldSuppressAssistantMessage("HEARTBEAT_OK all clear"))
        XCTAssertTrue(HeartbeatSupport.shouldSuppressAssistantMessage("All clear HEARTBEAT_OK"))
    }

    func testDoesNotSuppressRegularAssistantMessage() {
        XCTAssertFalse(HeartbeatSupport.shouldSuppressAssistantMessage("Please review today's reminders."))
    }

    func testIdentifiesHiddenHeartbeatConversationIDs() {
        let conversationID = HeartbeatSupport.conversationID(for: "agent-1")

        XCTAssertTrue(HeartbeatSupport.isHiddenConversationID(conversationID))
        XCTAssertFalse(HeartbeatSupport.isHiddenConversationID("main"))
    }

    func testParseDocumentFrontMatterOverridesIntervalAndActiveHours() {
        let parsed = HeartbeatSupport.parseDocument(
            """
            ---
            every: 45m
            active_hours: 09:00-12:00, 14:00-18:00
            notify: silent
            ---
            - Check reminders
            """
        )

        XCTAssertEqual(parsed.instructions, "- Check reminders")
        XCTAssertEqual(parsed.configuration.interval, 45 * 60)
        XCTAssertEqual(parsed.configuration.activeHours.count, 2)
        XCTAssertEqual(parsed.configuration.notify, .silent)
    }

    func testParseDocumentWithoutFrontMatterUsesDefaults() {
        let parsed = HeartbeatSupport.parseDocument("- Check reminders")

        XCTAssertEqual(parsed.instructions, "- Check reminders")
        XCTAssertEqual(parsed.configuration.interval, HeartbeatSupport.defaultInterval)
        XCTAssertTrue(parsed.configuration.activeHours.isEmpty)
        XCTAssertEqual(parsed.configuration.notify, .always)
    }

    func testParseDocumentSupportsAlwaysNotifyMode() {
        let parsed = HeartbeatSupport.parseDocument(
            """
            ---
            notify: always
            ---
            - Check reminders
            """
        )

        XCTAssertEqual(parsed.configuration.notify, .always)
    }

    func testActiveHoursDetectOvernightWindow() {
        let parsed = HeartbeatSupport.parseDocument(
            """
            ---
            active_hours: 22:00-06:00
            ---
            - Watch for urgent messages
            """
        )
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current

        let activeDate = date(hour: 23, minute: 30, calendar: calendar)
        let inactiveDate = date(hour: 12, minute: 0, calendar: calendar)

        XCTAssertTrue(parsed.configuration.isActive(at: activeDate, calendar: calendar))
        XCTAssertFalse(parsed.configuration.isActive(at: inactiveDate, calendar: calendar))
    }

    func testDelayUntilNextActiveWindow() {
        let parsed = HeartbeatSupport.parseDocument(
            """
            ---
            active_hours: 09:00-10:00
            ---
            - Morning review
            """
        )
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current

        let now = date(hour: 8, minute: 30, calendar: calendar)
        let delay = parsed.configuration.delayUntilActive(from: now, calendar: calendar)

        XCTAssertEqual(delay, 30 * 60, accuracy: 1)
    }

    func testTrimToRecentKeepsNewestItems() {
        XCTAssertEqual(HeartbeatSupport.trimToRecent([1, 2, 3, 4], limit: 2), [3, 4])
        XCTAssertEqual(HeartbeatSupport.trimToRecent([1, 2], limit: 5), [1, 2])
    }

    private func date(hour: Int, minute: Int, calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: 2026,
            month: 4,
            day: 1,
            hour: hour,
            minute: minute,
            second: 0
        )) ?? Date(timeIntervalSince1970: 0)
    }
}
