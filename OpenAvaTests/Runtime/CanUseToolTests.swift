import ChatClient
import XCTest
@testable import OpenAva

@MainActor
final class CanUseToolTests: XCTestCase {
    func testDefaultToolPermissionPolicyAllowsReadOnlyTools() async {
        let decision = await defaultToolPermissionPolicy(
            ToolRequest(id: "tool-read", name: "fs_read", arguments: "{}"),
            makeTool(functionName: "fs_read", isReadOnly: true),
            makeContext()
        )

        XCTAssertEqual(decision.behavior, .allow)
        XCTAssertEqual(decision.reason, "read_only_tool")
        XCTAssertNil(decision.message)
    }

    func testDefaultToolPermissionPolicyAsksForAbsoluteReadPathOutsideAllowedRoots() async {
        let decision = await defaultToolPermissionPolicy(
            ToolRequest(id: "tool-read-absolute", name: "fs_read", arguments: #"{"path":"/tmp/outside.txt"}"#),
            makeTool(functionName: "fs_read", isReadOnly: true, permissionProfile: .read),
            makeContext(toolProvider: PermissionScopeToolProvider(
                workspaceRootURL: URL(fileURLWithPath: "/workspace"),
                readableRootURLs: [URL(fileURLWithPath: "/workspace")]
            ))
        )

        XCTAssertEqual(decision.behavior, .ask)
        XCTAssertEqual(decision.reason, "absolute_read_path_requires_approval")
        XCTAssertEqual(decision.message, "Tool execution requires approval because it reads an absolute path outside the allowed working directories.")
    }

    func testDefaultToolPermissionPolicyDeniesAbsoluteReadPathAfterRememberedRejection() async {
        let session = ConversationSession(
            id: UUID().uuidString,
            configuration: .init(storage: DisposableStorageProvider())
        )
        session.addSessionToolPermissionRule(
            ToolPermissionRule(
                behavior: .deny,
                toolName: "fs_read",
                matcher: .pathPrefix("/tmp")
            )
        )

        let decision = await defaultToolPermissionPolicy(
            ToolRequest(id: "tool-read-denied", name: "fs_read", arguments: #"{"path":"/tmp/outside.txt"}"#),
            makeTool(functionName: "fs_read", isReadOnly: true, permissionProfile: .read),
            makeContext(
                session: session,
                toolProvider: PermissionScopeToolProvider(
                    workspaceRootURL: URL(fileURLWithPath: "/workspace"),
                    readableRootURLs: [URL(fileURLWithPath: "/workspace")]
                )
            )
        )

        XCTAssertEqual(decision.behavior, .deny)
        XCTAssertEqual(decision.reason, "permission_rule_deny_session")
    }

    func testDefaultToolPermissionPolicyAllowsTeamStatus() async throws {
        let definitions = TeamTools().toolDefinitions()
        let teamStatus = try XCTUnwrap(definitions.first { $0.functionName == "team_status" })

        let decision = await defaultToolPermissionPolicy(
            ToolRequest(id: "tool-team-status", name: "team_status", arguments: "{}"),
            teamStatus,
            makeContext()
        )

        XCTAssertEqual(decision.behavior, .allow)
        XCTAssertEqual(decision.reason, "read_only_tool")
        XCTAssertNil(decision.message)
    }

    func testDefaultToolPermissionPolicyAllowsTeamMutationTools() async throws {
        let definitions = TeamTools().toolDefinitions()
        let expectedReasons = [
            "team_message_send": "internal_communication",
            "team_plan_approve": "plan_approval",
            "team_task_create": "task_update",
            "team_task_update": "task_update",
        ]

        for (toolName, expectedReason) in expectedReasons {
            let tool = try XCTUnwrap(definitions.first { $0.functionName == toolName })
            let decision = await defaultToolPermissionPolicy(
                ToolRequest(id: "tool-\(toolName)", name: toolName, arguments: "{}"),
                tool,
                makeContext()
            )

            XCTAssertEqual(decision.behavior, .allow, toolName)
            XCTAssertEqual(decision.reason, expectedReason, toolName)
            XCTAssertNil(decision.message, toolName)
        }
    }

    func testDefaultToolPermissionPolicyAsksBeforeTeamShutdownMessage() async throws {
        let definitions = TeamTools().toolDefinitions()
        let teamMessageSend = try XCTUnwrap(definitions.first { $0.functionName == "team_message_send" })

        let decision = await defaultToolPermissionPolicy(
            ToolRequest(
                id: "tool-team-shutdown",
                name: "team_message_send",
                arguments: #"{"to":"researcher","message":"stop","message_type":"shutdown_request"}"#
            ),
            teamMessageSend,
            makeContext()
        )

        XCTAssertEqual(decision.behavior, .ask)
        XCTAssertEqual(decision.reason, "team_shutdown_requires_approval")
        XCTAssertEqual(decision.message, "Stopping another agent needs your approval.")
    }

    func testDefaultToolPermissionPolicyAllowsTodoWriteWithoutPrompt() async throws {
        let tool = try XCTUnwrap(SessionTodoTools().toolDefinitions().first { $0.functionName == "todo_write" })

        let decision = await defaultToolPermissionPolicy(
            ToolRequest(id: "tool-todo", name: "todo_write", arguments: #"{"todos":[]}"#),
            tool,
            makeContext()
        )

        XCTAssertEqual(decision.behavior, .allow)
        XCTAssertEqual(decision.reason, "internal_state_update")
        XCTAssertNil(decision.message)
    }

    func testDefaultToolPermissionPolicyAsksForDestructiveTools() async {
        let decision = await defaultToolPermissionPolicy(
            ToolRequest(id: "tool-write", name: "fs_write", arguments: "{}"),
            makeTool(functionName: "fs_write", isDestructive: true),
            makeContext()
        )

        XCTAssertEqual(decision.behavior, .ask)
        XCTAssertEqual(decision.reason, "destructive_tool_requires_approval")
        XCTAssertEqual(decision.message, "Tool execution requires approval because this tool can modify or delete data.")
    }

    func testDefaultToolPermissionPolicyAllowsWorkspaceRelativeFileEdits() async {
        let decision = await defaultToolPermissionPolicy(
            ToolRequest(id: "tool-write-relative", name: "fs_write", arguments: #"{"path":"Sources/App.swift","content":"x"}"#),
            makeTool(functionName: "fs_write", permissionProfile: .localMutation, isDestructive: true),
            makeContext()
        )

        XCTAssertEqual(decision.behavior, .allow)
        XCTAssertEqual(decision.reason, "workspace_edit_path")
    }

    func testDefaultToolPermissionPolicyAllowsAbsoluteFileEditsInsideWorkspace() async {
        let decision = await defaultToolPermissionPolicy(
            ToolRequest(id: "tool-write-workspace", name: "fs_write", arguments: #"{"path":"/workspace/Sources/App.swift","content":"x"}"#),
            makeTool(functionName: "fs_write", permissionProfile: .localMutation, isDestructive: true),
            makeContext(toolProvider: PermissionScopeToolProvider(
                workspaceRootURL: URL(fileURLWithPath: "/workspace"),
                readableRootURLs: [URL(fileURLWithPath: "/workspace")]
            ))
        )

        XCTAssertEqual(decision.behavior, .allow)
        XCTAssertEqual(decision.reason, "workspace_edit_path")
    }

    func testDefaultToolPermissionPolicyAsksForAbsoluteFileEditsOutsideWorkspace() async {
        let decision = await defaultToolPermissionPolicy(
            ToolRequest(id: "tool-write-outside", name: "fs_write", arguments: #"{"path":"/tmp/outside.txt","content":"x"}"#),
            makeTool(functionName: "fs_write", permissionProfile: .localMutation, isDestructive: true),
            makeContext(toolProvider: PermissionScopeToolProvider(
                workspaceRootURL: URL(fileURLWithPath: "/workspace"),
                readableRootURLs: [URL(fileURLWithPath: "/workspace")]
            ))
        )

        XCTAssertEqual(decision.behavior, .ask)
        XCTAssertEqual(decision.reason, "absolute_write_path_requires_approval")
        XCTAssertEqual(decision.approvedWritableRootURL?.path, "/tmp/outside.txt")
    }

    func testDefaultToolPermissionPolicyAllowsBypassPermissionMode() async {
        let session = ConversationSession(
            id: UUID().uuidString,
            configuration: .init(storage: DisposableStorageProvider())
        )
        session.setToolPermissionMode(.bypassPermissions)

        let decision = await defaultToolPermissionPolicy(
            ToolRequest(id: "tool-any", name: "unknown_mutating_tool", arguments: "{}"),
            makeTool(functionName: "unknown_mutating_tool"),
            makeContext(session: session)
        )

        XCTAssertEqual(decision.behavior, .allow)
        XCTAssertEqual(decision.reason, "permission_mode_bypass")
    }

    func testDefaultToolPermissionPolicyAllowsSafeFileEditsInAutoReviewMode() async {
        let session = ConversationSession(
            id: UUID().uuidString,
            configuration: .init(storage: DisposableStorageProvider())
        )
        session.setToolPermissionMode(.auto)

        let decision = await defaultToolPermissionPolicy(
            ToolRequest(id: "tool-auto-write", name: "fs_write", arguments: #"{"path":"Sources/App.swift","content":"x"}"#),
            makeTool(functionName: "fs_write", permissionProfile: .localMutation, isDestructive: true),
            makeContext(session: session)
        )

        XCTAssertEqual(decision.behavior, .allow)
        XCTAssertEqual(decision.reason, "workspace_edit_path")
    }

    func testDefaultToolPermissionPolicyAllowsWriteLocalBashInAutoReviewMode() async {
        let session = ConversationSession(
            id: UUID().uuidString,
            configuration: .init(storage: DisposableStorageProvider())
        )
        session.setToolPermissionMode(.auto)

        let decision = await defaultToolPermissionPolicy(
            ToolRequest(id: "tool-auto-bash-write", name: "bash", arguments: #"{"command":"go test ./..."}"#),
            makeTool(functionName: "bash", permissionProfile: .commandExecution, isDestructive: true),
            makeContext(session: session)
        )

        XCTAssertEqual(decision.behavior, .allow)
        XCTAssertEqual(decision.reason, "permission_mode_auto_review")
    }

    func testDefaultToolPermissionPolicyStillAsksForWriteLocalBashOutsideAutoReviewMode() async {
        let decision = await defaultToolPermissionPolicy(
            ToolRequest(id: "tool-bash-write", name: "bash", arguments: #"{"command":"go test ./..."}"#),
            makeTool(functionName: "bash", permissionProfile: .commandExecution, isDestructive: true),
            makeContext()
        )

        XCTAssertEqual(decision.behavior, .ask)
        XCTAssertEqual(decision.reason, "bash_write_command_requires_approval")
    }

    func testDefaultToolPermissionPolicyAsksForSensitiveBashPathInAutoReviewMode() async {
        let session = ConversationSession(
            id: UUID().uuidString,
            configuration: .init(storage: DisposableStorageProvider())
        )
        session.setToolPermissionMode(.auto)

        let decision = await defaultToolPermissionPolicy(
            ToolRequest(id: "tool-auto-bash-sensitive", name: "bash", arguments: #"{"command":"ls ~/.ssh"}"#),
            makeTool(functionName: "bash", permissionProfile: .commandExecution, isDestructive: true),
            makeContext(session: session)
        )

        XCTAssertEqual(decision.behavior, .ask)
        XCTAssertEqual(decision.reason, "bash_sensitive_path_requires_approval")
    }

    func testDefaultToolPermissionPolicyAllowsDefaultAllowedMutationProfiles() async {
        let cases = [
            "memory_upsert": makeTool(functionName: "memory_upsert", permissionProfile: .trustedMutation, isDestructive: true),
            "calendar_add": makeTool(functionName: "calendar_add", permissionProfile: .trustedMutation),
            "reminders_add": makeTool(functionName: "reminders_add", permissionProfile: .trustedMutation),
            "text_to_social_images": makeTool(functionName: "text_to_social_images", permissionProfile: .trustedMutation),
            "image_remove_background": makeTool(functionName: "image_remove_background", permissionProfile: .trustedMutation),
            "contacts_add": makeTool(functionName: "contacts_add", permissionProfile: .trustedMutation),
            "blog_watch": makeTool(functionName: "blog_watch", permissionProfile: .trustedMutation),
            "notify_user": makeTool(functionName: "notify_user", permissionProfile: .trustedMutation),
            "watch_notify": makeTool(functionName: "watch_notify", permissionProfile: .trustedMutation),
        ]

        for (toolName, tool) in cases {
            let decision = await defaultToolPermissionPolicy(
                ToolRequest(id: "tool-default-\(toolName)", name: toolName, arguments: "{}"),
                tool,
                makeContext()
            )

            XCTAssertEqual(decision.behavior, .allow, toolName)
            XCTAssertEqual(decision.reason, "default_allowed_tool_profile", toolName)
        }
    }

    func testDefaultToolPermissionPolicyAsksBeforeOpeningWebViewWebsite() async {
        let decision = await defaultToolPermissionPolicy(
            ToolRequest(id: "tool-web-open", name: "web_view", arguments: #"{"url":"https://example.com/docs"}"#),
            makeTool(functionName: "web_view", permissionProfile: .externalNavigation),
            makeContext()
        )

        XCTAssertEqual(decision.behavior, .ask)
        XCTAssertEqual(decision.reason, "web_view_origin_requires_approval")
        XCTAssertEqual(decision.message, "Opening pages from https://example.com needs your approval.")
    }

    func testDefaultToolPermissionPolicyUsesRememberedWebViewOriginRule() async {
        let session = ConversationSession(
            id: UUID().uuidString,
            configuration: .init(storage: DisposableStorageProvider())
        )
        session.addSessionToolPermissionRule(
            ToolPermissionRule(
                behavior: .allow,
                toolName: "web_view",
                matcher: .urlOrigin("https://example.com")
            )
        )

        let decision = await defaultToolPermissionPolicy(
            ToolRequest(id: "tool-web-open-origin", name: "web_view", arguments: #"{"url":"https://example.com/other?page=1"}"#),
            makeTool(functionName: "web_view", permissionProfile: .externalNavigation),
            makeContext(session: session)
        )

        XCTAssertEqual(decision.behavior, .allow)
        XCTAssertEqual(decision.reason, "permission_rule_allow_session")
    }

    func testDefaultToolPermissionPolicyAsksBeforeOpeningSensitiveWebViewLocalFile() async {
        let decision = await defaultToolPermissionPolicy(
            ToolRequest(id: "tool-web-local-sensitive", name: "web_view", arguments: #"{"url":"~/.ssh/id_rsa"}"#),
            makeTool(functionName: "web_view", permissionProfile: .externalNavigation),
            makeContext()
        )

        XCTAssertEqual(decision.behavior, .ask)
        XCTAssertEqual(decision.reason, "sensitive_path_requires_approval")
    }

    func testDefaultToolPermissionPolicyAllowsLowRiskWebViewTools() async {
        let cases = [
            ("web_view_snapshot", ToolPermissionProfile.read),
            ("web_view_read", ToolPermissionProfile.read),
            ("web_view_scroll", ToolPermissionProfile.viewControl),
            ("web_view_navigate", ToolPermissionProfile.viewControl),
            ("web_view_close", ToolPermissionProfile.viewControl),
        ]

        for (toolName, profile) in cases {
            let decision = await defaultToolPermissionPolicy(
                ToolRequest(id: "tool-\(toolName)", name: toolName, arguments: "{}"),
                makeTool(functionName: toolName, isReadOnly: profile == .read, permissionProfile: profile),
                makeContext()
            )

            XCTAssertEqual(decision.behavior, .allow, toolName)
            if profile == .viewControl {
                XCTAssertEqual(decision.reason, "default_allowed_tool_profile", toolName)
            }
        }
    }

    func testDefaultToolPermissionPolicyAsksBeforeWebViewInteractions() async {
        let cases = [
            ("web_view_click", #"{"ref":"1"}"#, "web_view_page_interaction_requires_approval"),
            ("web_view_type", #"{"ref":"1","text":"hello"}"#, "web_view_form_interaction_requires_approval"),
            ("web_view_select", #"{"ref":"1","value":"a"}"#, "web_view_form_interaction_requires_approval"),
        ]

        for (toolName, arguments, expectedReason) in cases {
            let decision = await defaultToolPermissionPolicy(
                ToolRequest(id: "tool-\(toolName)", name: toolName, arguments: arguments),
                makeTool(functionName: toolName, permissionProfile: .externalInteraction),
                makeContext()
            )

            XCTAssertEqual(decision.behavior, .ask, toolName)
            XCTAssertEqual(decision.reason, expectedReason, toolName)
        }
    }

    func testDefaultToolPermissionPolicyAllowsProfiledLocalMutationToolsInAutoReviewMode() async {
        let session = ConversationSession(
            id: UUID().uuidString,
            configuration: .init(storage: DisposableStorageProvider())
        )
        session.setToolPermissionMode(.auto)

        let cases = [
            "memory_upsert": makeTool(functionName: "memory_upsert", permissionProfile: .trustedMutation, isDestructive: true),
            "calendar_add": makeTool(functionName: "calendar_add", permissionProfile: .trustedMutation),
            "reminders_add": makeTool(functionName: "reminders_add", permissionProfile: .trustedMutation),
            "text_to_social_images": makeTool(functionName: "text_to_social_images", permissionProfile: .trustedMutation),
        ]

        for (toolName, tool) in cases {
            let decision = await defaultToolPermissionPolicy(
                ToolRequest(id: "tool-auto-\(toolName)", name: toolName, arguments: "{}"),
                tool,
                makeContext(session: session)
            )

            XCTAssertEqual(decision.behavior, .allow, toolName)
            XCTAssertEqual(decision.reason, "permission_mode_auto_review", toolName)
        }
    }

    func testDefaultToolPermissionPolicyAllowsCronActionsInAutoReviewMode() async {
        let session = ConversationSession(
            id: UUID().uuidString,
            configuration: .init(storage: DisposableStorageProvider())
        )
        session.setToolPermissionMode(.auto)

        let cases = [
            #"{"action":"add","prompt":"ping"}"#,
            #"{"action":"list"}"#,
            #"{"action":"remove","id":"job-1"}"#,
            #"{"action":"update","id":"job-1"}"#,
            #"{}"#,
        ]

        for arguments in cases {
            let decision = await defaultToolPermissionPolicy(
                ToolRequest(id: "tool-auto-cron", name: "cron", arguments: arguments),
                makeTool(functionName: "cron", permissionProfile: .scheduledAutomation),
                makeContext(session: session)
            )

            XCTAssertEqual(decision.behavior, .allow, arguments)
            XCTAssertEqual(decision.reason, "permission_mode_auto_review", arguments)
        }
    }

    func testDefaultToolPermissionPolicyAllowsCronOutsideAutoReviewMode() async {
        let decision = await defaultToolPermissionPolicy(
            ToolRequest(id: "tool-cron-remove", name: "cron", arguments: #"{"action":"remove","id":"job-1"}"#),
            makeTool(functionName: "cron", permissionProfile: .scheduledAutomation),
            makeContext()
        )

        XCTAssertEqual(decision.behavior, .allow)
        XCTAssertEqual(decision.reason, "default_allowed_tool_profile")
    }

    func testDefaultToolPermissionPolicyAllowsInstructionOrchestrationToolsInAutoReviewMode() async throws {
        let session = ConversationSession(
            id: UUID().uuidString,
            configuration: .init(storage: DisposableStorageProvider())
        )
        session.setToolPermissionMode(.auto)
        let skillInvoke = try XCTUnwrap(SkillTools().toolDefinitions().first { $0.functionName == "skill_invoke" })

        let cases = [
            (
                ToolRequest(id: "tool-auto-js", name: "javascript_execute", arguments: #"{"code":"return 1"}"#),
                makeTool(functionName: "javascript_execute", permissionProfile: .instructionOrchestration)
            ),
            (
                ToolRequest(id: "tool-auto-skill", name: "skill_invoke", arguments: #"{"name":"commit"}"#),
                skillInvoke
            ),
        ]

        for (request, tool) in cases {
            let decision = await defaultToolPermissionPolicy(
                request,
                tool,
                makeContext(session: session)
            )

            XCTAssertEqual(decision.behavior, .allow, request.name)
            XCTAssertEqual(decision.reason, "permission_mode_auto_review", request.name)
        }
    }

    func testDefaultToolPermissionPolicyDoesNotAutoAllowInstructionOrchestrationNameWithoutProfile() async {
        let session = ConversationSession(
            id: UUID().uuidString,
            configuration: .init(storage: DisposableStorageProvider())
        )
        session.setToolPermissionMode(.auto)

        let decision = await defaultToolPermissionPolicy(
            ToolRequest(id: "tool-auto-js-unprofiled", name: "javascript_execute", arguments: #"{"code":"return 1"}"#),
            makeTool(functionName: "javascript_execute"),
            makeContext(session: session)
        )

        XCTAssertEqual(decision.behavior, .ask)
        XCTAssertEqual(decision.reason, "unclassified_mutating_tool_requires_approval")
    }

    func testDefaultToolPermissionPolicyAsksForSensitiveOutputPathInAutoReviewMode() async {
        let session = ConversationSession(
            id: UUID().uuidString,
            configuration: .init(storage: DisposableStorageProvider())
        )
        session.setToolPermissionMode(.auto)

        let decision = await defaultToolPermissionPolicy(
            ToolRequest(
                id: "tool-auto-sensitive-output",
                name: "image_remove_background",
                arguments: #"{"inputPath":"image.png","outputPath":"~/.ssh/output.png"}"#
            ),
            makeTool(functionName: "image_remove_background", permissionProfile: .trustedMutation),
            makeContext(session: session)
        )

        XCTAssertEqual(decision.behavior, .ask)
        XCTAssertEqual(decision.reason, "sensitive_path_requires_approval")
    }

    func testDefaultToolPermissionPolicyUsesSessionAllowRule() async {
        let session = ConversationSession(
            id: UUID().uuidString,
            configuration: .init(storage: DisposableStorageProvider())
        )
        session.addSessionToolPermissionRule(
            ToolPermissionRule(
                behavior: .allow,
                toolName: "fs_write",
                matcher: .pathPrefix("Sources")
            )
        )

        let decision = await defaultToolPermissionPolicy(
            ToolRequest(id: "tool-write-rule", name: "fs_write", arguments: #"{"path":"Sources/App.swift","content":"x"}"#),
            makeTool(functionName: "fs_write", permissionProfile: .localMutation, isDestructive: true),
            makeContext(session: session)
        )

        XCTAssertEqual(decision.behavior, .allow)
        XCTAssertEqual(decision.reason, "permission_rule_allow_session")
    }

    func testDefaultToolPermissionPolicyUsesSessionDenyRule() async {
        let session = ConversationSession(
            id: UUID().uuidString,
            configuration: .init(storage: DisposableStorageProvider())
        )
        session.addSessionToolPermissionRule(
            ToolPermissionRule(
                behavior: .deny,
                toolName: "bash",
                matcher: .commandPrefix("curl")
            )
        )

        let decision = await defaultToolPermissionPolicy(
            ToolRequest(id: "tool-bash-deny-rule", name: "bash", arguments: #"{"command":"curl https://example.com"}"#),
            makeTool(functionName: "bash", permissionProfile: .commandExecution, isDestructive: true),
            makeContext(session: session)
        )

        XCTAssertEqual(decision.behavior, .deny)
        XCTAssertEqual(decision.reason, "permission_rule_deny_session")
    }

    func testDefaultToolPermissionPolicyAllowsReadOnlyBashCommands() async {
        let decision = await defaultToolPermissionPolicy(
            ToolRequest(id: "tool-bash-readonly", name: "bash", arguments: #"{"command":"git status && git diff"}"#),
            makeTool(functionName: "bash", permissionProfile: .commandExecution, isDestructive: true),
            makeContext()
        )

        XCTAssertEqual(decision.behavior, .allow)
        XCTAssertEqual(decision.reason, "bash_read_only_command")
    }

    func testDefaultToolPermissionPolicyAsksForHighRiskBashCommands() async {
        let decision = await defaultToolPermissionPolicy(
            ToolRequest(id: "tool-bash-risk", name: "bash", arguments: #"{"command":"sudo rm -rf /tmp/example"}"#),
            makeTool(functionName: "bash", permissionProfile: .commandExecution, isDestructive: true),
            makeContext()
        )

        XCTAssertEqual(decision.behavior, .ask)
        XCTAssertEqual(decision.reason, "bash_privilege_escalation_requires_approval")
    }

    func testDefaultToolPermissionPolicyAsksForSensitivePathEvenWhenReadOnly() async {
        let decision = await defaultToolPermissionPolicy(
            ToolRequest(id: "tool-sensitive-read", name: "fs_read", arguments: #"{"path":"~/.ssh/id_rsa"}"#),
            makeTool(functionName: "fs_read", isReadOnly: true, permissionProfile: .read),
            makeContext()
        )

        XCTAssertEqual(decision.behavior, .ask)
        XCTAssertEqual(decision.reason, "sensitive_path_requires_approval")
    }

    func testToolPermissionApprovalQueueResumesWhenApproved() async throws {
        let session = ConversationSession(
            id: UUID().uuidString,
            configuration: .init(storage: DisposableStorageProvider())
        )
        let request = ToolRequest(id: "tool-needs-approval", name: "dangerous_tool", arguments: #"{"force":true}"#)
        let tool = makeTool(functionName: "dangerous_tool", isDestructive: true)

        let approvalTask = Task { @MainActor in
            await session.requestToolPermissionApproval(
                for: request,
                tool: tool,
                decision: .ask(message: "Needs approval", reason: "destructive_tool_requires_approval")
            )
        }

        try await waitForPendingToolPermission(in: session, id: request.id)
        XCTAssertEqual(session.pendingToolPermissionRequests.count, 1)
        XCTAssertEqual(session.pendingToolPermissionRequests.first?.id, request.id)
        XCTAssertEqual(session.pendingToolPermissionRequests.first?.apiName, "dangerous_tool")
        XCTAssertEqual(session.pendingToolPermissionRequests.first?.arguments, #"{"force":true}"#)
        XCTAssertEqual(session.pendingToolPermissionRequests.first?.message, "Needs approval")
        XCTAssertEqual(session.pendingToolPermissionRequests.first?.reason, "destructive_tool_requires_approval")

        session.approveToolPermissionRequest(id: request.id)
        let decision = await approvalTask.value

        XCTAssertEqual(decision.behavior, .allow)
        XCTAssertEqual(decision.reason, "tool_permission_approved")
        XCTAssertTrue(session.pendingToolPermissionRequests.isEmpty)
    }

    func testToolPermissionApprovalQueueResumesWhenRejected() async throws {
        let session = ConversationSession(
            id: UUID().uuidString,
            configuration: .init(storage: DisposableStorageProvider())
        )
        let request = ToolRequest(id: "tool-rejected", name: "dangerous_tool", arguments: "{}")
        let tool = makeTool(functionName: "dangerous_tool", isDestructive: true)

        let approvalTask = Task { @MainActor in
            await session.requestToolPermissionApproval(
                for: request,
                tool: tool,
                decision: .ask(message: "Needs approval", reason: "destructive_tool_requires_approval")
            )
        }

        try await waitForPendingToolPermission(in: session, id: request.id)
        session.rejectToolPermissionRequest(id: request.id, message: "No")
        let decision = await approvalTask.value

        XCTAssertEqual(decision.behavior, .deny)
        XCTAssertEqual(decision.reason, "tool_permission_rejected")
        XCTAssertEqual(decision.message, "No")
        XCTAssertTrue(session.pendingToolPermissionRequests.isEmpty)
    }

    func testDefaultToolPermissionPolicyAllowsJavaScriptExecuteOutsideAutoReviewMode() async {
        let decision = await defaultToolPermissionPolicy(
            ToolRequest(id: "tool-js", name: "javascript_execute", arguments: "{}"),
            makeTool(functionName: "javascript_execute", permissionProfile: .instructionOrchestration),
            makeContext()
        )

        XCTAssertEqual(decision.behavior, .allow)
        XCTAssertEqual(decision.reason, "default_allowed_tool_profile")
    }

    func testDefaultToolPermissionPolicyAllowsSkillInvokeOutsideAutoReviewMode() async throws {
        let skillInvoke = try XCTUnwrap(SkillTools().toolDefinitions().first { $0.functionName == "skill_invoke" })

        let decision = await defaultToolPermissionPolicy(
            ToolRequest(id: "tool-skill", name: "skill_invoke", arguments: #"{"name":"commit"}"#),
            skillInvoke,
            makeContext()
        )

        XCTAssertEqual(decision.behavior, .allow)
        XCTAssertEqual(decision.reason, "default_allowed_tool_profile")
    }

    func testDefaultToolPermissionPolicyUsesSessionExactArgumentsAllowRule() async throws {
        let session = ConversationSession(
            id: UUID().uuidString,
            configuration: .init(storage: DisposableStorageProvider())
        )
        session.addSessionToolPermissionRule(
            ToolPermissionRule(
                behavior: .allow,
                toolName: "skill_invoke",
                matcher: .argumentsEqual(#"{"name":"commit"}"#)
            )
        )
        let skillInvoke = try XCTUnwrap(SkillTools().toolDefinitions().first { $0.functionName == "skill_invoke" })

        let decision = await defaultToolPermissionPolicy(
            ToolRequest(id: "tool-skill", name: "skill_invoke", arguments: #"{"name":"commit"}"#),
            skillInvoke,
            makeContext(session: session)
        )

        XCTAssertEqual(decision.behavior, .allow)
        XCTAssertEqual(decision.reason, "permission_rule_allow_session")
    }

    func testDefaultToolPermissionPolicyNormalizesExactArgumentsAllowRule() async throws {
        let session = ConversationSession(
            id: UUID().uuidString,
            configuration: .init(storage: DisposableStorageProvider())
        )
        session.addSessionToolPermissionRule(
            ToolPermissionRule(
                behavior: .allow,
                toolName: "skill_invoke",
                matcher: .argumentsEqual(#"{"task":"now","name":"commit"}"#)
            )
        )
        let skillInvoke = try XCTUnwrap(SkillTools().toolDefinitions().first { $0.functionName == "skill_invoke" })

        let decision = await defaultToolPermissionPolicy(
            ToolRequest(id: "tool-skill", name: "skill_invoke", arguments: #"{"name":"commit","task":"now"}"#),
            skillInvoke,
            makeContext(session: session)
        )

        XCTAssertEqual(decision.behavior, .allow)
        XCTAssertEqual(decision.reason, "permission_rule_allow_session")
    }

    func testPersistedToolPermissionRuleLoadsForNewSession() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenAvaPermissionTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let firstSession = ConversationSession(
            id: UUID().uuidString,
            configuration: .init(
                storage: DisposableStorageProvider(),
                toolPermissionRulesRootURL: rootURL
            )
        )
        firstSession.addPersistedToolPermissionRule(
            ToolPermissionRule(
                behavior: .allow,
                toolName: "skill_invoke",
                matcher: .argumentsEqual(#"{"name":"commit"}"#)
            )
        )

        let secondSession = ConversationSession(
            id: UUID().uuidString,
            configuration: .init(
                storage: DisposableStorageProvider(),
                toolPermissionRulesRootURL: rootURL
            )
        )
        let skillInvoke = try XCTUnwrap(SkillTools().toolDefinitions().first { $0.functionName == "skill_invoke" })

        let decision = await defaultToolPermissionPolicy(
            ToolRequest(id: "tool-skill", name: "skill_invoke", arguments: #"{"name":"commit"}"#),
            skillInvoke,
            makeContext(session: secondSession)
        )

        XCTAssertEqual(decision.behavior, .allow)
        XCTAssertEqual(decision.reason, "permission_rule_allow_project")
    }

    private func waitForPendingToolPermission(
        in session: ConversationSession,
        id requestID: String,
        timeoutNanoseconds: UInt64 = 1_000_000_000
    ) async throws {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutNanoseconds) / 1_000_000_000)
        while Date() < deadline {
            if session.pendingToolPermissionRequests.contains(where: { $0.id == requestID }) {
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for pending tool permission request \(requestID)")
    }

    private func makeContext(
        session: ConversationSession? = nil,
        toolProvider: ToolProvider? = nil
    ) -> ToolExecutionContext {
        ToolExecutionContext(
            session: session ?? ConversationSession(
                id: UUID().uuidString,
                configuration: .init(storage: DisposableStorageProvider())
            ),
            toolProvider: toolProvider,
            canUseTool: allowAllTools
        )
    }

    private func makeTool(
        functionName: String,
        isReadOnly: Bool = false,
        permissionProfile: ToolPermissionProfile = .standard,
        isDestructive: Bool = false
    ) -> ToolDefinition {
        ToolDefinition(
            functionName: functionName,
            command: "test.\(functionName)",
            description: "",
            parametersSchema: .init([:] as [String: Any]),
            isReadOnly: isReadOnly,
            permissionProfile: permissionProfile,
            isDestructive: isDestructive
        )
    }
}

@MainActor
private final class PermissionScopeToolProvider: ToolProvider, ToolPermissionScopeProviding {
    let toolPermissionWorkspaceRootURL: URL?
    let toolPermissionReadableRootURLs: [URL]

    init(workspaceRootURL: URL?, readableRootURLs: [URL]) {
        toolPermissionWorkspaceRootURL = workspaceRootURL
        toolPermissionReadableRootURLs = readableRootURLs
    }

    func enabledTools() async -> [ChatRequestBody.Tool] {
        []
    }

    func findTool(for _: ToolRequest) async -> ToolExecutor? {
        nil
    }

    func executeTool(_: ToolExecutor, parameters _: String) async throws -> ToolResult {
        ToolResult(text: "{}")
    }
}
