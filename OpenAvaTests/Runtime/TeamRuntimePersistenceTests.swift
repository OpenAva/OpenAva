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

    @MainActor
    func testSendMessageToTeamMemberDoesNotAppendUserTranscriptEntry() throws {
        let transcriptRuntimeURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let agentStateFileURL = try? AgentStore.workspaceRootDirectory(fileManager: .default)
            .appendingPathComponent(".agents.json", isDirectory: false)
        let originalAgentState = agentStateFileURL.flatMap { try? Data(contentsOf: $0) }
        try FileManager.default.createDirectory(at: transcriptRuntimeURL, withIntermediateDirectories: true)
        TranscriptStorageProvider.removeProvider(runtimeRootURL: transcriptRuntimeURL)
        defer {
            TranscriptStorageProvider.removeProvider(runtimeRootURL: transcriptRuntimeURL)
            try? FileManager.default.removeItem(at: transcriptRuntimeURL)
            if let agentStateFileURL {
                if let originalAgentState {
                    try? originalAgentState.write(to: agentStateFileURL, options: [.atomic])
                } else {
                    try? FileManager.default.removeItem(at: agentStateFileURL)
                }
            }
        }

        let agentName = "Worker-\(UUID().uuidString)"
        let teamName = "Team-\(UUID().uuidString)"
        let messageBody = "Please continue execution"

        let agent = try AgentStore.createAgent(
            name: agentName,
            emoji: "🧪",
            fileManager: .default
        )
        defer { _ = AgentStore.deleteAgent(agent.id, fileManager: .default) }

        let team = try XCTUnwrap(TeamStore.createTeam(name: teamName, emoji: "👥", fileManager: .default))
        defer { TeamStore.deleteTeam(team.id, fileManager: .default) }
        _ = try XCTUnwrap(TeamStore.addAgents([agent.id], to: team.id, fileManager: .default))

        let teamRuntimeRoot = try XCTUnwrap(TeamStore.runtimeDirectoryURL(fileManager: .default, createDirectoryIfNeeded: true))
        let teamDirectoryURL = teamRuntimeRoot.appendingPathComponent(team.name, isDirectory: true)
        try FileManager.default.createDirectory(at: teamDirectoryURL, withIntermediateDirectories: true)

        let persistedTeam = TeamFile(
            name: team.name,
            description: nil,
            createdAt: team.createdAt,
            updatedAt: team.updatedAt,
            coordinatorId: "\(TeamSwarmCoordinator.coordinatorName)@\(team.name)",
            coordinatorSessionId: team.name,
            hiddenPaneIds: [],
            teamAllowedPaths: [],
            nextTaskID: 1,
            tasks: [],
            members: [
                TeamFileMember(
                    agentId: agent.id.uuidString,
                    agentType: SubAgentRegistry.generalPurpose.agentType,
                    prompt: "Existing approved plan context",
                    planModeRequired: true,
                    sessionId: "\(agent.id.uuidString)::main",
                    mode: nil,
                    lastStatus: TeamSwarmCoordinator.MemberStatus.awaitingPlanApproval.rawValue,
                    pendingPlanRequestID: "pending-plan"
                ),
            ]
        )
        let persistedData = try JSONEncoder().encode(persistedTeam)
        try persistedData.write(to: teamDirectoryURL.appendingPathComponent("config.json", isDirectory: false), options: [.atomic])

        let coordinator = TeamSwarmCoordinator.shared
        coordinator.configure(runtimeRootURL: transcriptRuntimeURL, workspaceRootURL: nil, modelConfig: nil)
        coordinator.reload()

        let transcriptProvider = TranscriptStorageProvider.provider(runtimeRootURL: transcriptRuntimeURL)
        XCTAssertTrue(transcriptProvider.messages(in: TeamSwarmCoordinator.mainSessionID).isEmpty)

        try coordinator.sendMessage(
            to: agent.name,
            message: messageBody,
            messageType: "message",
            teamName: team.name,
            context: .init(sessionID: nil, senderMemberID: nil)
        )

        let transcriptMessages = transcriptProvider.messages(in: TeamSwarmCoordinator.mainSessionID)
        XCTAssertFalse(transcriptMessages.contains(where: {
            $0.role == .user && $0.textContent == "[\(TeamSwarmCoordinator.coordinatorName)] \(messageBody)"
        }))

        let snapshot = coordinator.snapshot(teamName: team.name, context: .init(sessionID: nil, senderMemberID: nil))
        let updatedMember = try XCTUnwrap(snapshot?.team.members.first)
        XCTAssertEqual(updatedMember.pendingPlanRequestID, "pending-plan")
        XCTAssertEqual(
            updatedMember.pendingExecutionPrompt,
            "Existing approved plan context\n\nAdditional message from coordinator: \(messageBody)"
        )
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
