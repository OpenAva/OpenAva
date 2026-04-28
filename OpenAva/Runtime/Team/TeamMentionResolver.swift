import ChatClient
import Foundation
import OSLog

private let mentionLogger = Logger(subsystem: "com.day1-labs.openava", category: "team.mention-resolver")

/// Determines which agent(s) a user message is addressing using a lightweight LLM call.
/// Handles explicit @mentions, name references, and implicit natural-language addressing
/// (e.g. "Jett, help me with this" or "让 Jett 总结一下").
enum TeamMentionResolver {
    /// Returns the names of addressed agents from `agentNames`, or an empty array if the
    /// message is a broadcast (no specific agent targeted). Falls back to empty on any error.
    static func resolveAddressedAgents(
        userMessage: String,
        agentNames: [String],
        using modelConfig: AppConfig.LLMModel
    ) async -> [String] {
        // Only resolve when there are multiple agents to choose from.
        guard agentNames.count > 1 else { return [] }

        let client = LLMChatClient(modelConfig: modelConfig)
        let nameList = agentNames.joined(separator: ", ")
        let requestBody = ChatRequestBody(
            messages: [
                .system(content: .text(systemPrompt)),
                .user(content: .text("Agent names: \(nameList)\nMessage: \(userMessage)")),
            ],
            maxCompletionTokens: 64,
            temperature: 0
        )

        do {
            let response = try await client.chat(body: requestBody)
            let addressed = parseAddressed(from: response.text, agentNames: agentNames)
            mentionLogger.notice(
                "mention resolution: addressed=\(addressed.joined(separator: ","), privacy: .public)"
            )
            return addressed
        } catch {
            mentionLogger.notice("mention resolution failed, broadcasting: \(error, privacy: .public)")
            return []
        }
    }

    // MARK: - Internal (exposed for testing)

    static func parseAddressed(from text: String, agentNames: [String]) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = trimmed.firstIndex(of: "{"),
              let end = trimmed.lastIndex(of: "}")
        else {
            return []
        }
        let jsonString = String(trimmed[start ... end])
        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let addressed = json["addressed"] as? [String]
        else {
            return []
        }
        let lowercasedNames = Set(agentNames.map { $0.lowercased() })
        return addressed.filter { lowercasedNames.contains($0.lowercased()) }
    }

    // MARK: - Private

    private static let systemPrompt = """
    You are a message routing assistant for a multi-agent team room.
    Given a list of agent names and a user message, determine which agent(s) the user is directly addressing or specifically requesting work from.
    Rules:
    - If the user uses @Name, explicitly names an agent, or clearly directs a request at a specific person, list those names.
    - If the message is a general broadcast with no specific agent targeted, return an empty list.
    - Match names case-insensitively. Return exact names as they appear in the provided list.
    - Respond ONLY with a JSON object, e.g.: {"addressed": ["Name1"]} or {"addressed": []}
    """
}
