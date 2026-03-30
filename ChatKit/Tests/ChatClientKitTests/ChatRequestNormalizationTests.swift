//
//  ChatRequestNormalizationTests.swift
//  ChatClientKitTests
//

import Foundation
import Testing
@testable import ChatClient

struct ChatRequestNormalizationTests {
    @Test("Backfills empty content for empty assistant placeholders")
    func backfillsEmptyAssistantPlaceholder() throws {
        let request = ChatRequest(
            messages: [
                .user(content: .text("hello")),
                .assistant(content: nil, toolCalls: nil, reasoning: nil),
            ]
        )

        let body = try request.asChatRequestBody()

        #expect(body.messages.count == 2)
        if case let .user(content, _) = body.messages[0] {
            if case let .text(text) = content {
                #expect(text == "hello")
            } else {
                #expect(Bool(false), "Expected text user content")
            }
        } else {
            #expect(Bool(false), "Expected first message to be user")
        }

        if case let .assistant(content, toolCalls, reasoning, _) = body.messages[1] {
            #expect(toolCalls == nil)
            #expect(reasoning == nil)
            if case let .text(text) = content {
                #expect(text.isEmpty)
            } else {
                #expect(Bool(false), "Expected empty assistant content text")
            }
        } else {
            #expect(Bool(false), "Expected second message to be assistant")
        }
    }

    @Test("Backfills empty content for reasoning-only assistant messages")
    func backfillsEmptyContentForReasoningOnlyAssistant() throws {
        let request = ChatRequest(
            messages: [
                .assistant(content: nil, toolCalls: nil, reasoning: "thinking..."),
            ]
        )

        let body = try request.asChatRequestBody()
        #expect(body.messages.count == 1)

        if case let .assistant(content, toolCalls, reasoning, _) = body.messages[0] {
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
}
