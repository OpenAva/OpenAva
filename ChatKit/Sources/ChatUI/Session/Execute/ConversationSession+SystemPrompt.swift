//
//  ConversationSession+SystemPrompt.swift
//  LanguageModelChatUI
//
//  System prompt injection into request messages.
//

import ChatClient
import Foundation

extension ConversationSession {
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

    /// Inject a fresh system prompt into request messages.
    ///
    /// The prompt is inserted after any existing instruction messages
    /// at the front of the array, ensuring it precedes user/assistant turns.
    func injectSystemPrompt(
        _ requestMessages: inout [ChatRequestBody.Message],
        capabilities: Set<ModelCapability>
    ) async {
        // Prefer a fully composed prompt from the delegate (e.g. AgentPromptBuilder).
        // This lets the host app inject the complete agent identity, tooling, workspace
        // context, and time section without duplicating the date appended below.
        if let fullPrompt = await sessionDelegate?.composeSystemPrompt(),
           !fullPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            let insertIndex = requestMessages.lastIndex(where: isInstructionMessage).map { $0 + 1 } ?? 0
            requestMessages.insert(instructionMessage(fullPrompt, capabilities: capabilities), at: insertIndex)
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

        guard !systemParts.isEmpty else { return }

        let combined = systemParts.joined(separator: "\n\n")
        let insertIndex = requestMessages.lastIndex(where: isInstructionMessage).map { $0 + 1 } ?? 0
        requestMessages.insert(instructionMessage(combined, capabilities: capabilities), at: insertIndex)
    }
}
