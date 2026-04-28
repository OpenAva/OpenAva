import ChatClient
import ChatUI
import Foundation

/// Per-million-token pricing for a model.
struct ModelCostTier {
    /// USD per 1 million input tokens.
    let inputPerMillion: Double
    /// USD per 1 million output tokens.
    let outputPerMillion: Double
    /// USD per 1 million prompt-cache-read tokens.
    let cacheReadPerMillion: Double
    /// USD per 1 million prompt-cache-write tokens.
    let cacheWritePerMillion: Double
}

/// Looks up model pricing and calculates USD cost for a given `TokenUsage`.
///
/// Pricing data is sourced from public provider documentation.
/// References: https://platform.openai.com/docs/pricing, https://platform.claude.com/docs/en/about-claude/pricing
enum TokenCostCalculator {
    // MARK: - Price Table

    /// Known pricing tiers. Keyed by lowercase model-name prefix for flexible substring matching.
    private static let priceTiers: [(prefix: String, tier: ModelCostTier)] = [
        // Anthropic Claude
        ("claude-opus-4-6", ModelCostTier(inputPerMillion: 5, outputPerMillion: 25, cacheReadPerMillion: 0.5, cacheWritePerMillion: 6.25)),
        ("claude-opus-4-5", ModelCostTier(inputPerMillion: 5, outputPerMillion: 25, cacheReadPerMillion: 0.5, cacheWritePerMillion: 6.25)),
        ("claude-opus-4-1", ModelCostTier(inputPerMillion: 15, outputPerMillion: 75, cacheReadPerMillion: 1.5, cacheWritePerMillion: 18.75)),
        ("claude-opus-4", ModelCostTier(inputPerMillion: 15, outputPerMillion: 75, cacheReadPerMillion: 1.5, cacheWritePerMillion: 18.75)),
        ("claude-sonnet-4", ModelCostTier(inputPerMillion: 3, outputPerMillion: 15, cacheReadPerMillion: 0.3, cacheWritePerMillion: 3.75)),
        ("claude-3-7-sonnet", ModelCostTier(inputPerMillion: 3, outputPerMillion: 15, cacheReadPerMillion: 0.3, cacheWritePerMillion: 3.75)),
        ("claude-3-5-sonnet", ModelCostTier(inputPerMillion: 3, outputPerMillion: 15, cacheReadPerMillion: 0.3, cacheWritePerMillion: 3.75)),
        ("claude-haiku-4-5", ModelCostTier(inputPerMillion: 1, outputPerMillion: 5, cacheReadPerMillion: 0.1, cacheWritePerMillion: 1.25)),
        ("claude-3-5-haiku", ModelCostTier(inputPerMillion: 0.8, outputPerMillion: 4, cacheReadPerMillion: 0.08, cacheWritePerMillion: 1.0)),
        ("claude-3-haiku", ModelCostTier(inputPerMillion: 0.25, outputPerMillion: 1.25, cacheReadPerMillion: 0.03, cacheWritePerMillion: 0.3)),

        // OpenAI
        ("gpt-4.1-mini", ModelCostTier(inputPerMillion: 0.4, outputPerMillion: 1.6, cacheReadPerMillion: 0.1, cacheWritePerMillion: 0)),
        ("gpt-4.1-nano", ModelCostTier(inputPerMillion: 0.1, outputPerMillion: 0.4, cacheReadPerMillion: 0.025, cacheWritePerMillion: 0)),
        ("gpt-4.1", ModelCostTier(inputPerMillion: 2, outputPerMillion: 8, cacheReadPerMillion: 0.5, cacheWritePerMillion: 0)),
        ("gpt-4o-mini", ModelCostTier(inputPerMillion: 0.15, outputPerMillion: 0.6, cacheReadPerMillion: 0.075, cacheWritePerMillion: 0)),
        ("gpt-4o", ModelCostTier(inputPerMillion: 2.5, outputPerMillion: 10, cacheReadPerMillion: 1.25, cacheWritePerMillion: 0)),
        ("o4-mini", ModelCostTier(inputPerMillion: 1.1, outputPerMillion: 4.4, cacheReadPerMillion: 0.275, cacheWritePerMillion: 0)),
        ("o3-mini", ModelCostTier(inputPerMillion: 1.1, outputPerMillion: 4.4, cacheReadPerMillion: 0.55, cacheWritePerMillion: 0)),
        ("o3", ModelCostTier(inputPerMillion: 10, outputPerMillion: 40, cacheReadPerMillion: 2.5, cacheWritePerMillion: 0)),
        ("o1-mini", ModelCostTier(inputPerMillion: 1.1, outputPerMillion: 4.4, cacheReadPerMillion: 0.55, cacheWritePerMillion: 0)),
        ("o1", ModelCostTier(inputPerMillion: 15, outputPerMillion: 60, cacheReadPerMillion: 7.5, cacheWritePerMillion: 0)),

        // Google Gemini (via public pricing)
        ("gemini-2.5-flash", ModelCostTier(inputPerMillion: 0.15, outputPerMillion: 0.6, cacheReadPerMillion: 0.0375, cacheWritePerMillion: 0)),
        ("gemini-2.5-pro", ModelCostTier(inputPerMillion: 1.25, outputPerMillion: 10, cacheReadPerMillion: 0.31, cacheWritePerMillion: 0)),
        ("gemini-2.0-flash", ModelCostTier(inputPerMillion: 0.1, outputPerMillion: 0.4, cacheReadPerMillion: 0.025, cacheWritePerMillion: 0)),
        ("gemini-1.5-flash", ModelCostTier(inputPerMillion: 0.075, outputPerMillion: 0.3, cacheReadPerMillion: 0.02, cacheWritePerMillion: 0)),
        ("gemini-1.5-pro", ModelCostTier(inputPerMillion: 1.25, outputPerMillion: 5, cacheReadPerMillion: 0.31, cacheWritePerMillion: 0)),

        // DeepSeek V4
        ("deepseek-v4-flash", ModelCostTier(inputPerMillion: 0.14, outputPerMillion: 0.28, cacheReadPerMillion: 0.0028, cacheWritePerMillion: 0)),
        ("deepseek-v4-pro", ModelCostTier(inputPerMillion: 1.74, outputPerMillion: 3.48, cacheReadPerMillion: 0.0145, cacheWritePerMillion: 0)),

        // xAI Grok
        ("grok-3-mini", ModelCostTier(inputPerMillion: 0.3, outputPerMillion: 0.5, cacheReadPerMillion: 0, cacheWritePerMillion: 0)),
        ("grok-3", ModelCostTier(inputPerMillion: 3, outputPerMillion: 15, cacheReadPerMillion: 0, cacheWritePerMillion: 0)),
        ("grok-2", ModelCostTier(inputPerMillion: 2, outputPerMillion: 10, cacheReadPerMillion: 0, cacheWritePerMillion: 0)),

        // Moonshot (Kimi)
        ("moonshot-v1-128k", ModelCostTier(inputPerMillion: 1.0, outputPerMillion: 3.0, cacheReadPerMillion: 0, cacheWritePerMillion: 0)),
        ("moonshot-v1-32k", ModelCostTier(inputPerMillion: 0.4, outputPerMillion: 1.2, cacheReadPerMillion: 0, cacheWritePerMillion: 0)),
        ("moonshot-v1-8k", ModelCostTier(inputPerMillion: 0.12, outputPerMillion: 0.36, cacheReadPerMillion: 0, cacheWritePerMillion: 0)),
    ]

    // MARK: - Lookup

    /// Returns the cost tier for a given model identifier, or nil if unknown.
    static func costTier(for model: String) -> ModelCostTier? {
        let lower = model.lowercased()
        for (prefix, tier) in priceTiers where lower.contains(prefix) {
            return tier
        }
        return nil
    }

    // MARK: - Calculation

    /// Calculates estimated USD cost for the given `TokenUsage` and model.
    ///
    /// Returns nil when the model is not in the price table.
    static func calculateCost(usage: TokenUsage, model: String) -> Double? {
        guard let tier = costTier(for: model) else { return nil }
        return calculateCost(usage: usage, tier: tier)
    }

    /// Calculates estimated USD cost using an explicit `ModelCostTier`.
    static func calculateCost(usage: TokenUsage, tier: ModelCostTier) -> Double {
        let m = 1_000_000.0
        return Double(usage.inputTokens) / m * tier.inputPerMillion
            + Double(usage.outputTokens) / m * tier.outputPerMillion
            + Double(usage.cacheReadTokens) / m * tier.cacheReadPerMillion
            + Double(usage.cacheWriteTokens) / m * tier.cacheWritePerMillion
    }
}
