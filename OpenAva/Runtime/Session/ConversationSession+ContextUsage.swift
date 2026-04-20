import ChatClient
import ChatUI
import Foundation

public struct ContextUsageSnapshot: Sendable {
    public struct LastCompaction: Sendable {
        public let trigger: String
        public let preTokens: Int
        public let messagesSummarized: Int?
    }

    public struct Category: Sendable, Hashable {
        public enum Kind: String, Sendable, Hashable {
            case systemPrompt
            case tools
            case messages
            case autoCompactBuffer
            case compactBuffer
            case freeSpace
        }

        public struct MessageBreakdown: Sendable, Hashable {
            public let userMessageCount: Int
            public let assistantMessageCount: Int
            public let toolMessageCount: Int
        }

        public let kind: Kind
        public let tokens: Int
        public let entryCount: Int?
        public let messageBreakdown: MessageBreakdown?
        public let isDeferred: Bool
    }

    public struct SystemPromptSectionDetail: Sendable, Hashable {
        public let name: String
        public let tokens: Int
    }

    public struct SystemToolDetail: Sendable, Hashable {
        public let name: String
        public let tokens: Int
    }

    public struct MessageBreakdown: Sendable, Hashable {
        public struct ToolCallDetail: Sendable, Hashable {
            public let name: String
            public let callTokens: Int
            public let resultTokens: Int
        }

        public struct AttachmentDetail: Sendable, Hashable {
            public let name: String
            public let tokens: Int
        }

        public let toolCallTokens: Int
        public let toolResultTokens: Int
        public let attachmentTokens: Int
        public let assistantMessageTokens: Int
        public let userMessageTokens: Int
        public let toolCallsByType: [ToolCallDetail]
        public let attachmentsByType: [AttachmentDetail]
    }

    public let estimatedInputTokens: Int
    public let contextWindowTokens: Int
    public let rawContextWindowTokens: Int
    public let compactOutputReserveTokens: Int
    public let usedPercentage: Int
    public let remainingTokens: Int
    public let remainingPercentage: Int
    public let blockingLimitTokens: Int
    public let autoCompactTriggerTokens: Int
    public let percentLeft: Int
    public let isAboveWarningThreshold: Bool
    public let isAboveErrorThreshold: Bool
    public let isAboveAutoCompactThreshold: Bool
    public let isAtBlockingLimit: Bool
    public let isAutoCompactEnabled: Bool
    public let categories: [Category]
    public let systemPromptSections: [SystemPromptSectionDetail]
    public let systemTools: [SystemToolDetail]
    public let messageBreakdown: MessageBreakdown?
    public let lastUsage: TokenUsage?
    public let lastCompaction: LastCompaction?
}

extension ConversationSession {
    func contextUsageSnapshot(for model: ConversationSession.Model) async -> ContextUsageSnapshot {
        let requestMessages = await buildMessages(capabilities: model.capabilities)
        let tools = await enabledRequestTools(for: model.capabilities)

        var systemPromptTokens = 0
        var systemPromptMessageCount = 0
        var messageTokens = 0
        var userMessageCount = 0
        var assistantMessageCount = 0
        var toolMessageCount = 0
        var systemPromptSections: [ContextUsageSnapshot.SystemPromptSectionDetail] = []

        for message in requestMessages {
            let tokens = await estimateTokens(for: message)
            switch message {
            case .system, .developer:
                systemPromptTokens += tokens
                systemPromptMessageCount += 1
                let content = instructionMessageText(from: message)
                let extractedSections = extractPromptSections(from: content)
                for section in extractedSections {
                    let sectionTokens = await estimateRawTextTokens(section.content)
                    guard sectionTokens > 0 else { continue }
                    systemPromptSections.append(.init(name: section.name, tokens: sectionTokens))
                }
            case .user:
                messageTokens += tokens
                userMessageCount += 1
            case .assistant:
                messageTokens += tokens
                assistantMessageCount += 1
            case .tool:
                messageTokens += tokens
                toolMessageCount += 1
            }
        }

        let systemTools = await estimateSystemToolDetails(tools)
        let toolTokens = systemTools.reduce(0) { $0 + $1.tokens }
        let messageBreakdown = await estimateMessageBreakdown(from: requestMessages)
        let estimatedInputTokens = max(1, systemPromptTokens + messageTokens + toolTokens)
        let rawContextWindowTokens = max(model.contextLength, 0)
        let compactOutputReserveTokens = getReservedTokensForSummary(for: model)
        let contextWindowTokens = max(getEffectiveContextWindowSize(for: model), 0)
        let remainingTokens = max(contextWindowTokens - estimatedInputTokens, 0)
        let usedPercentage: Int
        let remainingPercentage: Int
        if contextWindowTokens > 0 {
            usedPercentage = min(100, Int((Double(estimatedInputTokens) / Double(contextWindowTokens) * 100).rounded()))
            remainingPercentage = max(0, 100 - usedPercentage)
        } else {
            usedPercentage = 0
            remainingPercentage = 0
        }

        let blockingLimitTokens = getBlockingLimit(for: model)
        let autoCompactTriggerTokens = getAutoCompactThreshold(for: model)
        let warningState = calculateTokenWarningState(tokenUsage: estimatedInputTokens, model: model)
        let compactBufferCategoryKind: ContextUsageSnapshot.Category.Kind = isAutoCompactEnabled(for: model)
            ? .autoCompactBuffer
            : .compactBuffer
        let compactBufferTokens = isAutoCompactEnabled(for: model)
            ? max(contextWindowTokens - autoCompactTriggerTokens, 0)
            : max(contextWindowTokens - blockingLimitTokens, 0)
        let freeSpaceTokens = max(contextWindowTokens - estimatedInputTokens - compactBufferTokens, 0)

        var categories: [ContextUsageSnapshot.Category] = []
        if systemPromptTokens > 0 {
            categories.append(
                .init(
                    kind: .systemPrompt,
                    tokens: systemPromptTokens,
                    entryCount: systemPromptMessageCount,
                    messageBreakdown: nil,
                    isDeferred: false
                )
            )
        }
        if toolTokens > 0 {
            categories.append(
                .init(
                    kind: .tools,
                    tokens: toolTokens,
                    entryCount: tools?.count ?? 0,
                    messageBreakdown: nil,
                    isDeferred: false
                )
            )
        }
        if messageTokens > 0 {
            categories.append(
                .init(
                    kind: .messages,
                    tokens: messageTokens,
                    entryCount: nil,
                    messageBreakdown: .init(
                        userMessageCount: userMessageCount,
                        assistantMessageCount: assistantMessageCount,
                        toolMessageCount: toolMessageCount
                    ),
                    isDeferred: false
                )
            )
        }
        if compactBufferTokens > 0 {
            categories.append(
                .init(
                    kind: compactBufferCategoryKind,
                    tokens: compactBufferTokens,
                    entryCount: nil,
                    messageBreakdown: nil,
                    isDeferred: false
                )
            )
        }
        categories.append(
            .init(
                kind: .freeSpace,
                tokens: freeSpaceTokens,
                entryCount: nil,
                messageBreakdown: nil,
                isDeferred: false
            )
        )

        let lastCompaction = messages.reversed()
            .compactMap(\.compactBoundaryMetadata)
            .first
            .map {
                ContextUsageSnapshot.LastCompaction(
                    trigger: $0.trigger,
                    preTokens: $0.preTokens,
                    messagesSummarized: $0.messagesSummarized
                )
            }

        return ContextUsageSnapshot(
            estimatedInputTokens: estimatedInputTokens,
            contextWindowTokens: contextWindowTokens,
            rawContextWindowTokens: rawContextWindowTokens,
            compactOutputReserveTokens: compactOutputReserveTokens,
            usedPercentage: usedPercentage,
            remainingTokens: remainingTokens,
            remainingPercentage: remainingPercentage,
            blockingLimitTokens: blockingLimitTokens,
            autoCompactTriggerTokens: autoCompactTriggerTokens,
            percentLeft: warningState.percentLeft,
            isAboveWarningThreshold: warningState.isAboveWarningThreshold,
            isAboveErrorThreshold: warningState.isAboveErrorThreshold,
            isAboveAutoCompactThreshold: warningState.isAboveAutoCompactThreshold,
            isAtBlockingLimit: warningState.isAtBlockingLimit,
            isAutoCompactEnabled: isAutoCompactEnabled(for: model),
            categories: categories,
            systemPromptSections: systemPromptSections,
            systemTools: systemTools,
            messageBreakdown: messageBreakdown,
            lastUsage: lastUsage,
            lastCompaction: lastCompaction
        )
    }

    private func instructionMessageText(from message: ChatRequestBody.Message) -> String {
        switch message {
        case let .developer(content, _), let .system(content, _):
            return plainText(from: content)
        default:
            return ""
        }
    }

    private func plainText(from content: ChatRequestBody.Message.MessageContent<String, [String]>) -> String {
        switch content {
        case let .text(text):
            return text
        case let .parts(parts):
            return parts.joined(separator: "\n")
        }
    }

    private func extractPromptSections(from raw: String) -> [(name: String, content: String)] {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return [] }

        let lines = normalized.components(separatedBy: .newlines)
        var sections: [(name: String, content: String)] = []
        var currentHeading: String?
        var currentLines: [String] = []

        func flushCurrentSection() {
            let content = currentLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else {
                currentLines.removeAll(keepingCapacity: true)
                return
            }
            let name = currentHeading ?? promptSectionName(for: content)
            sections.append((name: name, content: content))
            currentLines.removeAll(keepingCapacity: true)
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if let heading = promptHeading(from: trimmed) {
                flushCurrentSection()
                currentHeading = heading
                continue
            }
            currentLines.append(line)
        }

        flushCurrentSection()
        return sections
    }

    private func promptHeading(from line: String) -> String? {
        guard line.hasPrefix("##") else { return nil }
        let trimmed = line.drop(while: { $0 == "#" || $0 == " " })
        let heading = String(trimmed).trimmingCharacters(in: .whitespacesAndNewlines)
        return heading.isEmpty ? nil : heading
    }

    private func promptSectionName(for content: String) -> String {
        let firstLine = content
            .components(separatedBy: .newlines)
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "System prompt"
        guard firstLine.count > 40 else { return firstLine }
        let endIndex = firstLine.index(firstLine.startIndex, offsetBy: 40)
        return String(firstLine[..<endIndex]) + "…"
    }

    private func estimateSystemToolDetails(
        _ tools: [ChatRequestBody.Tool]?
    ) async -> [ContextUsageSnapshot.SystemToolDetail] {
        guard let tools, !tools.isEmpty else { return [] }
        var details: [ContextUsageSnapshot.SystemToolDetail] = []
        for tool in tools {
            guard let name = toolName(for: tool),
                  let data = try? JSONEncoder().encode(tool),
                  let string = String(data: data, encoding: .utf8)
            else {
                continue
            }
            let tokens = await estimateRawTextTokens(string)
            details.append(.init(name: name, tokens: tokens))
        }
        return details.sorted { lhs, rhs in
            lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private func toolName(for tool: ChatRequestBody.Tool) -> String? {
        switch tool {
        case let .function(name, _, _, _):
            return name
        }
    }

    private func estimateMessageBreakdown(
        from requestMessages: [ChatRequestBody.Message]
    ) async -> ContextUsageSnapshot.MessageBreakdown? {
        var toolCallTokens = 0
        var toolResultTokens = 0
        var attachmentTokens = 0
        var assistantMessageTokens = 0
        var userMessageTokens = 0
        var toolCallDetailsByName: [String: (callTokens: Int, resultTokens: Int)] = [:]
        var attachmentDetailsByName: [String: Int] = [:]
        var toolNameByCallID: [String: String] = [:]

        for message in requestMessages {
            switch message {
            case let .assistant(content, toolCalls, reasoning, _):
                var assistantTokens = 12
                if let content {
                    assistantTokens += await estimateAssistantTextTokens(content)
                }
                if let reasoning {
                    assistantTokens += await estimateRawTextTokens(reasoning)
                }
                assistantMessageTokens += assistantTokens

                if let toolCalls {
                    for toolCall in toolCalls {
                        guard let data = try? JSONEncoder().encode(toolCall),
                              let string = String(data: data, encoding: .utf8)
                        else {
                            continue
                        }
                        let tokens = await estimateRawTextTokens(string)
                        toolCallTokens += tokens
                        let metadata = toolCallMetadata(from: data)
                        let name = normalizedToolName(metadata.name)
                        let current = toolCallDetailsByName[name] ?? (0, 0)
                        toolCallDetailsByName[name] = (current.callTokens + tokens, current.resultTokens)
                        if let id = metadata.id {
                            toolNameByCallID[id] = name
                        }
                    }
                }

            case let .tool(content, toolCallID):
                let resultTokens = 12 + (await estimateToolResultTokens(content))
                toolResultTokens += resultTokens
                let name = toolNameByCallID[toolCallID] ?? "tool"
                let current = toolCallDetailsByName[name] ?? (0, 0)
                toolCallDetailsByName[name] = (current.callTokens, current.resultTokens + resultTokens)

            case let .user(content, _):
                let detail = await estimateUserMessageBreakdown(content)
                userMessageTokens += detail.textTokens
                attachmentTokens += detail.attachmentTokens
                for (name, tokens) in detail.attachmentsByType {
                    attachmentDetailsByName[name, default: 0] += tokens
                }

            case .system, .developer:
                continue
            }
        }

        let hasBreakdown = toolCallTokens > 0
            || toolResultTokens > 0
            || attachmentTokens > 0
            || assistantMessageTokens > 0
            || userMessageTokens > 0
        guard hasBreakdown else { return nil }

        let toolCallsByType = toolCallDetailsByName.keys.sorted().map { name in
            let detail = toolCallDetailsByName[name] ?? (0, 0)
            return ContextUsageSnapshot.MessageBreakdown.ToolCallDetail(
                name: name,
                callTokens: detail.callTokens,
                resultTokens: detail.resultTokens
            )
        }
        let attachmentsByType = attachmentDetailsByName.keys.sorted().map { name in
            ContextUsageSnapshot.MessageBreakdown.AttachmentDetail(
                name: name,
                tokens: attachmentDetailsByName[name] ?? 0
            )
        }

        return .init(
            toolCallTokens: toolCallTokens,
            toolResultTokens: toolResultTokens,
            attachmentTokens: attachmentTokens,
            assistantMessageTokens: assistantMessageTokens,
            userMessageTokens: userMessageTokens,
            toolCallsByType: toolCallsByType,
            attachmentsByType: attachmentsByType
        )
    }

    private func estimateAssistantTextTokens(
        _ content: ChatRequestBody.Message.MessageContent<String, [String]>
    ) async -> Int {
        switch content {
        case let .text(text):
            return await estimateRawTextTokens(text)
        case let .parts(parts):
            var total = 0
            for part in parts {
                total += await estimateRawTextTokens(part)
            }
            return total
        }
    }

    private func estimateToolResultTokens(
        _ content: ChatRequestBody.Message.MessageContent<String, [String]>
    ) async -> Int {
        switch content {
        case let .text(text):
            return await estimateRawTextTokens(text)
        case let .parts(parts):
            var total = 0
            for part in parts {
                total += await estimateRawTextTokens(part)
            }
            return total
        }
    }

    private func estimateUserMessageBreakdown(
        _ content: ChatRequestBody.Message.MessageContent<String, [ChatRequestBody.Message.ContentPart]>
    ) async -> (textTokens: Int, attachmentTokens: Int, attachmentsByType: [String: Int]) {
        switch content {
        case let .text(text):
            let textTokens = 12 + (await estimateRawTextTokens(text))
            return (textTokens: textTokens, attachmentTokens: 0, attachmentsByType: [:])
        case let .parts(parts):
            var textTokens = 12
            var attachmentTokens = 0
            var attachmentsByType: [String: Int] = [:]
            for part in parts {
                switch part {
                case let .text(text):
                    textTokens += await estimateRawTextTokens(text)
                case .imageURL:
                    let tokens = estimateAttachmentTokens(for: part)
                    attachmentTokens += tokens
                    attachmentsByType["Image", default: 0] += tokens
                case .audioBase64:
                    let tokens = estimateAttachmentTokens(for: part)
                    attachmentTokens += tokens
                    attachmentsByType["Audio", default: 0] += tokens
                }
            }
            return (textTokens: textTokens, attachmentTokens: attachmentTokens, attachmentsByType: attachmentsByType)
        }
    }

    private func estimateRawTextTokens(_ text: String) async -> Int {
        max((await estimateTokens(for: .system(content: .text(text)))) - 12, 0)
    }

    private func estimateAttachmentTokens(for part: ChatRequestBody.Message.ContentPart) -> Int {
        switch part {
        case .imageURL, .audioBase64:
            1000
        case .text:
            0
        }
    }

    private func normalizedToolName(_ name: String?) -> String {
        let trimmed = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "tool" : trimmed
    }

    private func toolCallMetadata(from data: Data) -> (id: String?, name: String?) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (nil, nil)
        }
        let id = object["id"] as? String
        let function = object["function"] as? [String: Any]
        let name = function?["name"] as? String
        return (id, name)
    }
}
