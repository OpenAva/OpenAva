import ChatUI
import Foundation
import XCTest
@testable import OpenAva

@MainActor
final class ConversationSessionBuildMessagesTests: XCTestCase {
    func testRequestHistoryDefaultsToRecentFourMessages() {
        let session = makeSession(id: "recent-four")
        let now = Date()
        let ids = (0 ..< 6).map { index in
            appendMessage(
                to: session,
                role: index.isMultiple(of: 2) ? .user : .assistant,
                text: "message-\(index)",
                createdAt: now.addingTimeInterval(TimeInterval(-7200 + index * 60))
            ).id
        }

        let selectedIDs = session.requestHistoryMessages(referenceDate: now).map(\.id)
        XCTAssertEqual(selectedIDs, Array(ids.suffix(4)))
    }

    func testRequestHistoryExtendsOlderMessagesWhenConversationIsStillRecent() {
        let session = makeSession(id: "recent-continuation")
        let now = Date()
        let offsets: [TimeInterval] = [-45 * 60, -25 * 60, -20 * 60, -15 * 60, -10 * 60, -5 * 60, -60]
        let ids = offsets.enumerated().map { index, offset in
            appendMessage(
                to: session,
                role: index.isMultiple(of: 2) ? .user : .assistant,
                text: "message-\(index)",
                createdAt: now.addingTimeInterval(offset)
            ).id
        }

        let selectedIDs = session.requestHistoryMessages(referenceDate: now).map(\.id)
        XCTAssertEqual(selectedIDs, Array(ids.suffix(6)))
    }

    func testRequestHistoryPrependsCompactionSummaryWithoutCrossingBoundary() {
        let session = makeSession(id: "compaction-boundary")
        let now = Date()

        let boundary = appendMessage(
            to: session,
            role: .system,
            text: "\(ConversationMarkers.compactBoundaryPrefix)\n\nConversation compacted.",
            createdAt: now.addingTimeInterval(-4 * 3600)
        )
        boundary.subtype = "compact_boundary"

        let summary = appendMessage(
            to: session,
            role: .user,
            text: "\(ConversationMarkers.contextSummaryPrefix)\n\nEarlier conversation summary.",
            createdAt: now.addingTimeInterval(-4 * 3600 + 1)
        )
        summary.metadata["isCompactionSummary"] = "true"

        _ = appendMessage(
            to: session,
            role: .assistant,
            text: "old-preserved-1",
            createdAt: now.addingTimeInterval(-3 * 3600)
        )
        _ = appendMessage(
            to: session,
            role: .user,
            text: "old-preserved-2",
            createdAt: now.addingTimeInterval(-2 * 3600)
        )

        let recentIDs = [
            appendMessage(to: session, role: .assistant, text: "recent-1", createdAt: now.addingTimeInterval(-4 * 60)).id,
            appendMessage(to: session, role: .user, text: "recent-2", createdAt: now.addingTimeInterval(-3 * 60)).id,
            appendMessage(to: session, role: .assistant, text: "recent-3", createdAt: now.addingTimeInterval(-2 * 60)).id,
            appendMessage(to: session, role: .user, text: "recent-4", createdAt: now.addingTimeInterval(-60)).id,
        ]

        let selectedIDs = session.requestHistoryMessages(referenceDate: now).map(\.id)
        XCTAssertEqual(selectedIDs, [summary.id] + recentIDs)
        XCTAssertFalse(selectedIDs.contains(boundary.id))
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
