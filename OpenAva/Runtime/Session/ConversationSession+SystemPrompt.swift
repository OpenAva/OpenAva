import ChatClient
import ChatUI
import Foundation

extension ConversationSession {
    private enum DynamicMemoryRecallConfig {
        static let maxQueryCharacters = 320
        static let maxHits = 3
        static let maxContentCharacters = 280
    }

    private func latestUserQuery(from requestMessages: [ChatRequestBody.Message]) -> String? {
        for message in requestMessages.reversed() {
            guard case let .user(content, _) = message else { continue }
            guard case let .text(text) = content else { continue }
            let normalized = text
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else { continue }
            return truncated(normalized, limit: DynamicMemoryRecallConfig.maxQueryCharacters)
        }

        return nil
    }

    private func truncated(_ raw: String, limit: Int) -> String {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count > limit else { return normalized }
        let endIndex = normalized.index(normalized.startIndex, offsetBy: limit)
        return String(normalized[..<endIndex]) + "…"
    }

    private func dynamicMemoryRecallSection(for requestMessages: [ChatRequestBody.Message]) async -> String? {
        guard let runtimeRootURL = sessionDelegate?.activeRuntimeRootURL(),
              let query = latestUserQuery(from: requestMessages)
        else {
            return nil
        }

        let store = AgentMemoryStore(runtimeRootURL: runtimeRootURL)
        guard let hits = try? await store.recall(query: query, limit: DynamicMemoryRecallConfig.maxHits),
              !hits.isEmpty
        else {
            return nil
        }

        let lines = hits.map { hit -> String in
            let excerpt = truncated(hit.content.replacingOccurrences(of: "\n", with: " "), limit: DynamicMemoryRecallConfig.maxContentCharacters)
            return """
            - [\(hit.type.rawValue)] \(hit.name) (slug=\(hit.slug), version=\(hit.version))
              - description: \(hit.description)
              - content: \(excerpt)
            """
        }

        return """
        ## Dynamic Memory Recall
        Current request query: \(query)

        Relevant active durable memories:
        \(lines.joined(separator: "\n"))
        """
    }

    func buildInstructionRequestMessage(
        for requestMessages: [ChatRequestBody.Message],
        capabilities: Set<ModelCapability>
    ) async -> ChatRequestBody.Message? {
        let dynamicMemorySection = await dynamicMemoryRecallSection(for: requestMessages)

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
