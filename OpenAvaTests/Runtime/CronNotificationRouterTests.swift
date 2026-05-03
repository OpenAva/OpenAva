import Foundation
import OpenClawKit
import UserNotifications
import XCTest
@testable import OpenAva

final class CronNotificationRouterTests: XCTestCase {
    private var originalProjectData: Data?
    private var swarmStorageBackupURL: URL?
    private var removedCronJobIDs: [String] = []

    @MainActor
    override func setUp() {
        super.setUp()
        originalProjectData = try? Data(contentsOf: projectFileURL())
        removeProjectFile()
        backupSwarmStorageDirectory()
        removedCronJobIDs = []
        CronNotificationRouter.removeCronJob = { [weak self] jobID in
            self?.removedCronJobIDs.append(jobID)
        }
    }

    @MainActor
    override func tearDown() {
        CronNotificationRouter.removeCronJob = { jobID in
            _ = try? await CronService().remove(id: jobID)
        }
        TeamSwarmCoordinator.shared.configure(agentStoreRootURL: nil)
        TeamSwarmCoordinator.shared.reload()
        restoreSwarmStorageDirectory()
        restoreProjectFile()
        super.tearDown()
    }

    @MainActor
    func testNotifyCronWithAgentIDRoutesMessageIntoTeammateMailbox() async throws {
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

        let request = makeNotificationRequest(
            body: "Run the scheduled follow-up",
            kind: CronJobKind.notify,
            agentID: agent.id.uuidString,
            identifier: "cron.test.notify"
        )

        let handled = await CronNotificationRouter.handle(request: request, deliveredAt: Date())

        XCTAssertTrue(handled)

        let mailboxMessages = TeamMailbox.readMessages(teamDirectoryURL: teamDirectoryURL, recipientName: agent.name)
        XCTAssertEqual(mailboxMessages.count, 1)
        XCTAssertEqual(mailboxMessages.first?.from, TeamSwarmCoordinator.coordinatorName)
        XCTAssertEqual(mailboxMessages.first?.messageType, "scheduled_message")
        XCTAssertEqual(mailboxMessages.first?.text, "Message from coordinator:\nRun the scheduled follow-up")

        let updatedMember = try XCTUnwrap(
            coordinator.snapshot(context: .init(sessionID: nil, senderMemberID: nil))?
                .team.members.first(where: { $0.id == agent.id.uuidString })
        )
        XCTAssertEqual(updatedMember.status, .busy)
    }

    @MainActor
    func testNotifyCronWithoutAgentIDFallsBackToSystemNotificationHandling() async {
        let request = makeNotificationRequest(
            body: "General reminder",
            kind: CronJobKind.notify,
            agentID: nil,
            identifier: "cron.test.no-agent"
        )

        let handled = await CronNotificationRouter.handle(request: request, deliveredAt: Date())

        XCTAssertFalse(handled)
    }

    @MainActor
    func testRecurringNotifyCronRemovesOrphanedTeammateJob() async {
        let request = makeNotificationRequest(
            body: "Recurring follow-up",
            kind: CronJobKind.notify,
            agentID: UUID().uuidString,
            identifier: "cron.test.orphan.every",
            schedule: "every"
        )

        let handled = await CronNotificationRouter.handle(request: request, deliveredAt: Date())

        XCTAssertFalse(handled)
        XCTAssertEqual(removedCronJobIDs, ["cron.test.orphan.every"])
    }

    @MainActor
    func testOneShotNotifyCronDoesNotRemoveMissingTeammateJob() async {
        let request = makeNotificationRequest(
            body: "One-shot follow-up",
            kind: CronJobKind.notify,
            agentID: UUID().uuidString,
            identifier: "cron.test.orphan.at",
            schedule: "at"
        )

        let handled = await CronNotificationRouter.handle(request: request, deliveredAt: Date())

        XCTAssertFalse(handled)
        XCTAssertTrue(removedCronJobIDs.isEmpty)
    }

    private func makeNotificationRequest(
        body: String,
        kind: CronJobKind,
        agentID: String?,
        identifier: String,
        schedule: String = "every"
    ) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = "OpenAva"
        content.body = body
        content.userInfo = [
            CronNotificationMetadataKey.marker: true,
            CronNotificationMetadataKey.name: "Test",
            CronNotificationMetadataKey.kind: kind.rawValue,
            CronNotificationMetadataKey.agentID: agentID ?? "",
            CronNotificationMetadataKey.schedule: schedule,
            CronNotificationMetadataKey.at: "",
            CronNotificationMetadataKey.everySeconds: 60,
            CronNotificationMetadataKey.createdAt: ISO8601DateFormatter().string(from: Date()),
        ]

        return UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
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
