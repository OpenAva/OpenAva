import ChatClient
import Foundation
import MemoryKit
import Testing

struct LLMSaveMemoryConsolidatorTests {
    @Test("model can opt into long-term memory update during window consolidation")
    func modelDrivenMemoryUpdateForWindowMode() async throws {
        let response = """
        {
          "history_summary": "The user confirmed they want concise progress updates and root-cause fixes. They are reimplementing reference project behavior in Swift.",
          "should_update_memory": true,
          "memory_append": "User prefers concise progress updates and root-cause fixes while porting reference project behavior into Swift."
        }
        """
        let consolidator = LLMSaveMemoryConsolidator(chatClient: StubChatClient(responseText: response))
        let result = try await consolidator.consolidate(
            currentLongTermMemory: "",
            records: sampleRecords(),
            archiveAll: false
        )

        #expect(result.historyEntry.contains("concise progress updates"))
        #expect(result.memoryUpdate.contains("[window]"))
        #expect(result.memoryUpdate.contains("root-cause fixes"))
    }

    @Test("plain-text fallback keeps history save working")
    func plainTextFallbackDoesNotOverwriteMemory() async throws {
        let consolidator = LLMSaveMemoryConsolidator(chatClient: StubChatClient(responseText: "Short plain-text summary."))
        let result = try await consolidator.consolidate(
            currentLongTermMemory: "Existing durable memory",
            records: sampleRecords(),
            archiveAll: false
        )

        #expect(result.historyEntry.contains("Short plain-text summary."))
        #expect(result.memoryUpdate == "Existing durable memory")
    }

    @Test("duplicate memory append is ignored")
    func duplicateMemoryAppendIsIgnored() async throws {
        let response = """
        {
          "history_summary": "The user restated an existing preference.",
          "should_update_memory": true,
          "memory_append": "User prefers concise progress updates and root-cause fixes while porting reference project behavior into Swift."
        }
        """
        let existing = "- [2026-03-19] [window] User prefers concise progress updates and root-cause fixes while porting reference project behavior into Swift."
        let consolidator = LLMSaveMemoryConsolidator(chatClient: StubChatClient(responseText: response))
        let result = try await consolidator.consolidate(
            currentLongTermMemory: existing,
            records: sampleRecords(),
            archiveAll: true
        )

        #expect(result.memoryUpdate == existing)
    }

    private func sampleRecords() -> [MemoryRecord] {
        [
            MemoryRecord(role: "user", content: "Please keep progress updates concise.", timestamp: Date(timeIntervalSince1970: 1_710_000_000)),
            MemoryRecord(role: "assistant", content: "I will focus on root-cause fixes.", timestamp: Date(timeIntervalSince1970: 1_710_000_060)),
        ]
    }
}

private final class StubChatClient: ChatClient, @unchecked Sendable {
    let errorCollector = ErrorCollector()

    private let responseText: String

    init(responseText: String) {
        self.responseText = responseText
    }

    func chat(body _: ChatRequestBody) async throws -> ChatResponse {
        ChatResponse(reasoning: "", text: responseText, images: [], tools: [])
    }

    func streamingChat(body _: ChatRequestBody) async throws -> AnyAsyncSequence<ChatResponseChunk> {
        AnyAsyncSequence(AsyncStream { continuation in
            continuation.finish()
        })
    }
}
