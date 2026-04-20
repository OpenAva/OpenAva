//  Context window management — aligned with Claude Code thresholds/state.

import ChatClient
import ChatUI
import Foundation
import OSLog

private let autoCompactLogger = Logger(subsystem: "ChatUI", category: "AutoCompact")
private let tokenEstimator = ApproximateTokenEstimator()
private let maxOutputTokensForSummary = 20000
private let autoCompactBufferTokens = 13000
private let warningThresholdBufferTokens = 20000
private let errorThresholdBufferTokens = 20000
private let manualCompactBufferTokens = 3000
private let maxConsecutiveAutoCompactFailures = 3

struct AutoCompactResult {
    let wasCompacted: Bool
    let compactionResult: CompactionResult?
    let consecutiveFailures: Int?
}

struct AutoCompactTrackingState {
    var compacted = false
    var turnCounter = 0
    var turnId = ""
    var consecutiveFailures = 0
}

struct TokenWarningState {
    let percentLeft: Int
    let isAboveWarningThreshold: Bool
    let isAboveErrorThreshold: Bool
    let isAboveAutoCompactThreshold: Bool
    let isAtBlockingLimit: Bool
}

private actor ApproximateTokenEstimator {
    func count(for text: String) -> Int {
        guard !text.isEmpty else { return 1 }
        return max(1, Int(ceil(Double(text.utf8.count) / 4.0)))
    }
}

extension ConversationSession {
    func getReservedTokensForSummary(for model: ConversationSession.Model) -> Int {
        min(maxOutputTokensForSummary, max(model.maxOutputTokens, 0))
    }

    func getEffectiveContextWindowSize(for model: ConversationSession.Model) -> Int {
        max(model.contextLength - getReservedTokensForSummary(for: model), 0)
    }

    func getAutoCompactThreshold(for model: ConversationSession.Model) -> Int {
        max(0, getEffectiveContextWindowSize(for: model) - autoCompactBufferTokens)
    }

    func getBlockingLimit(for model: ConversationSession.Model) -> Int {
        max(0, getEffectiveContextWindowSize(for: model) - manualCompactBufferTokens)
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
            percentLeft = max(
                0,
                Int(
                    round(
                        (Double(threshold - tokenUsage) / Double(threshold)) * 100
                    )
                )
            )
        } else {
            percentLeft = 0
        }

        let warningThreshold = threshold - warningThresholdBufferTokens
        let errorThreshold = threshold - errorThresholdBufferTokens
        let blockingLimit = getBlockingLimit(for: model)

        return TokenWarningState(
            percentLeft: percentLeft,
            isAboveWarningThreshold: tokenUsage >= warningThreshold,
            isAboveErrorThreshold: tokenUsage >= errorThreshold,
            isAboveAutoCompactThreshold: isAutoCompactEnabled(for: model) && tokenUsage >= autoCompactThreshold,
            isAtBlockingLimit: tokenUsage >= blockingLimit
        )
    }

    func isAutoCompactEnabled(for model: ConversationSession.Model) -> Bool {
        model.autoCompactEnabled
    }

    func shouldAutoCompact(
        requestMessages: [ChatRequestBody.Message],
        tools: [ChatRequestBody.Tool]?,
        model: ConversationSession.Model,
        querySource: QuerySource? = nil
    ) async -> Bool {
        guard querySource != .compact, querySource != .sessionMemory else {
            return false
        }
        guard isAutoCompactEnabled(for: model) else {
            return false
        }
        guard model.contextLength > 0 else {
            return false
        }

        let estimatedTokens = await estimateTokenCount(messages: requestMessages, tools: tools)
        let warningState = calculateTokenWarningState(tokenUsage: estimatedTokens, model: model)
        return warningState.isAboveAutoCompactThreshold
    }

    func currentRecompactionInfo(
        for model: ConversationSession.Model,
        querySource: QuerySource?,
        tracking: AutoCompactTrackingState?
    ) -> RecompactionInfo {
        let trackingState = tracking ?? AutoCompactTrackingState()
        return RecompactionInfo(
            isRecompactionInChain: trackingState.compacted,
            turnsSincePreviousCompact: trackingState.compacted ? trackingState.turnCounter : -1,
            previousCompactTurnId: trackingState.compacted
                ? (trackingState.turnId.isEmpty ? nil : trackingState.turnId)
                : nil,
            autoCompactThreshold: getAutoCompactThreshold(for: model),
            querySource: querySource
        )
    }

    func resetAutoCompactTracking() {
        autoCompactTrackingState = AutoCompactTrackingState()
    }

    private func performAutoCompact(
        _ requestMessages: inout [ChatRequestBody.Message],
        tools: [ChatRequestBody.Tool]?,
        model: ConversationSession.Model,
        querySource: QuerySource?,
        tracking: AutoCompactTrackingState?,
        requireThreshold: Bool,
        reason: String
    ) async -> AutoCompactResult {
        let trackingState = tracking ?? AutoCompactTrackingState()

        guard trackingState.consecutiveFailures < maxConsecutiveAutoCompactFailures else {
            autoCompactLogger.warning("autocompact circuit breaker active; skipping session=\(self.id, privacy: .public)")
            return AutoCompactResult(wasCompacted: false, compactionResult: nil, consecutiveFailures: nil)
        }

        if requireThreshold {
            let shouldCompact = await shouldAutoCompact(
                requestMessages: requestMessages,
                tools: tools,
                model: model,
                querySource: querySource
            )
            guard shouldCompact else {
                return AutoCompactResult(wasCompacted: false, compactionResult: nil, consecutiveFailures: nil)
            }
        }

        let estimatedTokens = await estimateTokenCount(messages: requestMessages, tools: tools)

        let threshold = getAutoCompactThreshold(for: model)
        let effectiveWindow = getEffectiveContextWindowSize(for: model)
        autoCompactLogger.info(
            "autocompact start session=\(self.id, privacy: .public) reason=\(reason, privacy: .public) tokens=\(estimatedTokens) threshold=\(threshold) effectiveWindow=\(effectiveWindow)"
        )

        do {
            let result = try await compactConversation(
                model: model,
                trigger: "auto",
                preTokens: estimatedTokens,
                suppressFollowUpQuestions: true,
                isAutoCompact: true,
                recompactionInfo: currentRecompactionInfo(for: model, querySource: querySource, tracking: trackingState)
            )
            let rebuiltMessageCount = buildPostCompactMessages(result).count
            autoCompactLogger.info(
                "autocompact complete session=\(self.id, privacy: .public) reason=\(reason, privacy: .public) rebuiltMessages=\(rebuiltMessageCount)"
            )
            return AutoCompactResult(wasCompacted: true, compactionResult: result, consecutiveFailures: 0)
        } catch is CancellationError {
            return AutoCompactResult(wasCompacted: false, compactionResult: nil, consecutiveFailures: nil)
        } catch {
            let nextFailures = trackingState.consecutiveFailures + 1
            autoCompactLogger.error(
                "autocompact failed session=\(self.id, privacy: .public) reason=\(reason, privacy: .public) failures=\(nextFailures) error=\(error.localizedDescription, privacy: .public)"
            )
            return AutoCompactResult(wasCompacted: false, compactionResult: nil, consecutiveFailures: nextFailures)
        }
    }

    func autoCompactIfNeeded(
        _ requestMessages: inout [ChatRequestBody.Message],
        tools: [ChatRequestBody.Tool]?,
        model: ConversationSession.Model,
        tracking: AutoCompactTrackingState? = nil,
        querySource: QuerySource? = nil
    ) async -> AutoCompactResult {
        await performAutoCompact(
            &requestMessages,
            tools: tools,
            model: model,
            querySource: querySource,
            tracking: tracking,
            requireThreshold: true,
            reason: "proactive"
        )
    }

    func reactiveCompactIfNeeded(
        _ requestMessages: inout [ChatRequestBody.Message],
        tools: [ChatRequestBody.Tool]?,
        model: ConversationSession.Model,
        querySource: QuerySource? = nil
    ) async -> AutoCompactResult {
        guard querySource != .compact, querySource != .sessionMemory else {
            return AutoCompactResult(wasCompacted: false, compactionResult: nil, consecutiveFailures: nil)
        }
        guard isAutoCompactEnabled(for: model) else {
            return AutoCompactResult(wasCompacted: false, compactionResult: nil, consecutiveFailures: nil)
        }

        let estimatedTokens = await estimateTokenCount(messages: requestMessages, tools: tools)
        let threshold = getAutoCompactThreshold(for: model)
        let effectiveWindow = getEffectiveContextWindowSize(for: model)
        autoCompactLogger.info(
            "autocompact start session=\(self.id, privacy: .public) reason=reactive tokens=\(estimatedTokens) threshold=\(threshold) effectiveWindow=\(effectiveWindow)"
        )

        do {
            let result = try await compactConversation(
                model: model,
                trigger: "auto",
                preTokens: estimatedTokens,
                suppressFollowUpQuestions: true,
                isAutoCompact: true,
                recompactionInfo: nil
            )
            let rebuiltMessageCount = buildPostCompactMessages(result).count
            autoCompactLogger.info(
                "autocompact complete session=\(self.id, privacy: .public) reason=reactive rebuiltMessages=\(rebuiltMessageCount)"
            )
            return AutoCompactResult(wasCompacted: true, compactionResult: result, consecutiveFailures: nil)
        } catch is CancellationError {
            return AutoCompactResult(wasCompacted: false, compactionResult: nil, consecutiveFailures: nil)
        } catch {
            autoCompactLogger.error(
                "autocompact failed session=\(self.id, privacy: .public) reason=reactive error=\(error.localizedDescription, privacy: .public)"
            )
            return AutoCompactResult(wasCompacted: false, compactionResult: nil, consecutiveFailures: nil)
        }
    }

    func ensureBelowBlockingLimit(
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
                return await 12 + tokenEstimator.count(for: text)
            case let .parts(parts):
                return await 12 + parts.asyncReduce(0) { partialResult, part in
                    await partialResult + estimateTokens(for: part)
                }
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
                await partialResult + tokenEstimator.count(for: part)
            }
        }
    }

    private func estimateTokens(for part: ChatRequestBody.Message.ContentPart) async -> Int {
        switch part {
        case let .text(text):
            await tokenEstimator.count(for: text)
        case .imageURL, .audioBase64:
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
