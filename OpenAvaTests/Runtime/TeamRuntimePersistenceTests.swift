import Foundation
import XCTest
@testable import OpenAva

final class TeamRuntimePersistenceTests: XCTestCase {
    private var originalStateData: Data?
    private var originalLLMCollection: AppConfig.LLMCollection?

    override func setUp() {
        super.setUp()
        originalStateData = try? Data(contentsOf: stateFileURL())
        originalLLMCollection = LLMConfigStore.loadCollection()
        LLMConfigStore.clearCollection()
        removeStateFile()
    }

    override func tearDown() {
        restoreStateFile()
        if let originalLLMCollection {
            LLMConfigStore.saveCollection(originalLLMCollection)
        } else {
            LLMConfigStore.clearCollection()
        }
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

        XCTAssertEqual(TeamMailbox.unreadMessages(teamDirectoryURL: teamDirectoryURL, recipientName: "worker").count, 1)

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
        XCTAssertTrue(FileManager.default.fileExists(atPath: stateFileURL().path))

        let rawContent = try String(contentsOf: stateFileURL(), encoding: .utf8)
        XCTAssertTrue(rawContent.contains("Default Team"))

        _ = try TeamStore.addAgents([firstAgentID, secondAgentID, firstAgentID], to: XCTUnwrap(created?.id))
        XCTAssertEqual(TeamStore.load().teams.first?.agentPoolIDs, [firstAgentID, secondAgentID])

        _ = try TeamStore.removeAgent(firstAgentID, from: XCTUnwrap(created?.id))

        let remaining = TeamStore.load().teams.first
        XCTAssertEqual(remaining?.agentPoolIDs, [secondAgentID])
    }

    func testTeamStoreUsesTeamsWorkspaceDirectory() throws {
        let storageURL = try XCTUnwrap(TeamStore.storageDirectoryURL(fileManager: .default, createDirectoryIfNeeded: false))
        let runtimeURL = try XCTUnwrap(TeamStore.runtimeDirectoryURL(fileManager: .default, createDirectoryIfNeeded: false))

        XCTAssertEqual(storageURL.lastPathComponent, "teams")
        XCTAssertEqual(runtimeURL.deletingLastPathComponent().path, storageURL.path)
        XCTAssertEqual(runtimeURL.lastPathComponent, ".runtime")
    }

    @MainActor
    func testSendMessageToTeamMemberDoesNotAppendUserTranscriptEntry() throws {
        let transcriptRuntimeURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: transcriptRuntimeURL, withIntermediateDirectories: true)
        TranscriptStorageProvider.removeProvider(runtimeRootURL: transcriptRuntimeURL)
        defer {
            TranscriptStorageProvider.removeProvider(runtimeRootURL: transcriptRuntimeURL)
            try? FileManager.default.removeItem(at: transcriptRuntimeURL)
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

        let persistedTeam = TeamManifest(
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
                TeamManifestMember(
                    agentId: agent.id.uuidString,
                    agentType: SubAgentRegistry.generalPurpose.agentType,
                    input: "Existing approved plan context",
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
        coordinator.configure(agentStoreRootURL: nil)
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
        XCTAssertTrue(transcriptMessages.isEmpty)

        let snapshot = coordinator.snapshot(teamName: team.name, context: .init(sessionID: nil, senderMemberID: nil))
        let updatedMember = try XCTUnwrap(snapshot?.team.members.first)
        XCTAssertEqual(updatedMember.pendingPlanRequestID, "pending-plan")
        XCTAssertEqual(
            updatedMember.pendingExecutionInput,
            "Existing approved plan context\n\nAdditional message from coordinator: \(messageBody)"
        )
    }

    @MainActor
    func testDirectTeamMessageStoredForMemberIncludesSenderName() async throws {
        let transcriptRuntimeURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: transcriptRuntimeURL, withIntermediateDirectories: true)
        TranscriptStorageProvider.removeProvider(runtimeRootURL: transcriptRuntimeURL)
        defer {
            TranscriptStorageProvider.removeProvider(runtimeRootURL: transcriptRuntimeURL)
            try? FileManager.default.removeItem(at: transcriptRuntimeURL)
        }

        let agentName = "Worker-\(UUID().uuidString)"
        let teamName = "Team-\(UUID().uuidString)"
        let messageBody = "Please stop after this check"

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

        let persistedTeam = TeamManifest(
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
                TeamManifestMember(
                    agentId: agent.id.uuidString,
                    agentType: SubAgentRegistry.generalPurpose.agentType,
                    input: nil,
                    planModeRequired: false,
                    sessionId: "\(agent.id.uuidString)::main",
                    mode: nil,
                    lastStatus: TeamSwarmCoordinator.MemberStatus.idle.rawValue,
                    pendingPlanRequestID: nil
                ),
            ]
        )
        let persistedData = try JSONEncoder().encode(persistedTeam)
        try persistedData.write(to: teamDirectoryURL.appendingPathComponent("config.json", isDirectory: false), options: [.atomic])

        let coordinator = TeamSwarmCoordinator.shared
        coordinator.configure(agentStoreRootURL: nil)
        coordinator.reload()

        try coordinator.sendMessage(
            to: agent.name,
            message: messageBody,
            messageType: "shutdown_request",
            teamName: team.name,
            context: .init(sessionID: nil, senderMemberID: nil)
        )

        for _ in 0 ..< 20 {
            let status = coordinator.snapshot(teamName: team.name, context: .init(sessionID: nil, senderMemberID: nil))?
                .team.members.first?.status
            if status == .stopped {
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        let updatedMember = try XCTUnwrap(
            coordinator.snapshot(teamName: team.name, context: .init(sessionID: nil, senderMemberID: nil))?
                .team.members.first
        )
        XCTAssertEqual(updatedMember.status, .stopped)

        let mailboxMessages = TeamMailbox.readMessages(teamDirectoryURL: teamDirectoryURL, recipientName: agent.name)
        XCTAssertEqual(mailboxMessages.count, 1)
        XCTAssertEqual(mailboxMessages.first?.from, TeamSwarmCoordinator.coordinatorName)
        XCTAssertEqual(mailboxMessages.first?.text, "Message from coordinator:\n\(messageBody)")
    }

    @MainActor
    func testCoordinatorUsesExplicitAgentStoreRootForTeamLoading() throws {
        let transcriptRuntimeURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: transcriptRuntimeURL, withIntermediateDirectories: true)
        TranscriptStorageProvider.removeProvider(runtimeRootURL: transcriptRuntimeURL)

        defer {
            TranscriptStorageProvider.removeProvider(runtimeRootURL: transcriptRuntimeURL)
            try? FileManager.default.removeItem(at: transcriptRuntimeURL)
        }

        let agent = try AgentStore.createAgent(
            name: "Worker-\(UUID().uuidString)",
            emoji: "🧪",
            fileManager: .default
        )
        defer { _ = AgentStore.deleteAgent(agent.id, fileManager: .default) }

        let team = try XCTUnwrap(TeamStore.createTeam(name: "Team-\(UUID().uuidString)", emoji: "👥", fileManager: .default))
        defer { TeamStore.deleteTeam(team.id, fileManager: .default) }
        _ = try XCTUnwrap(TeamStore.addAgents([agent.id], to: team.id, fileManager: .default))

        let agentStoreRootURL = try AgentStore.workspaceRootDirectory(fileManager: .default)
        let coordinator = TeamSwarmCoordinator.shared
        coordinator.configure(
            agentStoreRootURL: agentStoreRootURL
        )
        coordinator.reload()

        let snapshot = coordinator.snapshot(
            teamName: nil,
            context: .init(sessionID: "\(agent.id.uuidString)::main", senderMemberID: nil)
        )

        XCTAssertEqual(snapshot?.team.name, team.name)
        XCTAssertEqual(snapshot?.team.members.map(\.id), [agent.id.uuidString])
    }

    @MainActor
    func testConfigureWithDifferentRuntimeRootPreservesInMemoryTeamState() throws {
        let firstRuntimeURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let secondRuntimeURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: firstRuntimeURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondRuntimeURL, withIntermediateDirectories: true)
        TranscriptStorageProvider.removeProvider(runtimeRootURL: firstRuntimeURL)
        TranscriptStorageProvider.removeProvider(runtimeRootURL: secondRuntimeURL)
        defer {
            TranscriptStorageProvider.removeProvider(runtimeRootURL: firstRuntimeURL)
            TranscriptStorageProvider.removeProvider(runtimeRootURL: secondRuntimeURL)
            try? FileManager.default.removeItem(at: firstRuntimeURL)
            try? FileManager.default.removeItem(at: secondRuntimeURL)
        }

        let agent = try AgentStore.createAgent(
            name: "Worker-\(UUID().uuidString)",
            emoji: "🧪",
            fileManager: .default
        )
        defer {
            AgentMainSessionRegistry.shared.removeAll()
            ConversationSessionManager.shared.removeAllSessions()
            _ = AgentStore.deleteAgent(agent.id, fileManager: .default)
        }

        let team = try XCTUnwrap(TeamStore.createTeam(name: "Team-\(UUID().uuidString)", emoji: "👥", fileManager: .default))
        defer { TeamStore.deleteTeam(team.id, fileManager: .default) }
        _ = try XCTUnwrap(TeamStore.addAgents([agent.id], to: team.id, fileManager: .default))
        let agentStoreRootURL = try AgentStore.workspaceRootDirectory(fileManager: .default)

        let teamRuntimeRoot = try XCTUnwrap(TeamStore.runtimeDirectoryURL(fileManager: .default, createDirectoryIfNeeded: true))
        let teamDirectoryURL = teamRuntimeRoot.appendingPathComponent(team.name, isDirectory: true)
        try FileManager.default.createDirectory(at: teamDirectoryURL, withIntermediateDirectories: true)

        let persistedTeam = TeamManifest(
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
                TeamManifestMember(
                    agentId: agent.id.uuidString,
                    agentType: SubAgentRegistry.generalPurpose.agentType,
                    input: nil,
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
        coordinator.configure(agentStoreRootURL: agentStoreRootURL)
        coordinator.reload()

        try coordinator.approvePlan(
            sessionID: nil,
            memberName: agent.name,
            teamName: team.name,
            feedback: nil,
            context: .init(sessionID: nil, senderMemberID: nil)
        )

        let memberBeforeReconfigure = try XCTUnwrap(
            coordinator.snapshot(teamName: team.name, context: .init(sessionID: nil, senderMemberID: nil))?.team.members.first
        )
        XCTAssertEqual(memberBeforeReconfigure.status, .busy)
        XCTAssertFalse(memberBeforeReconfigure.awaitingPlanApproval)
        XCTAssertTrue(memberBeforeReconfigure.hasApprovedPlan)
        XCTAssertNil(memberBeforeReconfigure.pendingExecutionInput)

        coordinator.configure(agentStoreRootURL: agentStoreRootURL)

        let memberAfterReconfigure = try XCTUnwrap(
            coordinator.snapshot(teamName: team.name, context: .init(sessionID: nil, senderMemberID: nil))?.team.members.first
        )
        XCTAssertEqual(memberAfterReconfigure.status, .busy)
        XCTAssertFalse(memberAfterReconfigure.awaitingPlanApproval)
        XCTAssertTrue(memberAfterReconfigure.hasApprovedPlan)
        XCTAssertNil(memberAfterReconfigure.pendingExecutionInput)
    }

    func testTeamMutationsPreserveAgentStateInUnifiedFile() throws {
        let agent = try AgentStore.createAgent(
            name: "Worker-\(UUID().uuidString)",
            emoji: "🧪",
            fileManager: .default
        )
        defer { _ = AgentStore.deleteAgent(agent.id, fileManager: .default) }

        _ = TeamStore.createTeam(name: "Team-\(UUID().uuidString)", emoji: "👥", fileManager: .default)

        let snapshot = AgentStore.load(fileManager: .default)
        XCTAssertEqual(snapshot.activeAgent?.id, agent.id)
        XCTAssertTrue(snapshot.agents.contains(where: { $0.id == agent.id }))
    }

    private func makeTemporaryTeamDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func removeStateFile() {
        try? FileManager.default.removeItem(at: stateFileURL())
    }

    private func restoreStateFile() {
        let url = stateFileURL()
        if let originalStateData {
            try? originalStateData.write(to: url, options: [.atomic])
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func stateFileURL() -> URL {
        let rootURL = try? AgentStore.workspaceRootDirectory(fileManager: .default)
        return rootURL?.appendingPathComponent(".openava.json", isDirectory: false)
            ?? FileManager.default.temporaryDirectory.appendingPathComponent(".openava.json", isDirectory: false)
    }
}
