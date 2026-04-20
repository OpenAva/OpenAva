import Foundation
import XCTest
@testable import OpenAva

final class TeamRuntimePersistenceTests: XCTestCase {
    private var originalStateData: Data?
    private var originalLLMCollection: AppConfig.LLMCollection?
    private var swarmRuntimeBackupURL: URL?

    @MainActor
    override func setUp() {
        super.setUp()
        originalStateData = try? Data(contentsOf: stateFileURL())
        originalLLMCollection = LLMConfigStore.loadCollection()
        LLMConfigStore.clearCollection()
        removeStateFile()
        backupSwarmRuntimeDirectory()
    }

    @MainActor
    override func tearDown() {
        TeamSwarmCoordinator.shared.configure(agentStoreRootURL: nil)
        TeamSwarmCoordinator.shared.reload()
        restoreSwarmRuntimeDirectory()
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
        let messageBody = "Please continue execution"

        let agent = try AgentStore.createAgent(
            name: agentName,
            emoji: "🧪",
            fileManager: .default
        )
        let peer = try AgentStore.createAgent(
            name: "Peer-\(UUID().uuidString)",
            emoji: "🧪",
            fileManager: .default
        )
        defer { _ = AgentStore.deleteAgent(agent.id, fileManager: .default) }
        defer { _ = AgentStore.deleteAgent(peer.id, fileManager: .default) }

        let teamDirectoryURL = try XCTUnwrap(swarmDirectoryURL())
        try FileManager.default.createDirectory(at: teamDirectoryURL, withIntermediateDirectories: true)

        let persistedTeam = TeamManifest(
            createdAt: Date(),
            updatedAt: Date(),
            coordinatorId: TeamSwarmCoordinator.coordinatorName,
            coordinatorSessionId: TeamSwarmCoordinator.mainSessionID,
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
                TeamManifestMember(
                    agentId: peer.id.uuidString,
                    agentType: SubAgentRegistry.generalPurpose.agentType,
                    input: nil,
                    planModeRequired: false,
                    sessionId: "\(peer.id.uuidString)::main",
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

        let transcriptProvider = TranscriptStorageProvider.provider(runtimeRootURL: transcriptRuntimeURL)
        XCTAssertTrue(transcriptProvider.messages(in: TeamSwarmCoordinator.mainSessionID).isEmpty)

        try coordinator.sendMessage(
            to: agent.name,
            message: messageBody,
            messageType: "message",
            context: .init(sessionID: nil, senderMemberID: nil)
        )

        let transcriptMessages = transcriptProvider.messages(in: TeamSwarmCoordinator.mainSessionID)
        XCTAssertTrue(transcriptMessages.isEmpty)

        let snapshot = coordinator.snapshot(context: .init(sessionID: nil, senderMemberID: nil))
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
        let messageBody = "Please stop after this check"

        let agent = try AgentStore.createAgent(
            name: agentName,
            emoji: "🧪",
            fileManager: .default
        )
        let peer = try AgentStore.createAgent(
            name: "Peer-\(UUID().uuidString)",
            emoji: "🧪",
            fileManager: .default
        )
        defer { _ = AgentStore.deleteAgent(agent.id, fileManager: .default) }
        defer { _ = AgentStore.deleteAgent(peer.id, fileManager: .default) }

        let teamDirectoryURL = try XCTUnwrap(swarmDirectoryURL())
        try FileManager.default.createDirectory(at: teamDirectoryURL, withIntermediateDirectories: true)

        let persistedTeam = TeamManifest(
            createdAt: Date(),
            updatedAt: Date(),
            coordinatorId: TeamSwarmCoordinator.coordinatorName,
            coordinatorSessionId: TeamSwarmCoordinator.mainSessionID,
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
                TeamManifestMember(
                    agentId: peer.id.uuidString,
                    agentType: SubAgentRegistry.generalPurpose.agentType,
                    input: nil,
                    planModeRequired: false,
                    sessionId: "\(peer.id.uuidString)::main",
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
            context: .init(sessionID: nil, senderMemberID: nil)
        )

        for _ in 0 ..< 20 {
            let status = coordinator.snapshot(context: .init(sessionID: nil, senderMemberID: nil))?
                .team.members.first?.status
            if status == .stopped {
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        let updatedMember = try XCTUnwrap(
            coordinator.snapshot(context: .init(sessionID: nil, senderMemberID: nil))?
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
            fileManager: .default,
            workspaceRootURL: transcriptRuntimeURL
        )
        let peer = try AgentStore.createAgent(
            name: "Peer-\(UUID().uuidString)",
            emoji: "🧪",
            fileManager: .default,
            workspaceRootURL: transcriptRuntimeURL
        )
        defer { _ = AgentStore.deleteAgent(agent.id, fileManager: .default, workspaceRootURL: transcriptRuntimeURL) }
        defer { _ = AgentStore.deleteAgent(peer.id, fileManager: .default, workspaceRootURL: transcriptRuntimeURL) }

        let agentStoreRootURL = transcriptRuntimeURL
        let coordinator = TeamSwarmCoordinator.shared
        coordinator.configure(
            agentStoreRootURL: agentStoreRootURL
        )
        coordinator.reload()

        let snapshot = coordinator.snapshot(context: .init(sessionID: "\(agent.id.uuidString)::main", senderMemberID: nil))

        XCTAssertEqual(Set(snapshot?.team.members.map(\.id) ?? []), Set([agent.id.uuidString, peer.id.uuidString]))
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
        let peer = try AgentStore.createAgent(
            name: "Peer-\(UUID().uuidString)",
            emoji: "🧪",
            fileManager: .default
        )
        defer {
            AgentMainSessionRegistry.shared.removeAll()
            ConversationSessionManager.shared.removeAllSessions()
            _ = AgentStore.deleteAgent(agent.id, fileManager: .default)
            _ = AgentStore.deleteAgent(peer.id, fileManager: .default)
        }
        let agentStoreRootURL = try AgentStore.workspaceRootDirectory(fileManager: .default)

        let teamDirectoryURL = try XCTUnwrap(swarmDirectoryURL())
        try FileManager.default.createDirectory(at: teamDirectoryURL, withIntermediateDirectories: true)

        let persistedTeam = TeamManifest(
            createdAt: Date(),
            updatedAt: Date(),
            coordinatorId: TeamSwarmCoordinator.coordinatorName,
            coordinatorSessionId: TeamSwarmCoordinator.mainSessionID,
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
                TeamManifestMember(
                    agentId: peer.id.uuidString,
                    agentType: SubAgentRegistry.generalPurpose.agentType,
                    input: nil,
                    planModeRequired: false,
                    sessionId: "\(peer.id.uuidString)::main",
                    mode: nil,
                    lastStatus: TeamSwarmCoordinator.MemberStatus.idle.rawValue,
                    pendingPlanRequestID: nil
                ),
            ]
        )
        let persistedData = try JSONEncoder().encode(persistedTeam)
        try persistedData.write(to: teamDirectoryURL.appendingPathComponent("config.json", isDirectory: false), options: [.atomic])

        let coordinator = TeamSwarmCoordinator.shared
        coordinator.configure(agentStoreRootURL: agentStoreRootURL)
        coordinator.reload()

        _ = try coordinator.approvePlan(
            sessionID: nil,
            memberName: agent.name,
            feedback: nil,
            context: .init(sessionID: nil, senderMemberID: nil)
        )

        let memberBeforeReconfigure = try XCTUnwrap(
            coordinator.snapshot(context: .init(sessionID: nil, senderMemberID: nil))?.team.members.first
        )
        XCTAssertEqual(memberBeforeReconfigure.status, .busy)
        XCTAssertFalse(memberBeforeReconfigure.awaitingPlanApproval)
        XCTAssertTrue(memberBeforeReconfigure.hasApprovedPlan)
        XCTAssertNil(memberBeforeReconfigure.pendingExecutionInput)

        coordinator.configure(agentStoreRootURL: agentStoreRootURL)

        let memberAfterReconfigure = try XCTUnwrap(
            coordinator.snapshot(context: .init(sessionID: nil, senderMemberID: nil))?.team.members.first
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

    @MainActor
    private func backupSwarmRuntimeDirectory() {
        guard let swarmDirectoryURL = swarmDirectoryURL() else { return }
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: swarmDirectoryURL.path) else {
            swarmRuntimeBackupURL = nil
            return
        }

        let backupURL = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? fileManager.copyItem(at: swarmDirectoryURL, to: backupURL)
        try? fileManager.removeItem(at: swarmDirectoryURL)
        swarmRuntimeBackupURL = backupURL
    }

    @MainActor
    private func restoreSwarmRuntimeDirectory() {
        guard let swarmDirectoryURL = swarmDirectoryURL() else { return }
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: swarmDirectoryURL)
        if let swarmRuntimeBackupURL {
            try? fileManager.copyItem(at: swarmRuntimeBackupURL, to: swarmDirectoryURL)
            try? fileManager.removeItem(at: swarmRuntimeBackupURL)
        }
        self.swarmRuntimeBackupURL = nil
    }

    @MainActor
    private func swarmDirectoryURL() -> URL? {
        TeamStore.runtimeDirectoryURL(fileManager: .default, createDirectoryIfNeeded: true)?
            .appendingPathComponent("swarm", isDirectory: true)
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
