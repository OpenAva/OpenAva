import ChatClient
import ChatUI
import Foundation

extension ConversationSession {
    private enum DynamicMemoryMetadata {
        static let key = AgentMemorySurfacingSupport.metadataKey
    }

    private func latestUserQuery(from requestMessages: [ChatRequestBody.Message]) -> String? {
        for message in requestMessages.reversed() {
            guard case let .user(content, _) = message else { continue }
            guard case let .text(text) = content else { continue }
            let normalized = text
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else { continue }
            return normalized
        }

        return nil
    }

    private func dynamicMemoryRecallSection(for requestMessages: [ChatRequestBody.Message]) async -> String? {
        guard let supportRootURL = sessionDelegate?.activeSupportRootURL(),
              let query = latestUserQuery(from: requestMessages)
        else {
            return nil
        }

        let modelConfig = (models.chat?.client as? LLMChatClient)?.modelConfig
        let builder = AgentMemoryContextBuilder(
            supportRootURL: supportRootURL,
            modelConfig: modelConfig
        )
        return await builder.contextSection(
            query: query,
            recentTools: recentToolNames(),
            alreadySurfacedSlugs: alreadySurfacedMemorySlugs()
        )
    }

    private func recentToolNames(limit: Int = 8) -> [String] {
        var seen = Set<String>()
        var collected: [String] = []

        for message in historyMessages().reversed() where message.role == .assistant {
            for part in message.parts.reversed() {
                guard case let .toolCall(toolCall) = part else { continue }
                let name = (toolCall.apiName.isEmpty ? toolCall.toolName : toolCall.apiName)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, seen.insert(name).inserted else { continue }
                collected.append(name)
                if collected.count >= limit {
                    return collected
                }
            }
        }

        return collected
    }

    private func alreadySurfacedMemorySlugs() -> Set<String> {
        AgentMemorySurfacingSupport.surfacedSlugs(from: historyMessages())
    }

    private func persistSurfacedMemorySlugs(_ slugs: Set<String>, for requestMessages: [ChatRequestBody.Message]) {
        let metadataValue = AgentMemorySurfacingSupport.encodeMetadataValue(for: slugs)
        let userTurnText = latestUserQuery(from: requestMessages)
        guard let targetMessage = latestUserMessage(matching: userTurnText) else {
            return
        }

        if let metadataValue {
            targetMessage.metadata[DynamicMemoryMetadata.key] = metadataValue
        } else {
            targetMessage.metadata.removeValue(forKey: DynamicMemoryMetadata.key)
        }
        recordMessageInTranscript(targetMessage)
    }

    private func latestUserMessage(matching userText: String?) -> ConversationMessage? {
        let normalizedTarget = userText?
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let normalizedTarget, !normalizedTarget.isEmpty,
           let matched = historyMessages().last(where: { message in
               guard message.role == .user else { return false }
               let normalizedMessage = message.textContent
                   .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                   .trimmingCharacters(in: .whitespacesAndNewlines)
               return normalizedMessage == normalizedTarget
           })
        {
            return matched
        }

        return historyMessages().last(where: { $0.role == .user })
    }

    func buildInstructionRequestMessage(
        for requestMessages: [ChatRequestBody.Message],
        capabilities: Set<ModelCapability>
    ) async -> ChatRequestBody.Message? {
        let dynamicMemorySection = await dynamicMemoryRecallSection(for: requestMessages)
        if let dynamicMemorySection {
            let surfacedSlugs = AgentMemorySurfacingSupport.surfacedSlugs(fromRenderedSection: dynamicMemorySection)
            if !surfacedSlugs.isEmpty {
                persistSurfacedMemorySlugs(alreadySurfacedMemorySlugs().union(surfacedSlugs), for: requestMessages)
            }
        }

        let trimmedBasePrompt = systemPromptProvider()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let promptSections = [trimmedBasePrompt, dynamicMemorySection]
            .compactMap { section -> String? in
                guard let section else { return nil }
                let trimmed = section.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
        guard !promptSections.isEmpty else { return nil }

        let combined = promptSections.joined(separator: "\n\n")
        if capabilities.contains(.developerRole) {
            return .developer(content: .text(combined))
        } else {
            return .system(content: .text(combined))
        }
    }
}
