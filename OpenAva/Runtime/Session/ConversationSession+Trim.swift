//  Context window management — Claude Code style autocompact thresholds.

import ChatClient
import ChatUI
import Foundation
import OSLog

private let autoCompactLogger = Logger(subsystem: "ChatUI", category: "AutoCompact")
private let tokenEstimator = ApproximateTokenEstimator()
private let compactMaxReservedOutputTokens = 20000
private let autoCompactBufferTokens = 13000
private let warningThresholdBufferTokens = 20000
private let errorThresholdBufferTokens = 20000
private let manualCompactBufferTokens = 3000
private let maxConsecutiveAutoCompactFailures = 3

struct AutoCompactTrackingState {
    var compacted = false
    var turnCounter = 0
    var turnID = UUID().uuidString
    var consecutiveFailures = 0
}

struct TokenWarningState {
    let percentLeft: Int
    let isAboveWarningThreshold: Bool
    let isAboveErrorThreshold: Bool
    let isAboveAutoCompactThreshold: Bool
    let isAtBlockingLimit: Bool
}

struct AutoCompactResult {
    let wasCompacted: Bool
    let consecutiveFailures: Int?
}

private actor ApproximateTokenEstimator {
    func count(for text: String) -> Int {
        guard !text.isEmpty else { return 1 }
        return max(1, Int(ceil(Double(text.utf8.count) / 4.0)))
    }
}

extension ConversationSession {
    func getEffectiveContextWindowSize(for model: ConversationSession.Model) -> Int {
        let reservedTokensForSummary = min(compactMaxReservedOutputTokens, max(model.contextLength / 4, 0))
        return max(model.contextLength - reservedTokensForSummary, 0)
    }

    func getAutoCompactThreshold(for model: ConversationSession.Model) -> Int {
        max(0, getEffectiveContextWindowSize(for: model) - autoCompactBufferTokens)
    }

    func getBlockingLimit(for model: ConversationSession.Model) -> Int {
        max(0, getEffectiveContextWindowSize(for: model) - manualCompactBufferTokens)
    }

    func isAutoCompactEnabled(for model: ConversationSession.Model) -> Bool {
        model.autoCompactEnabled
    }

    func calculateTokenWarningState(
        tokenUsage: Int,
        model: ConversationSession.Model
    ) -> TokenWarningState {
        let autoCompactThreshold = getAutoCompactThreshold(for: model)
        let threshold = isAutoCompactEnabled(for: model)
            ? autoCompactThreshold
            : getEffectiveContextWindowSize(for: model)

        let percentLeft: Int
        if threshold > 0 {
            percentLeft = max(0, Int(round((Double(threshold - tokenUsage) / Double(threshold)) * 100)))
        } else {
            percentLeft = 0
        }

        let warningThreshold = max(0, threshold - warningThresholdBufferTokens)
        let errorThreshold = max(0, threshold - errorThresholdBufferTokens)
        let blockingLimit = getBlockingLimit(for: model)

        return TokenWarningState(
            percentLeft: percentLeft,
            isAboveWarningThreshold: tokenUsage >= warningThreshold,
            isAboveErrorThreshold: tokenUsage >= errorThreshold,
            isAboveAutoCompactThreshold: isAutoCompactEnabled(for: model) && tokenUsage >= autoCompactThreshold,
            isAtBlockingLimit: tokenUsage >= blockingLimit
        )
    }

    @discardableResult
    func autoCompactIfNeeded(
        _ requestMessages: inout [ChatRequestBody.Message],
        tools: [ChatRequestBody.Tool]?,
        model: ConversationSession.Model,
        capabilities: Set<ModelCapability>
    ) async -> AutoCompactResult {
        guard isAutoCompactEnabled(for: model) else {
            return .init(wasCompacted: false, consecutiveFailures: nil)
        }
        guard model.contextLength > 0 else {
            return .init(wasCompacted: false, consecutiveFailures: nil)
        }
        guard autoCompactTrackingState.consecutiveFailures < maxConsecutiveAutoCompactFailures else {
            autoCompactLogger.warning("autocompact circuit breaker active; skipping session=\(self.id, privacy: .public)")
            return .init(wasCompacted: false, consecutiveFailures: autoCompactTrackingState.consecutiveFailures)
        }

        let estimatedTokens = await estimateTokenCount(messages: requestMessages, tools: tools)
        let threshold = getAutoCompactThreshold(for: model)
        guard estimatedTokens >= threshold else {
            return .init(wasCompacted: false, consecutiveFailures: nil)
        }

        autoCompactLogger.info(
            "autocompact start session=\(self.id, privacy: .public) tokens=\(estimatedTokens) threshold=\(threshold)"
        )

        do {
            let result = try await compactConversation(
                model: model,
                trigger: "auto",
                preTokens: estimatedTokens,
                tools: tools
            )
            applyCompactionResult(result)
            requestMessages = await buildMessages(capabilities: capabilities)
            autoCompactTrackingState = .init(compacted: true, turnCounter: 0, turnID: UUID().uuidString, consecutiveFailures: 0)
            let rebuiltMessageCount = requestMessages.count
            autoCompactLogger.info(
                "autocompact complete session=\(self.id, privacy: .public) rebuiltMessages=\(rebuiltMessageCount)"
            )
            return .init(wasCompacted: true, consecutiveFailures: 0)
        } catch is CancellationError {
            return .init(wasCompacted: false, consecutiveFailures: autoCompactTrackingState.consecutiveFailures)
        } catch {
            let nextFailures = autoCompactTrackingState.consecutiveFailures + 1
            autoCompactTrackingState.consecutiveFailures = nextFailures
            autoCompactLogger.error(
                "autocompact failed session=\(self.id, privacy: .public) failures=\(nextFailures) error=\(error.localizedDescription, privacy: .public)"
            )
            return .init(wasCompacted: false, consecutiveFailures: nextFailures)
        }
    }

    func ensureCanContinueWithoutCompaction(
        requestMessages: [ChatRequestBody.Message],
        tools: [ChatRequestBody.Tool]?,
        model: ConversationSession.Model
    ) async throws {
        guard !isAutoCompactEnabled(for: model) else { return }
        guard model.contextLength > 0 else { return }

        let estimatedTokens = await estimateTokenCount(messages: requestMessages, tools: tools)
        let warningState = calculateTokenWarningState(tokenUsage: estimatedTokens, model: model)
        guard warningState.isAtBlockingLimit else { return }

        throw QueryExecutionError.contextWindowExceeded(
            message: String.localized(
                "Conversation too long. Use /compact to free space, or enable auto-compact."
            )
        )
    }

    func estimateTokenCount(
        messages: [ChatRequestBody.Message],
        tools: [ChatRequestBody.Tool]?
    ) async -> Int {
        let messageTokens = await messages.asyncReduce(0) { partialResult, message in
            await partialResult + estimateTokens(for: message)
        }

        let toolTokens = await estimateToolTokenCount(tools)

        return max(1, messageTokens + toolTokens)
    }

    func estimateToolTokenCount(_ tools: [ChatRequestBody.Tool]?) async -> Int {
        if let tools,
           let data = try? JSONEncoder().encode(tools),
           let string = String(data: data, encoding: .utf8)
        {
            return await tokenEstimator.count(for: string)
        }
        return 0
    }

    func estimateTokens(for message: ChatRequestBody.Message) async -> Int {
        switch message {
        case let .assistant(content, toolCalls, reasoning, _):
            var total = 12
            if let content {
                total += await estimateTokens(forTextContent: content)
            }
            if let toolCalls, let data = try? JSONEncoder().encode(toolCalls), let string = String(data: data, encoding: .utf8) {
                total += await tokenEstimator.count(for: string)
            }
            if let reasoning {
                total += await tokenEstimator.count(for: reasoning)
            }
            return total

        case let .developer(content, _), let .system(content, _), let .tool(content, _):
            return await 12 + estimateTokens(forTextContent: content)

        case let .user(content, _):
            switch content {
            case let .text(text):
                return await 12 + (tokenEstimator.count(for: text))
            case let .parts(parts):
                return await 12 + (parts.asyncReduce(0) { partialResult, part in
                    await partialResult + estimateTokens(for: part)
                })
            }
        }
    }

    private func estimateTokens(
        forTextContent content: ChatRequestBody.Message.MessageContent<String, [String]>
    ) async -> Int {
        switch content {
        case let .text(text):
            await tokenEstimator.count(for: text)
        case let .parts(parts):
            await parts.asyncReduce(0) { partialResult, part in
                await partialResult + (tokenEstimator.count(for: part))
            }
        }
    }

    private func estimateTokens(for part: ChatRequestBody.Message.ContentPart) async -> Int {
        switch part {
        case let .text(text):
            await tokenEstimator.count(for: text)
        case .imageURL:
            1000
        case .audioBase64:
            1000
        }
    }
}

private extension Sequence {
    func asyncReduce<Result>(
        _ initialResult: Result,
        _ nextPartialResult: @Sendable (Result, Element) async -> Result
    ) async -> Result {
        var accumulator = initialResult
        for element in self {
            accumulator = await nextPartialResult(accumulator, element)
        }
        return accumulator
    }
}
