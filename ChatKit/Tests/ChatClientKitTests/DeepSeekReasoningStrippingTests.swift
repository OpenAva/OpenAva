//
//  DeepSeekReasoningStrippingTests.swift
//  ChatClientKitTests
//
//  Verifies DeepSeek V4 tool-call + reasoning rules:
//
//  - Assistant messages WITH reasoning      → preserve reasoning internally
//  - Outbound payload maps reasoning -> reasoning_content for DeepSeek API
//  - Assistant messages WITH tool_calls     → content must be present ("")
//
//  See: https://api-docs.deepseek.com/guides/reasoning_model
//       https://api-docs.deepseek.com/guides/tool_calls
//

import Foundation
import Testing
@testable import ChatClient

struct DeepSeekReasoningStrippingTests {
    private func prepareForAPI(
        _ client: DeepSeekClient,
        body: ChatRequestBody,
        streaming: Bool
    ) -> ChatRequestBody {
        try! client.applyModelSettings(to: body, streaming: streaming)
            .preparingForAPI(.init(provider: client.apiProvider))
    }

    // MARK: - No tool calls → preserve reasoning

    @Test("DeepSeek resolve preserves reasoning in plain assistant messages (no tool calls)")
    func preserveReasoningFromAssistantMessages() {
        let client = DeepSeekClient(model: "deepseek-v4-flash", apiKey: "test-key")

        let body = ChatRequestBody(
            messages: [
                .system(content: .text("You are helpful.")),
                .user(content: .text("Hello")),
                .assistant(content: .text("Hi there"), reasoning: "Let me think..."),
                .user(content: .text("How are you?")),
            ]
        )

        let resolved = prepareForAPI(client, body: body, streaming: true)

        #expect(resolved.model == "deepseek-v4-flash")
        #expect(resolved.stream == true)

        for message in resolved.messages {
            if case let .assistant(_, toolCalls, reasoning, _) = message {
                let hasToolCalls = toolCalls != nil && !toolCalls!.isEmpty
                if !hasToolCalls {
                    #expect(reasoning != nil, "Reasoning should be preserved in canonical message model")
                }
            }
        }
        #expect(resolved.messages.count == 4)
    }

    // MARK: - With tool calls → preserve reasoning

    /// DeepSeek V3.2 thinking-integrated tool-use:
    /// every assistant message that triggers tool_calls must include reasoning_content
    /// in the follow-up request, or the API returns HTTP 400.
    ///
    /// Ref: https://api-docs.deepseek.com/guides/reasoning_model (Tool Calls section)
    @Test("DeepSeek resolve preserves reasoning in assistant messages that have tool calls")
    func preserveReasoningWithToolCalls() {
        let client = DeepSeekClient(model: "deepseek-v4-flash", apiKey: "test-key")

        let toolCalls: [ChatRequestBody.Message.ToolCall] = [
            .init(id: "call_1", function: .init(name: "get_weather", arguments: "{\"city\":\"Tokyo\"}")),
        ]

        let body = ChatRequestBody(
            messages: [
                .assistant(
                    content: nil,
                    toolCalls: toolCalls,
                    reasoning: "I should use the weather tool to look this up."
                ),
            ]
        )

        let resolved = prepareForAPI(client, body: body, streaming: false)

        if case let .assistant(content, resolvedToolCalls, reasoning, _) = resolved.messages[0] {
            #expect(resolvedToolCalls?.count == 1, "Tool calls should be preserved")
            #expect(
                reasoning == "I should use the weather tool to look this up.",
                "Reasoning must be PRESERVED when tool_calls are present"
            )
            // Content should be injected as "" when originally nil + has tool calls
            if case let .text(text) = content {
                #expect(text == "", "Content must be empty string, not absent")
            } else {
                #expect(Bool(false), "Content should be .text when tool calls are present")
            }
        } else {
            #expect(Bool(false), "Expected assistant message")
        }
    }

    @Test("DeepSeek resolve preserves content and reasoning when tool calls present")
    func preserveContentAndReasoningWithToolCalls() {
        let client = DeepSeekClient(model: "deepseek-v4-flash", apiKey: "test-key")

        let toolCalls: [ChatRequestBody.Message.ToolCall] = [
            .init(id: "call_1", function: .init(name: "get_weather", arguments: "{\"city\":\"Tokyo\"}")),
        ]

        let body = ChatRequestBody(
            messages: [
                .assistant(
                    content: .text("Let me check the weather."),
                    toolCalls: toolCalls,
                    reasoning: "I should look up weather data."
                ),
            ]
        )

        let resolved = prepareForAPI(client, body: body, streaming: false)

        if case let .assistant(content, resolvedToolCalls, reasoning, _) = resolved.messages[0] {
            if case let .text(text) = content {
                #expect(text == "Let me check the weather.", "Existing content must be preserved")
            }
            #expect(resolvedToolCalls?.count == 1, "Tool calls must be preserved")
            #expect(reasoning != nil, "Reasoning must be preserved when tool_calls present")
            #expect(reasoning == "I should look up weather data.")
        } else {
            #expect(Bool(false), "Expected assistant message")
        }
    }

    @Test("DeepSeek resolve preserves reasoning from plain assistant message (no tool calls)")
    func preserveReasoningNoToolCalls() {
        let client = DeepSeekClient(model: "deepseek-v4-flash", apiKey: "test-key")

        let body = ChatRequestBody(
            messages: [
                .assistant(content: .text("The answer is 42."), reasoning: "Let me think..."),
            ]
        )

        let resolved = prepareForAPI(client, body: body, streaming: false)

        if case let .assistant(_, toolCalls, reasoning, _) = resolved.messages[0] {
            let hasToolCalls = toolCalls != nil && !toolCalls!.isEmpty
            #expect(!hasToolCalls, "No tool calls in this message")
            #expect(reasoning == "Let me think...", "Reasoning should be preserved when no tool calls")
        } else {
            #expect(Bool(false), "Expected assistant message")
        }
    }

    @Test("DeepSeek resolve handles mixed: both assistant messages keep reasoning")
    func mixedMessagesSelectiveReasoning() {
        let client = DeepSeekClient(model: "deepseek-v4-flash", apiKey: "test-key")

        let toolCalls: [ChatRequestBody.Message.ToolCall] = [
            .init(id: "call_1", function: .init(name: "search", arguments: "{}")),
        ]

        let body = ChatRequestBody(
            messages: [
                .user(content: .text("Search for cats")),
                // This assistant message HAS tool calls → reasoning preserved
                .assistant(content: nil, toolCalls: toolCalls, reasoning: "I'll search"),
                .tool(content: .text("Results: [...]"), toolCallID: "call_1"),
                // This assistant message has NO tool calls → reasoning still preserved
                .assistant(content: .text("Here are the results."), reasoning: "Let me summarize"),
            ]
        )

        let resolved = prepareForAPI(client, body: body, streaming: false)

        // Index 1: assistant with tool calls → reasoning preserved
        if case let .assistant(_, toolCalls1, reasoning1, _) = resolved.messages[1] {
            #expect(toolCalls1?.isEmpty == false)
            #expect(reasoning1 != nil, "Reasoning must be preserved for tool-call assistant message")
        }
        // Index 3: assistant without tool calls → reasoning preserved in model
        if case let .assistant(_, toolCalls3, reasoning3, _) = resolved.messages[3] {
            #expect(toolCalls3 == nil || toolCalls3!.isEmpty)
            #expect(reasoning3 == "Let me summarize", "Reasoning should be preserved for plain assistant message")
        }
    }

    @Test("DeepSeek encoded JSON preserves reasoning_content in tool-call assistant message")
    func encodedJSONPreservesReasoningWithToolCalls() throws {
        let client = DeepSeekClient(model: "deepseek-v4-flash", apiKey: "test-key")

        let toolCalls: [ChatRequestBody.Message.ToolCall] = [
            .init(id: "call_abc", function: .init(name: "calc", arguments: "{}")),
        ]

        let body = ChatRequestBody(
            messages: [
                .assistant(content: nil, toolCalls: toolCalls, reasoning: "calculating"),
            ]
        )

        let resolved = prepareForAPI(client, body: body, streaming: true)
        // Validate the final outbound payload shape after provider-specific mapping.
        let request = try client.makeURLRequest(body: resolved)
        let data = try #require(request.httpBody)
        let json = try #require(String(data: data, encoding: .utf8))

        #expect(json.contains("\"reasoning_content\":\"calculating\""), "reasoning_content must be present for tool-call messages")
        #expect(!json.contains("\"reasoning\":"), "legacy reasoning field must not be sent to DeepSeek")
        #expect(json.contains("\"content\":\"\""), "content must be empty string not absent")
        #expect(json.contains("\"tool_calls\""), "tool_calls must be present")
    }

    @Test("DeepSeek encoded JSON maps reasoning to reasoning_content without tool calls")
    func encodedJSONMapsReasoningWithoutToolCalls() throws {
        let client = DeepSeekClient(model: "deepseek-v4-flash", apiKey: "test-key")

        let body = ChatRequestBody(
            messages: [
                .assistant(content: .text("Final answer."), reasoning: "chain of thought"),
            ]
        )

        let resolved = prepareForAPI(client, body: body, streaming: true)
        let request = try client.makeURLRequest(body: resolved)
        let data = try #require(request.httpBody)
        let json = try #require(String(data: data, encoding: .utf8))

        #expect(json.contains("\"reasoning_content\":\"chain of thought\""), "reasoning must be sent as reasoning_content")
        #expect(!json.contains("\"reasoning\":"), "legacy reasoning field must not be sent")
    }
}
