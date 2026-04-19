import ChatClient
import ChatUI
import Foundation

private let contextTrimLimitRatio: Double = 0.75
private let contextAutoCompactRatio: Double = 0.80

public struct ContextUsageSnapshot: Sendable {
    public struct LastCompaction: Sendable {
        public let trigger: String
        public let preTokens: Int
        public let messagesSummarized: Int?
        public let preCompactDiscoveredTools: [String]?
    }

    public let estimatedInputTokens: Int
    public let contextLength: Int
    public let usedPercentage: Int
    public let remainingTokens: Int
    public let remainingPercentage: Int
    public let trimLimitTokens: Int
    public let responseHeadroomTokens: Int
    public let autoCompactThresholdTokens: Int
    public let autoCompactEnabled: Bool
    public let instructionTokens: Int
    public let conversationTokens: Int
    public let toolDefinitionTokens: Int
    public let instructionMessageCount: Int
    public let userMessageCount: Int
    public let assistantMessageCount: Int
    public let toolMessageCount: Int
    public let toolDefinitionCount: Int
    public let lastUsage: TokenUsage?
    public let lastCompaction: LastCompaction?
}

extension ConversationSession {
    func contextUsageSnapshot(for model: ConversationSession.Model) async -> ContextUsageSnapshot {
        let requestMessages = await buildExecutionRequestMessages(capabilities: model.capabilities)

        var tools: [ChatRequestBody.Tool]? = nil
        if model.capabilities.contains(.tool), let toolProvider {
            let toolDefinitions = await toolProvider.enabledTools()
            if !toolDefinitions.isEmpty {
                tools = toolDefinitions
            }
        }

        var instructionTokens = 0
        var conversationTokens = 0
        var instructionMessageCount = 0
        var userMessageCount = 0
        var assistantMessageCount = 0
        var toolMessageCount = 0

        for message in requestMessages {
            let tokens = await estimateTokens(for: message)
            switch message {
            case .system, .developer:
                instructionTokens += tokens
                instructionMessageCount += 1
            case .user:
                conversationTokens += tokens
                userMessageCount += 1
            case .assistant:
                conversationTokens += tokens
                assistantMessageCount += 1
            case .tool:
                conversationTokens += tokens
                toolMessageCount += 1
            }
        }

        let toolDefinitionTokens = await estimateToolTokenCount(tools)
        let estimatedInputTokens = max(1, instructionTokens + conversationTokens + toolDefinitionTokens)
        let contextLength = max(model.contextLength, 0)
        let remainingTokens = max(contextLength - estimatedInputTokens, 0)
        let usedPercentage: Int
        let remainingPercentage: Int
        if contextLength > 0 {
            usedPercentage = min(100, Int((Double(estimatedInputTokens) / Double(contextLength) * 100).rounded()))
            remainingPercentage = max(0, 100 - usedPercentage)
        } else {
            usedPercentage = 0
            remainingPercentage = 0
        }

        let trimLimitTokens = Int(Double(contextLength) * contextTrimLimitRatio)
        let responseHeadroomTokens = max(contextLength - trimLimitTokens, 0)
        let autoCompactThresholdTokens = Int(Double(contextLength) * contextAutoCompactRatio)
        let lastCompaction = messages.reversed()
            .compactMap(\.compactBoundaryMetadata)
            .first
            .map {
                ContextUsageSnapshot.LastCompaction(
                    trigger: $0.trigger,
                    preTokens: $0.preTokens,
                    messagesSummarized: $0.messagesSummarized,
                    preCompactDiscoveredTools: $0.preCompactDiscoveredTools
                )
            }

        return ContextUsageSnapshot(
            estimatedInputTokens: estimatedInputTokens,
            contextLength: contextLength,
            usedPercentage: usedPercentage,
            remainingTokens: remainingTokens,
            remainingPercentage: remainingPercentage,
            trimLimitTokens: trimLimitTokens,
            responseHeadroomTokens: responseHeadroomTokens,
            autoCompactThresholdTokens: autoCompactThresholdTokens,
            autoCompactEnabled: model.autoCompactEnabled,
            instructionTokens: instructionTokens,
            conversationTokens: conversationTokens,
            toolDefinitionTokens: toolDefinitionTokens,
            instructionMessageCount: instructionMessageCount,
            userMessageCount: userMessageCount,
            assistantMessageCount: assistantMessageCount,
            toolMessageCount: toolMessageCount,
            toolDefinitionCount: tools?.count ?? 0,
            lastUsage: lastUsage,
            lastCompaction: lastCompaction
        )
    }
}
