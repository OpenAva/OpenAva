import Foundation
import XCTest
@testable import OpenAva

final class TeamRuntimePersistenceTests: XCTestCase {
    override func setUp() {
        super.setUp()
        removeTeamStoreFile()
    }

    override func tearDown() {
        removeTeamStoreFile()
        super.tearDown()
    }

    func testMailboxAppendReadAndMarkRead() throws {
        let teamDirectoryURL = makeTemporaryTeamDirectory()
        defer { try? FileManager.default.removeItem(at: teamDirectoryURL) }

        let message = TeamMailboxMessage(
            id: "m1",
            from: "coordinator",
            text: "Finish the migration",
            timestamp: Date(timeIntervalSince1970: 1),
            read: false,
            color: nil,
            summary: "Finish the migration",
            messageType: "task"
        )

        try TeamMailbox.append(teamDirectoryURL: teamDirectoryURL, recipientName: "worker", message: message)

        XCTAssertEqual(TeamMailbox.unreadCount(teamDirectoryURL: teamDirectoryURL, recipientName: "worker"), 1)
        XCTAssertEqual(TeamMailbox.lastPreview(teamDirectoryURL: teamDirectoryURL, recipientName: "worker"), "Finish the migration")

        try TeamMailbox.markRead(teamDirectoryURL: teamDirectoryURL, recipientName: "worker", messageIDs: ["m1"])

        XCTAssertTrue(TeamMailbox.unreadMessages(teamDirectoryURL: teamDirectoryURL, recipientName: "worker").isEmpty)
    }

    func testPermissionSyncWritePendingAndResolve() throws {
        let teamDirectoryURL = makeTemporaryTeamDirectory()
        defer { try? FileManager.default.removeItem(at: teamDirectoryURL) }

        let request = TeamPermissionRequest(
            id: "p1",
            kind: "plan_execution",
            workerID: "worker@alpha",
            workerName: "worker",
            teamName: "alpha",
            toolName: "team.plan.approve",
            description: "Approve the proposed plan",
            inputJSON: nil,
            status: .pending,
            resolvedBy: nil,
            resolvedAt: nil,
            feedback: nil,
            createdAt: Date(timeIntervalSince1970: 1)
        )

        try TeamPermissionSync.writePending(teamDirectoryURL: teamDirectoryURL, request: request)
        XCTAssertEqual(TeamPermissionSync.readPending(teamDirectoryURL: teamDirectoryURL).count, 1)

        let resolved = try TeamPermissionSync.resolve(
            teamDirectoryURL: teamDirectoryURL,
            requestID: "p1",
            resolution: TeamPermissionResolution(status: .approved, resolvedBy: "coordinator", feedback: "Looks good")
        )

        XCTAssertEqual(resolved?.status, .approved)
        XCTAssertTrue(TeamPermissionSync.readPending(teamDirectoryURL: teamDirectoryURL).isEmpty)
    }

    func testTeamStoreSupportsEmptyTeamsAndDynamicMembership() throws {
        let firstAgentID = UUID()
        let secondAgentID = UUID()

        let created = TeamStore.createTeam(
            name: "Default Team",
            emoji: "🛰️"
        )

        XCTAssertNotNil(created)
        XCTAssertEqual(created?.emoji, "🛰️")
        XCTAssertEqual(TeamStore.load().teams.first?.agentPoolIDs, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: teamStoreFileURL().path))

        let rawContent = try String(contentsOf: teamStoreFileURL(), encoding: .utf8)
        XCTAssertTrue(rawContent.contains("Default Team"))

        _ = try TeamStore.addAgents([firstAgentID, secondAgentID, firstAgentID], to: XCTUnwrap(created?.id))
        XCTAssertEqual(TeamStore.load().teams.first?.agentPoolIDs, [firstAgentID, secondAgentID])

        _ = try TeamStore.removeAgent(firstAgentID, from: XCTUnwrap(created?.id))

        let remaining = TeamStore.load().teams.first
        XCTAssertEqual(remaining?.agentPoolIDs, [secondAgentID])
    }

    private func makeTemporaryTeamDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func removeTeamStoreFile() {
        try? FileManager.default.removeItem(at: teamStoreFileURL())
    }

    private func teamStoreFileURL() -> URL {
        let rootURL = TeamStore.storageDirectoryURL(fileManager: .default)
        return rootURL?.appendingPathComponent("teams.json", isDirectory: false) ?? FileManager.default.temporaryDirectory.appendingPathComponent("teams.json", isDirectory: false)
    }
}
