//
//  FinishReason.swift
//  ChatUI
//
//  Tracks why model generation stopped, inspired by Vercel AI SDK.
//

import Foundation

/// The reason a model stopped generating output.
public enum FinishReason: String, Sendable, Hashable {
    /// Natural stop (end of response).
    case stop
    /// Hit the maximum token/context length.
    case length
    /// The model requested tool calls.
    case toolCalls
    /// Content was filtered by safety systems.
    case contentFilter
    /// An error occurred during generation.
    case error
    /// The generation was cancelled or interrupted by the user or system.
    case cancelled
    /// Reason is unknown or not reported.
    case unknown
}
