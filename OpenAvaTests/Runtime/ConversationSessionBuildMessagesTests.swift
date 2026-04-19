import ChatUI
import Foundation
import XCTest
@testable import OpenAva

@MainActor
final class ConversationSessionBuildMessagesTests: XCTestCase {
    func testRequestHistoryReturnsAllMessagesAfterLatestCompactBoundary() {
        let session = makeSession(id: "after-boundary-all")
        let now = Date()
        _ = appendMessage(
            to: session,
            role: .user,
            text: "before-boundary",
            createdAt: now.addingTimeInterval(-3600)
        )
        let boundary = appendMessage(
            to: session,
            role: .system,
            text: "Conversation compacted.",
            createdAt: now.addingTimeInterval(-1800)
        )
        boundary.subtype = "compact_boundary"

        let keptIDs = [
            appendMessage(to: session, role: .user, text: "message-1", createdAt: now.addingTimeInterval(-300)).id,
            appendMessage(to: session, role: .assistant, text: "message-2", createdAt: now.addingTimeInterval(-240)).id,
            appendMessage(to: session, role: .user, text: "message-3", createdAt: now.addingTimeInterval(-180)).id,
            appendMessage(to: session, role: .assistant, text: "message-4", createdAt: now.addingTimeInterval(-120)).id,
            appendMessage(to: session, role: .user, text: "message-5", createdAt: now.addingTimeInterval(-60)).id,
        ]

        let selectedIDs = session.requestHistoryMessages().map(\.id)
        XCTAssertEqual(selectedIDs, keptIDs)
    }

    func testRequestHistoryKeepsSummaryAndSkipsBoundary() {
        let session = makeSession(id: "compaction-boundary")
        let now = Date()

        let boundary = appendMessage(
            to: session,
            role: .system,
            text: "Conversation compacted.",
            createdAt: now.addingTimeInterval(-4 * 3600)
        )
        boundary.subtype = "compact_boundary"

        let summary = appendMessage(
            to: session,
            role: .user,
            text: "Earlier conversation summary.",
            createdAt: now.addingTimeInterval(-4 * 3600 + 1)
        )
        summary.metadata["isCompactSummary"] = "true"

        let keptIDs = [
            appendMessage(to: session, role: .assistant, text: "recent-1", createdAt: now.addingTimeInterval(-4 * 60)).id,
            appendMessage(to: session, role: .user, text: "recent-2", createdAt: now.addingTimeInterval(-3 * 60)).id,
            appendMessage(to: session, role: .assistant, text: "recent-3", createdAt: now.addingTimeInterval(-2 * 60)).id,
            appendMessage(to: session, role: .user, text: "recent-4", createdAt: now.addingTimeInterval(-60)).id,
        ]

        let selectedIDs = session.requestHistoryMessages().map(\.id)
        XCTAssertEqual(selectedIDs, [summary.id] + keptIDs)
        XCTAssertFalse(selectedIDs.contains(boundary.id))
    }

    func testBuildRequestMessagesDropsUnsupportedCustomRoles() {
        let session = makeSession(id: "unsupported-role")
        let message = appendMessage(
            to: session,
            role: MessageRole(rawValue: "tool"),
            text: "legacy tool message",
            createdAt: Date()
        )

        let requestMessages = session.buildRequestMessages(from: message, capabilities: [])
        XCTAssertTrue(requestMessages.isEmpty)
    }

    private func makeSession(id: String) -> ConversationSession {
        ConversationSession(id: id, configuration: .init(storage: DisposableStorageProvider()))
    }

    @discardableResult
    private func appendMessage(
        to session: ConversationSession,
        role: MessageRole,
        text: String,
        createdAt: Date
    ) -> ConversationMessage {
        let message = session.appendNewMessage(role: role)
        message.textContent = text
        message.createdAt = createdAt
        return message
    }
}
