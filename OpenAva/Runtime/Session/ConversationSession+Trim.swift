//  Context window management — removes oldest messages when exceeding limit.

import ChatClient
import ChatUI
import Foundation
import OSLog

private let trimLogger = Logger(subsystem: "ChatUI", category: "Trim")
private let tokenEstimator = ApproximateTokenEstimator()

private actor ApproximateTokenEstimator {
    func count(for text: String) -> Int {
        guard !text.isEmpty else { return 1 }
        return max(1, Int(ceil(Double(text.utf8.count) / 4.0)))
    }
}

extension ConversationSession {
    /// Remove oldest non-system messages to fit within the model's context length.
    func trimToContextLength(
        _ requestMessages: inout [ChatRequestBody.Message],
        tools: [ChatRequestBody.Tool]?,
        maxTokens: Int
    ) async {
        guard maxTokens > 0 else { return }

        let estimatedTokens = await estimateTokenCount(messages: requestMessages, tools: tools)

        // Leave 25% headroom for the response
        let limit = Int(Double(maxTokens) * 0.75)
        guard estimatedTokens > limit else { return }

        var removed = 0
        let protectedIndex = requestMessages.lastIndex(where: { message in
            if case .user = message { return true }
            return false
        })

        while await estimateTokenCount(messages: requestMessages, tools: tools) > limit {
            guard let index = requestMessages.indices.first(where: { index in
                if let protectedIndex, index == protectedIndex { return false }
                switch requestMessages[index] {
                case .system, .developer:
                    return false
                default:
                    return true
                }
            }) else { break }

            requestMessages.remove(at: index)
            removed += 1

            if removed > 100 { break }
        }

        if await estimateTokenCount(messages: requestMessages, tools: tools) > limit {
            trimLogger.warning("request still exceeds context limit after trimming history; latest user message was preserved")
        }

        if removed > 0 {
            let hintMessage = appendNewMessage(role: .system) { msg in
                msg.textContent = String.localized("Some messages have been removed to fit the model context length.")
            }
            _ = hintMessage
        }
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
