//
//  LLMSaveMemoryConsolidator.swift
//  MemoryKit
//
//  LLM-based consolidator using plain-text summary response.
//

import ChatClient
import Foundation
import OSLog

/// Consolidates records by asking the model to return a plain-text summary.
public struct LLMSaveMemoryConsolidator: MemoryConsolidator {
    private static let logger = Logger(subsystem: "com.day1-labs.openava", category: "memory.consolidation")

    private let chatClient: any ChatClient

    public init(chatClient: any ChatClient) {
        self.chatClient = chatClient
    }

    public func consolidate(
        currentLongTermMemory: String,
        records: [MemoryRecord],
        archiveAll: Bool
    ) async throws -> MemoryConsolidationResult {
        Self.logger.info("start memory consolidation mode=\(archiveAll ? "archive_all" : "window") records=\(records.count)")
        let conversationText = buildConversationText(records)
        // Keep stable behavior instructions in system prompt and pass session data in user prompt.
        let systemPrompt = """
        You are a memory consolidation agent.

        Task:
        - Decide both the history summary and whether long-term memory should change.

        Output rules:
        - Return a JSON object only. Do not wrap it in markdown fences.
        - Use this schema exactly:
            {
                "history_summary": "string",
                "should_update_memory": true,
                "memory_append": "string"
            }
        - `history_summary` must be 2-5 sentences and focus on key events, decisions, and useful searchable details.
        - Set `should_update_memory` to true only when the conversation contains durable facts, preferences, constraints, or ongoing goals that should be injected into future prompts.
        - DO NOT store: real-time device data (weather, current location, today's calendar events, contact details, reminder contents) — these are always queryable via tools and will become stale. DO NOT store one-off task completions (sent a message, added a reminder, set an alarm) — the action is already done. DO NOT store transient search or web results. DO NOT store smalltalk or pleasantries.
        - When `should_update_memory` is false, set `memory_append` to an empty string.
        - When `should_update_memory` is true, `memory_append` must be a concise plain-text bullet fragment without a leading dash or date.
        - Do not duplicate information already present in Current Long-term Memory.
        """

        let userPrompt = """
        ## Current Long-term Memory
        \(currentLongTermMemory.isEmpty ? "(empty)" : currentLongTermMemory)

        ## Conversation to Process
        \(conversationText)
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

        // Some reasoning models can place the final payload in reasoning when text is empty.
        let responseText = response.text.isEmpty ? response.reasoning : response.text
        let payload = parseResponse(responseText)
        let summary = payload.historySummary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty else {
            Self.logger.error("memory consolidation failed: empty summary")
            throw MemoryConsolidationError.emptyResult
        }

        let historyEntry = formatHistoryEntry(summary: summary, records: records)
        let memoryUpdate = buildMemoryUpdate(
            currentLongTermMemory: currentLongTermMemory,
            memoryAppend: payload.memoryAppend,
            shouldUpdateMemory: payload.shouldUpdateMemory,
            records: records
        )
        Self.logger.info("memory consolidation succeeded historyChars=\(historyEntry.count) memoryChars=\(memoryUpdate.count)")
        return MemoryConsolidationResult(historyEntry: historyEntry, memoryUpdate: memoryUpdate)
    }

    private func parseResponse(_ text: String) -> ConsolidationPayload {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .init(historySummary: "", shouldUpdateMemory: false, memoryAppend: "")
        }

        if let payload = decodePayload(from: trimmed) {
            return payload
        }

        // Keep compatibility with older plain-text responses so memory saving does not regress.
        return .init(historySummary: trimmed, shouldUpdateMemory: false, memoryAppend: "")
    }

    private func decodePayload(from text: String) -> ConsolidationPayload? {
        let candidates = [text, unwrapCodeFence(in: text)].compactMap { $0 }
        let decoder = JSONDecoder()

        for candidate in candidates {
            guard let data = candidate.data(using: .utf8) else { continue }
            if let payload = try? decoder.decode(ConsolidationPayload.self, from: data) {
                return payload.normalized()
            }
        }

        return nil
    }

    private func unwrapCodeFence(in text: String) -> String? {
        guard text.hasPrefix("```") else { return nil }
        let lines = text.components(separatedBy: .newlines)
        guard lines.count >= 3, lines.last == "```" else { return nil }
        return lines.dropFirst().dropLast().joined(separator: "\n")
    }

    private func buildConversationText(_ records: [MemoryRecord]) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return records.map { record in
            let ts = formatter.string(from: record.timestamp)
            let role = record.role.uppercased()
            let tools = record.toolsUsed.isEmpty ? "" : " [tools: \(record.toolsUsed.joined(separator: ", "))]"
            let content = record.content.replacingOccurrences(of: "\n", with: " ")
            return "[\(ts)] \(role)\(tools): \(content)"
        }.joined(separator: "\n")
    }

    private func formatHistoryEntry(summary: String, records: [MemoryRecord]) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let timestamp = formatter.string(from: records.last?.timestamp ?? Date())
        // Timestamp is added by the app, not generated by model output.
        return "[\(timestamp)] \(summary)"
    }

    private func buildMemoryUpdate(
        currentLongTermMemory: String,
        memoryAppend: String,
        shouldUpdateMemory: Bool,
        records: [MemoryRecord]
    ) -> String {
        guard shouldUpdateMemory else {
            return currentLongTermMemory
        }

        let current = currentLongTermMemory.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedAppend = memoryAppend.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedAppend.isEmpty else {
            return currentLongTermMemory
        }
        if current.localizedCaseInsensitiveContains(normalizedAppend) {
            return currentLongTermMemory
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let date = formatter.string(from: records.last?.timestamp ?? Date())
        // Keep entry minimal: date + durable memory fragment.
        let entry = "- [\(date)] \(normalizedAppend)"

        // Keep long-term memory append-only so future prompts can use durable facts immediately.
        if current.isEmpty {
            return entry
        }
        return "\(current)\n\(entry)"
    }
}

private struct ConsolidationPayload: Codable {
    let historySummary: String
    let shouldUpdateMemory: Bool
    let memoryAppend: String

    enum CodingKeys: String, CodingKey {
        case historySummary = "history_summary"
        case shouldUpdateMemory = "should_update_memory"
        case memoryAppend = "memory_append"
    }

    func normalized() -> ConsolidationPayload {
        let trimmedAppend = memoryAppend.trimmingCharacters(in: .whitespacesAndNewlines)
        return .init(
            historySummary: historySummary.trimmingCharacters(in: .whitespacesAndNewlines),
            shouldUpdateMemory: shouldUpdateMemory && !trimmedAppend.isEmpty,
            memoryAppend: trimmedAppend
        )
    }
}

private enum MemoryConsolidationError: Error {
    case emptyResult
}
