//
//  TokenUsage.swift
//  LanguageModelChatUI
//
//  Token usage tracking for inference calls, inspired by Vercel AI SDK.
//

import Foundation

/// Token usage statistics for a single inference call.
public struct TokenUsage: Sendable, Equatable {
    /// Number of tokens in the input/prompt.
    public var inputTokens: Int

    /// Number of tokens in the output/completion.
    public var outputTokens: Int

    /// Tokens read from the provider's prompt cache (billed at a discount).
    public var cacheReadTokens: Int

    /// Tokens written to the provider's prompt cache.
    public var cacheWriteTokens: Int

    /// Estimated USD cost for this usage, if a price table entry exists for the model.
    public var costUSD: Double?

    /// The model identifier that produced this usage record.
    public var model: String?

    /// Total tokens used (input + output).
    public var totalTokens: Int {
        inputTokens + outputTokens
    }

    public init(
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        cacheReadTokens: Int = 0,
        cacheWriteTokens: Int = 0,
        costUSD: Double? = nil,
        model: String? = nil
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.costUSD = costUSD
        self.model = model
    }

    /// Combine two usage records (for multi-step inference).
    public func adding(_ other: TokenUsage) -> TokenUsage {
        TokenUsage(
            inputTokens: inputTokens + other.inputTokens,
            outputTokens: outputTokens + other.outputTokens,
            cacheReadTokens: cacheReadTokens + other.cacheReadTokens,
            cacheWriteTokens: cacheWriteTokens + other.cacheWriteTokens,
            costUSD: (costUSD ?? 0) + (other.costUSD ?? 0),
            model: model ?? other.model
        )
    }
}
