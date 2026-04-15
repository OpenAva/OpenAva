//
//  ConversationSession+SystemPrompt.swift
//  ChatUI
//
//  System prompt injection into request messages.
//

import ChatClient
import ChatUI
import Foundation

extension ConversationSession {
    private enum DynamicMemoryRecallConfig {
        static let maxQueryCharacters = 320
        static let maxHits = 3
        static let maxContentCharacters = 280
        static let maxRecentUserMessages = 3
        static let minPrimaryQueryCharacters = 80
    }

    private func instructionMessage(
        _ text: String,
        capabilities: Set<ModelCapability>
    ) -> ChatRequestBody.Message {
        if capabilities.contains(.developerRole) {
            return .developer(content: .text(text))
        }
        return .system(content: .text(text))
    }

    private func isInstructionMessage(_ message: ChatRequestBody.Message) -> Bool {
        switch message {
        case .system, .developer:
            true
        default:
            false
        }
    }

    private func latestUserQuery(in requestMessages: [ChatRequestBody.Message]) -> String? {
        let recentUserTexts = recentUserTexts(in: requestMessages)
        guard let latest = recentUserTexts.first else { return nil }

        var queryParts = [latest]
        var totalCharacters = latest.count
        if shouldExpandRecallQuery(latest) {
            for previous in recentUserTexts.dropFirst() {
                guard totalCharacters < DynamicMemoryRecallConfig.maxQueryCharacters else { break }
                queryParts.append(previous)
                totalCharacters += previous.count
            }
        }

        return truncated(queryParts.joined(separator: "\n"), limit: DynamicMemoryRecallConfig.maxQueryCharacters)
    }

    private func recentUserTexts(in requestMessages: [ChatRequestBody.Message]) -> [String] {
        var texts: [String] = []
        var seen = Set<String>()

        for message in requestMessages.reversed() {
            guard case let .user(content, _) = message else { continue }
            let text = normalizedUserText(from: content)
            guard !text.isEmpty else { continue }
            guard !ConversationMarkers.isContextSummary(text), !ConversationMarkers.isToolUseSummary(text) else { continue }
            guard seen.insert(text).inserted else { continue }
            texts.append(text)
            if texts.count >= DynamicMemoryRecallConfig.maxRecentUserMessages {
                break
            }
        }
        return texts
    }

    private func normalizedUserText(from content: ChatRequestBody.Message.MessageContent<String, [ChatRequestBody.Message.ContentPart]>) -> String {
        userText(from: content)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func shouldExpandRecallQuery(_ text: String) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }
        if normalized.count < DynamicMemoryRecallConfig.minPrimaryQueryCharacters {
            return true
        }

        let lowered = normalized.lowercased()
        let continuationMarkers = [
            "继续", "接着", "再", "然后", "顺便", "同样", "基于上面", "在这个基础上", "按这个", "上面那个", "这个呢", "下一步",
            "continue", "follow up", "based on that", "on top of", "same", "also", "then", "next step",
        ]
        return continuationMarkers.contains { marker in
            lowered.contains(marker)
        }
    }

    private func userText(from content: ChatRequestBody.Message.MessageContent<String, [ChatRequestBody.Message.ContentPart]>) -> String {
        switch content {
        case let .text(text):
            return text
        case let .parts(parts):
            return parts.compactMap { part in
                guard case let .text(text) = part else { return nil }
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        }
    }

    private func truncated(_ raw: String, limit: Int) -> String {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count > limit else { return normalized }
        let endIndex = normalized.index(normalized.startIndex, offsetBy: limit)
        return String(normalized[..<endIndex]) + "…"
    }

    private func dynamicMemoryRecallSection(for requestMessages: [ChatRequestBody.Message]) async -> String? {
        guard let runtimeRootURL = sessionDelegate?.activeRuntimeRootURL(),
              let query = latestUserQuery(in: requestMessages)
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
            let entry = hit.entry
            let excerpt = truncated(entry.content.replacingOccurrences(of: "\n", with: " "), limit: DynamicMemoryRecallConfig.maxContentCharacters)
            return """
            - [\(entry.type.rawValue)] \(entry.name) (slug=\(entry.slug), version=\(entry.version), score=\(hit.score))
              - description: \(entry.description)
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

    /// Inject a fresh system prompt into request messages.
    ///
    /// The prompt is inserted after any existing instruction messages
    /// at the front of the array, ensuring it precedes user/assistant turns.
    func injectSystemPrompt(
        _ requestMessages: inout [ChatRequestBody.Message],
        capabilities: Set<ModelCapability>
    ) async {
        let dynamicMemorySection = await dynamicMemoryRecallSection(for: requestMessages)

        // Prefer a fully composed prompt from the delegate (e.g. AgentPromptBuilder).
        // This lets the host app inject the complete agent identity, tooling, workspace
        // context, and time section without duplicating the date appended below.
        if let fullPrompt = await sessionDelegate?.composeSystemPrompt(),
           !fullPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            let finalPrompt: String
            if let dynamicMemorySection {
                finalPrompt = fullPrompt + "\n\n" + dynamicMemorySection
            } else {
                finalPrompt = fullPrompt
            }
            let insertIndex = requestMessages.lastIndex(where: isInstructionMessage).map { $0 + 1 } ?? 0
            requestMessages.insert(instructionMessage(finalPrompt, capabilities: capabilities), at: insertIndex)
            return
        }

        var systemParts: [String] = []

        let basePrompt = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !basePrompt.isEmpty {
            systemParts.append(basePrompt)
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let dateString = formatter.string(from: Date())
        systemParts.append("Current date and time: \(dateString).")

        if let searchPrompt = sessionDelegate?.searchSensitivityPrompt() {
            systemParts.append(searchPrompt)
        }

        if let dynamicMemorySection {
            systemParts.append(dynamicMemorySection)
        }

        guard !systemParts.isEmpty else { return }

        let combined = systemParts.joined(separator: "\n\n")
        let insertIndex = requestMessages.lastIndex(where: isInstructionMessage).map { $0 + 1 } ?? 0
        requestMessages.insert(instructionMessage(combined, capabilities: capabilities), at: insertIndex)
    }
}
