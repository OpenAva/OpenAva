import ChatClient
import ChatUI
import Foundation

actor AgentDurableMemoryExtractor {
    private struct ExtractionResponse: Decodable {
        struct MemoryCandidate: Decodable {
            let name: String
            let type: String
            let description: String
            let content: String
            let slug: String?
            let expiresAt: String?
            let conflictsWith: [String]?
        }

        let memories: [MemoryCandidate]
    }

    private struct CursorState: Codable {
        let lastProcessedMessageID: String
    }

    private let chatClient: (any ChatClient)?
    private let memoryStore: AgentMemoryStore
    private let runtimeRootURL: URL
    private let fileManager: FileManager

    init(
        runtimeRootURL: URL,
        chatClient: (any ChatClient)?,
        fileManager: FileManager = .default
    ) {
        self.runtimeRootURL = runtimeRootURL.standardizedFileURL
        self.chatClient = chatClient
        self.fileManager = fileManager
        memoryStore = AgentMemoryStore(runtimeRootURL: AgentStore.sharedRuntimeRootURL(fileManager: fileManager), fileManager: fileManager)
    }

    func extractIfNeeded(for sessionID: String, messages: [ConversationMessage]) async {
        guard let chatClient else { return }

        let relevantMessages = recentMessages(from: messages, since: loadLastProcessedMessageID(for: sessionID))
        let visibleMessages = relevantMessages.filter(Self.isModelVisibleMessage)
        guard shouldExtract(from: visibleMessages) else {
            return
        }
        guard let lastProcessedMessageID = visibleMessages.last?.id else {
            return
        }

        if containsManualMemoryMutation(in: relevantMessages) {
            saveLastProcessedMessageID(lastProcessedMessageID, for: sessionID)
            return
        }

        let existingEntries = (try? await memoryStore.listEntries()) ?? []
        let conversationBlock = renderConversation(visibleMessages)
        guard !conversationBlock.isEmpty else { return }

        do {
            let response = try await requestExtraction(
                using: chatClient,
                existingEntries: existingEntries,
                conversationBlock: conversationBlock
            )
            for candidate in response.memories {
                guard let type = AgentMemoryStore.MemoryType(rawValue: candidate.type.lowercased()) else {
                    continue
                }
                let name = candidate.name.trimmingCharacters(in: .whitespacesAndNewlines)
                let description = candidate.description.trimmingCharacters(in: .whitespacesAndNewlines)
                let content = candidate.content.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, !description.isEmpty, !content.isEmpty else {
                    continue
                }
                let resolvedSlug = sanitizedSlug(candidate.slug)
                let conflictSlugs = sanitizedConflictSlugs(candidate.conflictsWith, excluding: resolvedSlug)
                _ = try await memoryStore.upsert(
                    name: name,
                    type: type,
                    description: description,
                    content: content,
                    slug: resolvedSlug,
                    expiresAt: candidate.expiresAt,
                    conflictsWith: conflictSlugs
                )
            }
            saveLastProcessedMessageID(lastProcessedMessageID, for: sessionID)
        } catch {
            return
        }
    }

    private func loadLastProcessedMessageID(for sessionID: String) -> String? {
        let fileURL = cursorFileURL(for: sessionID)
        guard let data = try? Data(contentsOf: fileURL),
              let state = try? JSONDecoder().decode(CursorState.self, from: data)
        else {
            return nil
        }
        return state.lastProcessedMessageID
    }

    private func saveLastProcessedMessageID(_ messageID: String, for sessionID: String) {
        let directoryURL = sessionDirectoryURL(for: sessionID)
        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(CursorState(lastProcessedMessageID: messageID))
            try data.write(to: cursorFileURL(for: sessionID), options: .atomic)
        } catch {
            return
        }
    }

    private func sessionDirectoryURL(for sessionID: String) -> URL {
        runtimeRootURL
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(sessionID, isDirectory: true)
    }

    private func cursorFileURL(for sessionID: String) -> URL {
        sessionDirectoryURL(for: sessionID).appendingPathComponent("durable-memory-extraction-cursor.json", isDirectory: false)
    }

    private func requestExtraction(
        using chatClient: any ChatClient,
        existingEntries: [AgentMemoryStore.Entry],
        conversationBlock: String
    ) async throws -> ExtractionResponse {
        let systemPrompt = """
        You extract durable memories from an agent conversation into a shared memory pool used by all agents.

        Return JSON only using this schema:
        {
          "memories": [
            {
              "name": "string",
              "type": "user|feedback|project|reference",
              "description": "string",
              "content": "string",
              "slug": "string or omitted",
              "expiresAt": "ISO 8601 string or omitted",
              "conflictsWith": ["slug", "..."]
            }
          ]
        }

        Rules:
        - Extract at most 4 memories.
        - Only save durable facts that will matter in future conversations.
        - These memories are shared across all agents — prioritize saving mistakes, corrections, user preferences, and project conventions that prevent the group from repeating errors.
        - Allowed types are exactly: user, feedback, project, reference.
        - Do not save code structure, file paths, implementation details derivable from the repo, temporary task progress, compact summaries, or transient search results.
        - Prefer updating an existing memory topic by reusing its slug when the topic already exists.
        - If an existing memory already covers the same durable topic, reuse that slug instead of creating a new topic.
        - If a new user preference, feedback preference, or project policy directly contradicts an existing active memory, include the old slug in conflictsWith.
        - Use conflictsWith only for genuinely incompatible memories that should stop being active.
        - Use expiresAt only when the conversation explicitly makes the memory time-bounded.
        - If there is nothing worth remembering, return {"memories":[]}.
        - Keep descriptions concise and contents specific.
        """
        let userPrompt = """
        ## Existing Durable Memories
        \(memoryManifest(from: existingEntries))

        ## Recent Conversation
        \(conversationBlock)
        """

        let response = try await chatClient.chat(
            body: ChatRequestBody(
                messages: [
                    .system(content: .text(systemPrompt)),
                    .user(content: .text(userPrompt)),
                ],
                stream: false
            )
        )
        return parseResponse(response.text)
    }

    private func parseResponse(_ raw: String) -> ExtractionResponse {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(ExtractionResponse.self, from: data)
        else {
            return ExtractionResponse(memories: [])
        }
        return decoded
    }

    private func recentMessages(from messages: [ConversationMessage], since messageID: String?) -> [ConversationMessage] {
        guard let messageID, !messageID.isEmpty else {
            return messages
        }
        if let index = messages.firstIndex(where: { $0.id == messageID }) {
            let nextIndex = messages.index(after: index)
            guard nextIndex < messages.endIndex else { return [] }
            return Array(messages[nextIndex...])
        }

        for message in messages.reversed() {
            if message.isCompactBoundary {
                return []
            }
        }

        return messages
    }

    private func shouldExtract(from messages: [ConversationMessage]) -> Bool {
        let userCount = messages.count { $0.role == .user && !$0.textContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let assistantCount = messages.count { $0.role == .assistant && !$0.textContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return userCount > 0 && assistantCount > 0
    }

    private func containsManualMemoryMutation(in messages: [ConversationMessage]) -> Bool {
        let memoryToolNames: Set = [
            "memory_upsert",
            "memory_forget",
        ]
        for message in messages where message.role == .assistant {
            for part in message.parts {
                guard case let .toolCall(toolCall) = part else { continue }
                let name = (toolCall.apiName.isEmpty ? toolCall.toolName : toolCall.apiName)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if memoryToolNames.contains(name) {
                    return true
                }
            }
        }
        return false
    }

    private func renderConversation(_ messages: [ConversationMessage]) -> String {
        messages.compactMap { message in
            let text = message.textContent.trimmingCharacters(in: .whitespacesAndNewlines)
            let toolsUsed = message.parts.compactMap { part -> String? in
                guard case let .toolCall(toolCall) = part else { return nil }
                let name = toolCall.apiName.isEmpty ? toolCall.toolName : toolCall.apiName
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            guard !text.isEmpty || !toolsUsed.isEmpty else { return nil }
            let prefix: String
            switch message.role {
            case .user:
                prefix = "USER"
            case .assistant:
                prefix = "ASSISTANT"
            default:
                prefix = message.role.rawValue.uppercased()
            }
            let toolsSuffix = toolsUsed.isEmpty ? "" : " [tools: \(toolsUsed.joined(separator: ", "))]"
            return "[\(prefix)\(toolsSuffix)] \(text)"
        }
        .joined(separator: "\n\n")
    }

    private func memoryManifest(from entries: [AgentMemoryStore.Entry]) -> String {
        guard !entries.isEmpty else { return "(empty)" }
        return entries.map { entry in
            let excerpt = entry.content
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let truncatedExcerpt: String
            if excerpt.count > 160 {
                let endIndex = excerpt.index(excerpt.startIndex, offsetBy: 160)
                truncatedExcerpt = String(excerpt[..<endIndex]) + "…"
            } else {
                truncatedExcerpt = excerpt
            }
            let versionPart = "version=\(entry.version)"
            return "- slug=\(entry.slug) | \(versionPart) | type=\(entry.type.rawValue) | name=\(entry.name) | description=\(entry.description) | content=\(truncatedExcerpt)"
        }.joined(separator: "\n")
    }

    private func sanitizedSlug(_ raw: String?) -> String? {
        guard let slug = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !slug.isEmpty else {
            return nil
        }
        return slug
    }

    private func sanitizedConflictSlugs(_ raw: [String]?, excluding slug: String?) -> [String] {
        let excluded = slug?.trimmingCharacters(in: .whitespacesAndNewlines)
        let values = (raw ?? []).compactMap { value -> String? in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed != excluded else { return nil }
            return trimmed
        }
        return Array(Set(values)).sorted()
    }

    private static func isModelVisibleMessage(_ message: ConversationMessage) -> Bool {
        !message.isCompactSummary && (message.role == .user || message.role == .assistant || message.role == .tool)
    }
}

private extension Collection {
    func count(where predicate: (Element) -> Bool) -> Int {
        reduce(into: 0) { result, element in
            if predicate(element) {
                result += 1
            }
        }
    }
}
