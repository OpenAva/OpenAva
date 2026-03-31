//
//  ChatResponse.swift
//  ChatClient
//
//  Created by qaq on 7/12/2025.
//

import Foundation

public struct ChatResponse: Sendable, Equatable {
    public var reasoning: String
    public var text: String
    public var images: [ImageContent]
    public var tools: [ToolRequest]

    /// Structured thinking blocks from Anthropic extended thinking.
    /// Contains thinking text with signatures, and optionally redacted blocks.
    /// Must be preserved and passed back in multi-turn tool-use conversations.
    /// See: https://docs.anthropic.com/en/docs/build-with-claude/extended-thinking#multi-turn-conversations
    public var thinkingBlocks: [ThinkingBlockContent]

    /// Token usage for this response, emitted by the provider at the end of the stream.
    public var usage: TokenUsage?

    /// A thinking block content item from the Anthropic API response.
    public enum ThinkingBlockContent: Sendable, Equatable {
        /// A thinking block with plaintext reasoning and its verification signature.
        case thinking(ThinkingBlock)
        /// A redacted (encrypted) thinking block. Must be preserved verbatim.
        case redactedThinking(data: String)
    }

    public init(
        reasoning: String,
        text: String,
        images: [ImageContent],
        tools: [ToolRequest],
        thinkingBlocks: [ThinkingBlockContent] = [],
        usage: TokenUsage? = nil
    ) {
        self.reasoning = reasoning
        self.text = text
        self.images = images
        self.tools = tools
        self.thinkingBlocks = thinkingBlocks
        self.usage = usage
    }

    public init(chunks: [ChatResponseChunk]) {
        var reasoning = ""
        var text = ""
        var images: [ImageContent] = []
        var tools: [ToolRequest] = []
        var thinkingBlocks: [ThinkingBlockContent] = []
        var usage: TokenUsage?
        for chunk in chunks {
            switch chunk {
            case let .reasoning(string): reasoning += string
            case let .text(string): text += string
            case let .image(imageContent): images.append(imageContent)
            case let .tool(toolRequest): tools.append(toolRequest)
            case let .thinkingBlock(block): thinkingBlocks.append(.thinking(block))
            case let .redactedThinking(data): thinkingBlocks.append(.redactedThinking(data: data))
            case let .usage(u): usage = usage?.adding(u) ?? u
            }
        }
        self.reasoning = reasoning
        self.text = text
        self.images = images
        self.tools = tools
        self.thinkingBlocks = thinkingBlocks
        self.usage = usage
    }
}
