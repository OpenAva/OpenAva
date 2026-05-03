import Foundation
import OpenClawKit
import OpenClawProtocol

extension SkillTools {
    func registerHandlers(
        into handlers: inout [String: ToolHandler],
        context: ToolHandlerRegistrationContext
    ) {
        handlers["skill.invoke"] = { request in
            try await Self.handleSkillInvoke(
                request,
                workspaceRootURL: context.workspaceRootURL,
                modelConfig: context.modelConfig,
                activeSupportRootURLProvider: context.activeSupportRootURLProvider,
                toolInvoker: context.toolInvoker
            )
        }
        handlers["skill.upsert"] = { request in
            try await Self.handleSkillUpsert(
                request,
                workspaceRootURL: context.workspaceRootURL
            )
        }
    }

    private static func handleSkillInvoke(
        _ request: BridgeInvokeRequest,
        workspaceRootURL: URL?,
        modelConfig: AppConfig.LLMModel?,
        activeSupportRootURLProvider: @escaping @Sendable () -> URL?,
        toolInvoker: @escaping @Sendable (BridgeInvokeRequest, String?) async -> BridgeInvokeResponse
    ) async throws -> BridgeInvokeResponse {
        struct InvokeParams: Decodable {
            let name: String?
            let task: String?
        }

        switch request.command {
        case "skill.invoke":
            let params = try ToolInvocationHelpers.decodeParams(InvokeParams.self, from: request.paramsJSON)
            guard let name = AppConfig.nonEmpty(params.name) else {
                return BridgeInvokeResponse(
                    id: request.id,
                    ok: false,
                    error: OpenClawNodeError(code: .invalidRequest, message: "INVALID_REQUEST: name is required")
                )
            }

            guard let skill = AgentSkillsLoader.resolveSkill(
                named: name,
                visibility: .all,
                workspaceRootURL: workspaceRootURL
            ) else {
                return BridgeInvokeResponse(
                    id: request.id,
                    ok: false,
                    error: OpenClawNodeError(code: .invalidRequest, message: "NOT_FOUND: skill '\(name)' not found")
                )
            }

            guard let body = AgentSkillsLoader.skillBody(for: skill), !body.isEmpty else {
                return BridgeInvokeResponse(
                    id: request.id,
                    ok: false,
                    error: OpenClawNodeError(code: .unavailable, message: "UNAVAILABLE: skill '\(skill.name)' has empty content")
                )
            }

            let task = AppConfig.nonEmpty(params.task)
            if skill.source == "workspace", skill.origin != nil, let workspaceRootURL {
                let store = AgentSkillStore(workspaceRootURL: workspaceRootURL)
                _ = try? await store.recordInvocation(slug: skill.name)
            }

            switch skill.executionContext {
            case .inline:
                return BridgeInvokeResponse(
                    id: request.id,
                    ok: true,
                    payload: inlineSkillPayload(skill: skill, task: task, body: body)
                )

            case .fork:
                guard let task else {
                    return BridgeInvokeResponse(
                        id: request.id,
                        ok: false,
                        error: OpenClawNodeError(code: .invalidRequest, message: "INVALID_REQUEST: task is required for fork-context skills")
                    )
                }
                guard let modelConfig else {
                    return BridgeInvokeResponse(
                        id: request.id,
                        ok: false,
                        error: OpenClawNodeError(code: .unavailable, message: "UNAVAILABLE: no configured model for fork-context skill execution")
                    )
                }
                guard let definition = forkedSkillDefinition(for: skill) else {
                    return BridgeInvokeResponse(
                        id: request.id,
                        ok: false,
                        error: OpenClawNodeError(code: .invalidRequest, message: "INVALID_REQUEST: unsupported agent '\(skill.agent ?? "")' for skill '\(skill.name)'")
                    )
                }

                let sessionID = ToolRuntime.InvocationContext.sessionID
                let output = try await SubAgentRunner.run(
                    prompt: forkedSkillPrompt(skill: skill, task: task, body: body),
                    definition: definition,
                    workspaceRootURL: workspaceRootURL,
                    supportRootURL: activeSupportRootURLProvider(),
                    modelConfig: modelConfig,
                    executeTool: { nestedRequest in
                        await toolInvoker(nestedRequest, sessionID)
                    }
                )

                let payload = [
                    "## Skill Fork Result",
                    "- skill: \(skill.displayName) (`\(skill.name)`)",
                    "- agent: \(output.agentType)",
                    "- turns: \(output.totalTurns)",
                    "- tool_calls: \(output.totalToolCalls)",
                    "- duration_ms: \(output.durationMs)",
                    "",
                    output.content,
                ].joined(separator: "\n")
                return ToolInvocationHelpers.successResponse(id: request.id, payload: payload)
            }

        default:
            return BridgeInvokeResponse(
                id: request.id,
                ok: false,
                error: OpenClawNodeError(code: .invalidRequest, message: "INVALID_REQUEST: unknown skill command")
            )
        }
    }

    // MARK: - Skill Helpers

    private static func handleSkillUpsert(
        _ request: BridgeInvokeRequest,
        workspaceRootURL: URL?
    ) async throws -> BridgeInvokeResponse {
        struct SupportingFile: Decodable {
            let path: String
            let content: String
        }

        struct UpsertParams: Decodable {
            let name: String
            let description: String
            let whenToUse: String
            let content: String
            let userInvocable: Bool?
            let supportingFiles: [SupportingFile]?
        }

        guard let workspaceRootURL else {
            return BridgeInvokeResponse(
                id: request.id,
                ok: false,
                error: OpenClawNodeError(code: .unavailable, message: "UNAVAILABLE: no active project workspace")
            )
        }

        let params = try ToolInvocationHelpers.decodeParams(UpsertParams.self, from: request.paramsJSON)
        let store = AgentSkillStore(workspaceRootURL: workspaceRootURL)
        let entry = try await store.upsert(
            name: params.name,
            description: params.description,
            whenToUse: params.whenToUse,
            content: params.content,
            slug: params.name,
            userInvocable: params.userInvocable ?? false,
            maturity: .validated,
            origin: .agent
        )
        var fileLines: [String] = []
        for supportingFile in params.supportingFiles ?? [] {
            let targetURL = try await store.writeSupportingFile(
                slug: entry.slug,
                relativePath: supportingFile.path,
                content: supportingFile.content
            )
            fileLines.append("- \(targetURL.path)")
        }

        var lines = [
            "## Skill Upsert",
            "- slug: \(entry.slug)",
            "- version: \(entry.version)",
            "- maturity: \(entry.maturity.rawValue)",
            "- origin: \(entry.origin.rawValue)",
            "- file: \(entry.fileURL.path)",
        ]
        if !fileLines.isEmpty {
            lines.append("- supporting_files:")
            lines.append(contentsOf: fileLines)
        }
        return ToolInvocationHelpers.successResponse(id: request.id, payload: lines.joined(separator: "\n"))
    }

    private static func inlineSkillPayload(skill: AgentSkillsLoader.SkillDefinition, task: String?, body: String) -> String {
        var lines = [
            "## Skill Invocation",
            "- skill: \(skill.displayName) (`\(skill.name)`)",
            "- execution_context: \(skill.executionContext.rawValue)",
        ]

        if let whenToUse = skill.whenToUse {
            lines.append("- when_to_use: \(whenToUse)")
        }
        if !skill.allowedTools.isEmpty {
            lines.append("- allowed_tools: \(skill.allowedTools.joined(separator: ", "))")
        }
        if let effort = skill.effort {
            lines.append("- effort: \(effort)")
        }
        if let maturity = skill.maturity {
            lines.append("- maturity: \(maturity)")
        }
        if let origin = skill.origin {
            lines.append("- origin: \(origin)")
        }
        if skill.usageCount > 0 {
            lines.append("- usage_count: \(skill.usageCount)")
        }
        if !skill.supportingFiles.isEmpty {
            lines.append("- supporting_files: \(skill.supportingFiles.joined(separator: ", "))")
        }

        lines.append("")
        if let task {
            lines.append("## Requested Task")
            lines.append(task)
            lines.append("")
        }
        lines.append("## Skill Instructions")
        lines.append(body)
        return lines.joined(separator: "\n")
    }

    private static func forkedSkillDefinition(for skill: AgentSkillsLoader.SkillDefinition) -> SubAgentDefinition? {
        let baseDefinition: SubAgentDefinition
        if let agent = AppConfig.nonEmpty(skill.agent) {
            guard let resolved = SubAgentRegistry.definition(for: agent) else {
                return nil
            }
            baseDefinition = resolved
        } else {
            baseDefinition = SubAgentRegistry.generalPurpose
        }

        let toolPolicy: SubAgentDefinition.ToolPolicy
        if !skill.allowedTools.isEmpty {
            toolPolicy = .custom(Set(skill.allowedTools))
        } else {
            toolPolicy = baseDefinition.toolPolicy
        }

        var systemPromptParts = [baseDefinition.systemPrompt]
        systemPromptParts.append("You are executing the OpenAva skill '\(skill.displayName)' (id=\(skill.name)). Follow the skill instructions and return only the final result to the parent agent.")
        if let whenToUse = skill.whenToUse {
            systemPromptParts.append("When-to-use guidance: \(whenToUse)")
        }
        if let effort = skill.effort {
            systemPromptParts.append("Requested execution effort: \(effort). Use deeper reasoning when the task complexity justifies it.")
        }

        return SubAgentDefinition(
            agentType: baseDefinition.agentType,
            description: baseDefinition.description,
            systemPrompt: systemPromptParts.joined(separator: "\n\n"),
            toolPolicy: toolPolicy,
            disallowedFunctionNames: baseDefinition.disallowedFunctionNames.union(["skill_invoke"]),
            maxTurns: baseDefinition.maxTurns,
            supportsBackground: baseDefinition.supportsBackground
        )
    }

    private static func forkedSkillPrompt(skill: AgentSkillsLoader.SkillDefinition, task: String, body: String) -> String {
        var lines = [
            "## Requested Task",
            task,
            "",
            "## Skill Metadata",
            "- skill: \(skill.displayName) (`\(skill.name)`)",
            "- execution_context: \(skill.executionContext.rawValue)",
        ]

        if let whenToUse = skill.whenToUse {
            lines.append("- when_to_use: \(whenToUse)")
        }
        if !skill.allowedTools.isEmpty {
            lines.append("- allowed_tools: \(skill.allowedTools.joined(separator: ", "))")
        }
        if let effort = skill.effort {
            lines.append("- effort: \(effort)")
        }
        if let maturity = skill.maturity {
            lines.append("- maturity: \(maturity)")
        }
        if !skill.supportingFiles.isEmpty {
            lines.append("- supporting_files: \(skill.supportingFiles.joined(separator: ", "))")
            lines.append("")
            lines.append("Resolve skill-relative files against the skill directory that contains SKILL.md.")
        }

        lines.append("")
        lines.append("## Skill Instructions")
        lines.append(body)
        return lines.joined(separator: "\n")
    }
}
