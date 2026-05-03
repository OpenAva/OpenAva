import Foundation
import XCTest
@testable import OpenAva

final class TeamRuntimePersistenceTests: XCTestCase {
    private var originalProjectData: Data?
    private var originalLLMCollection: AppConfig.LLMCollection?
    private var swarmStorageBackupURL: URL?

    @MainActor
    override func setUp() {
        super.setUp()
        originalProjectData = try? Data(contentsOf: projectFileURL())
        originalLLMCollection = LLMConfigStore.loadCollection()
        LLMConfigStore.clearCollection()
        removeProjectFile()
        backupSwarmStorageDirectory()
    }

    @MainActor
    override func tearDown() {
        TeamSwarmCoordinator.shared.configure(agentStoreRootURL: nil)
        TeamSwarmCoordinator.shared.reload()
        restoreSwarmStorageDirectory()
        restoreProjectFile()
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
        XCTAssertTrue(FileManager.default.fileExists(atPath: projectFileURL().path))

        let rawContent = try String(contentsOf: projectFileURL(), encoding: .utf8)
        XCTAssertTrue(rawContent.contains("Default Team"))

        _ = try TeamStore.addAgents([firstAgentID, secondAgentID, firstAgentID], to: XCTUnwrap(created?.id))
        XCTAssertEqual(TeamStore.load().teams.first?.agentPoolIDs, [firstAgentID, secondAgentID])

        _ = try TeamStore.removeAgent(firstAgentID, from: XCTUnwrap(created?.id))

        let remaining = TeamStore.load().teams.first
        XCTAssertEqual(remaining?.agentPoolIDs, [secondAgentID])
    }

    func testTeamStoreUsesTeamsWorkspaceDirectory() throws {
        let storageURL = try XCTUnwrap(TeamStore.storageDirectoryURL(fileManager: .default, createDirectoryIfNeeded: false))
        let supportURL = try XCTUnwrap(TeamStore.storageDirectoryURL(fileManager: .default, createDirectoryIfNeeded: false))

        XCTAssertEqual(storageURL.lastPathComponent, "teams")
        XCTAssertEqual(supportURL.path, storageURL.path)
    }

    @MainActor
    func testSendMessageToTeamMemberDoesNotAppendUserTranscriptEntry() throws {
        let transcriptSupportURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: transcriptSupportURL, withIntermediateDirectories: true)
        TranscriptStorageProvider.removeProvider(supportRootURL: transcriptSupportURL)
        defer {
            TranscriptStorageProvider.removeProvider(supportRootURL: transcriptSupportURL)
            try? FileManager.default.removeItem(at: transcriptSupportURL)
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

        let transcriptProvider = TranscriptStorageProvider.provider(supportRootURL: transcriptSupportURL)
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
        let transcriptSupportURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: transcriptSupportURL, withIntermediateDirectories: true)
        TranscriptStorageProvider.removeProvider(supportRootURL: transcriptSupportURL)
        defer {
            TranscriptStorageProvider.removeProvider(supportRootURL: transcriptSupportURL)
            try? FileManager.default.removeItem(at: transcriptSupportURL)
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
        let transcriptSupportURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: transcriptSupportURL, withIntermediateDirectories: true)
        TranscriptStorageProvider.removeProvider(supportRootURL: transcriptSupportURL)

        defer {
            TranscriptStorageProvider.removeProvider(supportRootURL: transcriptSupportURL)
            try? FileManager.default.removeItem(at: transcriptSupportURL)
        }

        let agent = try AgentStore.createAgent(
            name: "Worker-\(UUID().uuidString)",
            emoji: "🧪",
            fileManager: .default,
            workspaceRootURL: transcriptSupportURL
        )
        let peer = try AgentStore.createAgent(
            name: "Peer-\(UUID().uuidString)",
            emoji: "🧪",
            fileManager: .default,
            workspaceRootURL: transcriptSupportURL
        )
        defer { _ = AgentStore.deleteAgent(agent.id, fileManager: .default, workspaceRootURL: transcriptSupportURL) }
        defer { _ = AgentStore.deleteAgent(peer.id, fileManager: .default, workspaceRootURL: transcriptSupportURL) }

        let agentStoreRootURL = transcriptSupportURL
        let coordinator = TeamSwarmCoordinator.shared
        coordinator.configure(
            agentStoreRootURL: agentStoreRootURL
        )
        coordinator.reload()

        let snapshot = coordinator.snapshot(context: .init(sessionID: "\(agent.id.uuidString)::main", senderMemberID: nil))

        XCTAssertEqual(Set(snapshot?.team.members.map(\.id) ?? []), Set([agent.id.uuidString, peer.id.uuidString]))
    }

    @MainActor
    func testConfigureWithDifferentSupportRootPreservesInMemoryTeamState() throws {
        let firstSupportURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let secondSupportURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: firstSupportURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondSupportURL, withIntermediateDirectories: true)
        TranscriptStorageProvider.removeProvider(supportRootURL: firstSupportURL)
        TranscriptStorageProvider.removeProvider(supportRootURL: secondSupportURL)
        defer {
            TranscriptStorageProvider.removeProvider(supportRootURL: firstSupportURL)
            TranscriptStorageProvider.removeProvider(supportRootURL: secondSupportURL)
            try? FileManager.default.removeItem(at: firstSupportURL)
            try? FileManager.default.removeItem(at: secondSupportURL)
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

    @MainActor
    func testUpdateTaskAutoAssignsOwnerWhenTeammateStartsWork() throws {
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
            nextTaskID: 2,
            tasks: [
                TeamSwarmCoordinator.TeamTask(
                    id: 1,
                    title: "Investigate failing test",
                    detail: nil,
                    status: .pending,
                    owner: nil,
                    createdAt: Date(),
                    updatedAt: Date()
                ),
            ],
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

        let updated = try coordinator.updateTask(
            id: 1,
            title: nil,
            detail: nil,
            status: .inProgress,
            owner: nil,
            context: .init(sessionID: "\(agent.id.uuidString)::main", senderMemberID: agent.id.uuidString)
        )

        XCTAssertEqual(updated.status, .inProgress)
        XCTAssertEqual(updated.owner, agent.name)
    }

    @MainActor
    func testUpdateTaskDoesNotOverrideExplicitOwnerWhenTeammateStartsWork() throws {
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
            nextTaskID: 2,
            tasks: [
                TeamSwarmCoordinator.TeamTask(
                    id: 1,
                    title: "Investigate failing test",
                    detail: nil,
                    status: .pending,
                    owner: nil,
                    createdAt: Date(),
                    updatedAt: Date()
                ),
            ],
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

        let updated = try coordinator.updateTask(
            id: 1,
            title: nil,
            detail: nil,
            status: .inProgress,
            owner: peer.name,
            context: .init(sessionID: "\(agent.id.uuidString)::main", senderMemberID: agent.id.uuidString)
        )

        XCTAssertEqual(updated.status, .inProgress)
        XCTAssertEqual(updated.owner, peer.name)
    }

    @MainActor
    func testFinishMemberIdleCompletesOwnedInProgressTasks() throws {
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
            nextTaskID: 4,
            tasks: [
                TeamSwarmCoordinator.TeamTask(
                    id: 1,
                    title: "Owned active task",
                    detail: nil,
                    status: .inProgress,
                    owner: agent.name,
                    createdAt: Date(),
                    updatedAt: Date(timeIntervalSince1970: 1)
                ),
                TeamSwarmCoordinator.TeamTask(
                    id: 2,
                    title: "Peer active task",
                    detail: nil,
                    status: .inProgress,
                    owner: peer.name,
                    createdAt: Date(),
                    updatedAt: Date(timeIntervalSince1970: 1)
                ),
                TeamSwarmCoordinator.TeamTask(
                    id: 3,
                    title: "Owned blocked task",
                    detail: nil,
                    status: .blocked,
                    owner: agent.name,
                    createdAt: Date(),
                    updatedAt: Date(timeIntervalSince1970: 1)
                ),
            ],
            members: [
                TeamManifestMember(
                    agentId: agent.id.uuidString,
                    agentType: SubAgentRegistry.generalPurpose.agentType,
                    input: nil,
                    planModeRequired: false,
                    sessionId: "\(agent.id.uuidString)::main",
                    mode: nil,
                    lastStatus: TeamSwarmCoordinator.MemberStatus.busy.rawValue,
                    pendingPlanRequestID: nil
                ),
                TeamManifestMember(
                    agentId: peer.id.uuidString,
                    agentType: SubAgentRegistry.generalPurpose.agentType,
                    input: nil,
                    planModeRequired: false,
                    sessionId: "\(peer.id.uuidString)::main",
                    mode: nil,
                    lastStatus: TeamSwarmCoordinator.MemberStatus.busy.rawValue,
                    pendingPlanRequestID: nil
                ),
            ]
        )
        let persistedData = try JSONEncoder().encode(persistedTeam)
        try persistedData.write(to: teamDirectoryURL.appendingPathComponent("config.json", isDirectory: false), options: [.atomic])

        let coordinator = TeamSwarmCoordinator.shared
        coordinator.configure(agentStoreRootURL: nil)
        coordinator.reload()

        let finished = try coordinator.test_finishMember(
            memberID: agent.id.uuidString,
            status: .idle,
            result: "Done.",
            error: nil
        )

        XCTAssertEqual(finished.member.status, .idle)
        XCTAssertEqual(finished.member.lastIdleSummary, "Done.")
        XCTAssertEqual(finished.tasksByID[1]?.status, .completed)
        XCTAssertEqual(finished.tasksByID[2]?.status, .inProgress)
        XCTAssertEqual(finished.tasksByID[3]?.status, .blocked)

        let coordinatorMessages = TeamMailbox.readMessages(
            teamDirectoryURL: teamDirectoryURL,
            recipientName: TeamSwarmCoordinator.coordinatorName
        )
        XCTAssertEqual(coordinatorMessages.count, 1)
        XCTAssertEqual(coordinatorMessages.first?.from, agent.name)
        XCTAssertEqual(coordinatorMessages.first?.messageType, "teammate_idle")
        XCTAssertEqual(coordinatorMessages.first?.summary, "Done.")
        XCTAssertEqual(
            coordinatorMessages.first?.text,
            "Teammate \(agent.name) is now idle.\nSummary: Done."
        )
    }

    @MainActor
    func testFinishMemberFailedDoesNotCompleteOwnedInProgressTasks() throws {
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
            nextTaskID: 2,
            tasks: [
                TeamSwarmCoordinator.TeamTask(
                    id: 1,
                    title: "Owned active task",
                    detail: nil,
                    status: .inProgress,
                    owner: agent.name,
                    createdAt: Date(),
                    updatedAt: Date(timeIntervalSince1970: 1)
                ),
            ],
            members: [
                TeamManifestMember(
                    agentId: agent.id.uuidString,
                    agentType: SubAgentRegistry.generalPurpose.agentType,
                    input: nil,
                    planModeRequired: false,
                    sessionId: "\(agent.id.uuidString)::main",
                    mode: nil,
                    lastStatus: TeamSwarmCoordinator.MemberStatus.busy.rawValue,
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

        let finished = try coordinator.test_finishMember(
            memberID: agent.id.uuidString,
            status: .failed,
            result: nil,
            error: "boom"
        )

        XCTAssertEqual(finished.member.status, .failed)
        XCTAssertEqual(finished.tasksByID[1]?.status, .inProgress)

        let coordinatorMessages = TeamMailbox.readMessages(
            teamDirectoryURL: teamDirectoryURL,
            recipientName: TeamSwarmCoordinator.coordinatorName
        )
        XCTAssertTrue(coordinatorMessages.isEmpty)
    }

    @MainActor
    func testUpdateTaskAddBlockedByMarksTaskBlockedAndCompletingDependencyUnblocksIt() throws {
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
            nextTaskID: 3,
            tasks: [
                TeamSwarmCoordinator.TeamTask(
                    id: 1,
                    title: "Implement API",
                    detail: nil,
                    status: .pending,
                    owner: nil,
                    blockedBy: [],
                    createdAt: Date(),
                    updatedAt: Date(timeIntervalSince1970: 1)
                ),
                TeamSwarmCoordinator.TeamTask(
                    id: 2,
                    title: "Wire UI",
                    detail: nil,
                    status: .pending,
                    owner: nil,
                    blockedBy: [],
                    createdAt: Date(),
                    updatedAt: Date(timeIntervalSince1970: 1)
                ),
            ],
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

        let blockedTask = try coordinator.updateTask(
            id: 2,
            title: nil,
            detail: nil,
            status: nil,
            owner: nil,
            addBlockedBy: [1],
            context: .init(sessionID: nil, senderMemberID: nil)
        )

        XCTAssertEqual(blockedTask.status, .blocked)
        XCTAssertEqual(blockedTask.blockedBy, [1])

        let completedDependency = try coordinator.updateTask(
            id: 1,
            title: nil,
            detail: nil,
            status: .completed,
            owner: nil,
            context: .init(sessionID: nil, senderMemberID: nil)
        )

        XCTAssertEqual(completedDependency.status, .completed)

        let unblockedTask = try coordinator.getTask(id: 2, context: .init(sessionID: nil, senderMemberID: nil))
        XCTAssertEqual(unblockedTask.status, .pending)
        XCTAssertTrue(unblockedTask.blockedBy.isEmpty)
    }

    private func makeTemporaryTeamDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @MainActor
    private func backupSwarmStorageDirectory() {
        guard let swarmDirectoryURL = swarmDirectoryURL() else { return }
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: swarmDirectoryURL.path) else {
            swarmStorageBackupURL = nil
            return
        }

        let backupURL = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? fileManager.copyItem(at: swarmDirectoryURL, to: backupURL)
        try? fileManager.removeItem(at: swarmDirectoryURL)
        swarmStorageBackupURL = backupURL
    }

    @MainActor
    private func restoreSwarmStorageDirectory() {
        guard let swarmDirectoryURL = swarmDirectoryURL() else { return }
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: swarmDirectoryURL)
        if let swarmStorageBackupURL {
            try? fileManager.copyItem(at: swarmStorageBackupURL, to: swarmDirectoryURL)
            try? fileManager.removeItem(at: swarmStorageBackupURL)
        }
        self.swarmStorageBackupURL = nil
    }

    @MainActor
    private func swarmDirectoryURL() -> URL? {
        TeamStore.storageDirectoryURL(fileManager: .default, createDirectoryIfNeeded: true)
    }

    private func removeProjectFile() {
        try? FileManager.default.removeItem(at: projectFileURL())
    }

    private func restoreProjectFile() {
        let url = projectFileURL()
        if let originalProjectData {
            try? originalProjectData.write(to: url, options: [.atomic])
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func projectFileURL() -> URL {
        let rootURL = try? AgentStore.workspaceRootDirectory(fileManager: .default)
        if let rootURL, let fileURL = OpenAvaProjectFile.fileURL(workspaceRootURL: rootURL) {
            return fileURL
        }
        let fallbackRootURL = FileManager.default.temporaryDirectory.appendingPathComponent("OpenAva", isDirectory: true)
        return AgentStore.supportDirectoryURL(workspaceRootURL: fallbackRootURL)
            .appendingPathComponent("project.json", isDirectory: false)
    }
}
