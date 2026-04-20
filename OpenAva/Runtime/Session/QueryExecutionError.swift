//  Typed errors for query and tool execution failures.
import ChatUI
import Foundation

/// Errors that can occur during query execution.
public enum QueryExecutionError: LocalizedError, Sendable {
    /// The model returned no content (no text, reasoning, or tool calls).
    case noResponseFromModel

    /// The active context is too large to continue without compaction.
    case contextWindowExceeded(message: String)

    /// Tool execution was attempted without an available provider.
    case toolProviderUnavailable

    /// A tool call referenced a tool that could not be found.
    case toolNotFound(name: String)

    /// A tool execution threw an error.
    case toolExecutionFailed(name: String, underlyingDescription: String)

    /// The query was cancelled by the user or system.
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .noResponseFromModel:
            String.localized("No response from model.")
        case let .contextWindowExceeded(message):
            message
        case .toolProviderUnavailable:
            String.localized("Tool execution is unavailable.")
        case let .toolNotFound(name):
            String.localized("Unable to find tool: \(name)")
        case let .toolExecutionFailed(name, description):
            String.localized("Tool \(name) failed: \(description)")
        case .cancelled:
            String.localized("Query execution was cancelled.")
        }
    }
}

func isPromptTooLongError(_ error: Error) -> Bool {
    let message = error.localizedDescription.lowercased()
    return message.contains("prompt too long") ||
        message.contains("maximum context length") ||
        message.contains("context_length_exceeded") ||
        message.contains("reduce the length of the messages") ||
        message.contains("too many tokens")
}

func parsePromptTooLongTokenCounts(from rawMessage: String) -> (actualTokens: Int?, limitTokens: Int?) {
    let pattern = #"prompt is too long[^0-9]*(\d+)\s*tokens?\s*>\s*(\d+)"#
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
        return (nil, nil)
    }

    let rawRange = NSRange(rawMessage.startIndex ..< rawMessage.endIndex, in: rawMessage)
    guard let match = regex.firstMatch(in: rawMessage, options: [], range: rawRange),
          let actualRange = Range(match.range(at: 1), in: rawMessage),
          let limitRange = Range(match.range(at: 2), in: rawMessage)
    else {
        return (nil, nil)
    }

    return (Int(rawMessage[actualRange]), Int(rawMessage[limitRange]))
}

func getPromptTooLongTokenGap(from error: Error) -> Int? {
    let counts = parsePromptTooLongTokenCounts(from: error.localizedDescription)
    guard let actualTokens = counts.actualTokens,
          let limitTokens = counts.limitTokens
    else {
        return nil
    }
    let gap = actualTokens - limitTokens
    return gap > 0 ? gap : nil
}
