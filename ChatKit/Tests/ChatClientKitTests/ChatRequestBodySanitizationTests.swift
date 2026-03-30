import Foundation
import Testing
@testable import ChatClient

struct ChatRequestBodySanitizationTests {
    @Test("Outbound sanitization backfills content for reasoning-only assistant")
    func backfillsReasoningOnlyAssistantMessage() {
        let body = ChatRequestBody(
            messages: [
                .assistant(content: nil, toolCalls: nil, reasoning: "thinking..."),
            ]
        )

        let sanitized = body.sanitizingOutboundMessages()

        #expect(sanitized.messages.count == 1)
        if case let .assistant(content, toolCalls, reasoning, _) = sanitized.messages[0] {
            #expect(toolCalls == nil)
            #expect(reasoning == "thinking...")
            if case let .text(text) = content {
                #expect(text.isEmpty)
            } else {
                #expect(Bool(false), "Expected assistant content to be empty text")
            }
        } else {
            #expect(Bool(false), "Expected assistant message")
        }
    }

    @Test("Outbound sanitization strips empty tool_calls arrays")
    func stripsEmptyToolCallsAndBackfillsContent() {
        let body = ChatRequestBody(
            messages: [
                .assistant(content: nil, toolCalls: [], reasoning: nil),
            ]
        )

        let sanitized = body.sanitizingOutboundMessages()

        if case let .assistant(content, toolCalls, _, _) = sanitized.messages[0] {
            #expect(toolCalls == nil)
            if case let .text(text) = content {
                #expect(text.isEmpty)
            } else {
                #expect(Bool(false), "Expected assistant content to be empty text")
            }
        } else {
            #expect(Bool(false), "Expected assistant message")
        }
    }
}
