import Foundation

enum SubAgentRegistry {
    static let generalPurpose = SubAgentDefinition(
        agentType: "general-purpose",
        description: "General sub agent for multi-step execution with the standard toolset.",
        systemPrompt: """
        You are a delegated sub agent inside OpenAva.
        Execute the assigned task directly and return a concise final result to the parent agent.
        You may use available tools, but you must not spawn additional sub agents.
        """,
        toolPolicy: .all,
        disallowedFunctionNames: SubAgentDefinition.recursiveToolFunctionNames,
        maxTurns: 16,
        supportsBackground: true
    )

    static let explore = SubAgentDefinition(
        agentType: "Explore",
        description: "Read-only research sub agent for searching code, files, and external references.",
        systemPrompt: """
        You are the Explore sub agent inside OpenAva.
        Work in read-only mode. Search, inspect, summarize, and cite findings.
        Do not modify files, write memory, or perform side-effecting device actions.
        Do not spawn additional sub agents.
        """,
        toolPolicy: .readOnly,
        disallowedFunctionNames: SubAgentDefinition.recursiveToolFunctionNames,
        maxTurns: 12,
        supportsBackground: true
    )

    static let plan = SubAgentDefinition(
        agentType: "Plan",
        description: "Read-only planning sub agent for decomposition, investigation, and implementation planning.",
        systemPrompt: """
        You are the Plan sub agent inside OpenAva.
        Investigate the task, identify the right files and dependencies, and return an actionable plan.
        Stay read-only, avoid speculative edits, and do not spawn additional sub agents.
        """,
        toolPolicy: .readOnly,
        disallowedFunctionNames: SubAgentDefinition.recursiveToolFunctionNames,
        maxTurns: 12,
        supportsBackground: true
    )

    static func allDefinitions() -> [SubAgentDefinition] {
        [generalPurpose, explore, plan]
    }

    static func definition(for rawAgentType: String?) -> SubAgentDefinition? {
        guard let normalized = AppConfig.nonEmpty(rawAgentType)?.lowercased() else {
            return generalPurpose
        }

        return allDefinitions().first { $0.agentType.lowercased() == normalized }
    }

    static func availableAgentTypes() -> [String] {
        allDefinitions().map(\.agentType)
    }
}
