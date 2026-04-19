//  Typed errors for query and tool execution failures.
import ChatUI
import Foundation

/// Errors that can occur during query execution.
public enum QueryExecutionError: LocalizedError, Sendable {
    /// The model returned no content (no text, reasoning, or tool calls).
    case noResponseFromModel

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
