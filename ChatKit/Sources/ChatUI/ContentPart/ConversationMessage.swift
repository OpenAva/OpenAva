//
//  ConversationMessage.swift
//  ChatUI
//

import Foundation

/// A message in a session, composed of typed content parts.
public final class ConversationMessage: Identifiable, @unchecked Sendable {
    public let id: String
    public let sessionID: String
    public var role: MessageRole
    public var parts: [ContentPart]
    public var createdAt: Date
    public var metadata: [String: String]

    public init(
        id: String = UUID().uuidString,
        sessionID: String,
        role: MessageRole,
        parts: [ContentPart] = [],
        createdAt: Date = .init(),
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.sessionID = sessionID
        self.role = role
        self.parts = parts
        self.createdAt = createdAt
        self.metadata = metadata
    }
}

// MARK: - Convenience Accessors

public extension ConversationMessage {
    /// The primary text content of this message (first text part).
    var textContent: String {
        get {
            for part in parts {
                if case let .text(textPart) = part {
                    return textPart.text
                }
            }
            return ""
        }
        set {
            for (index, part) in parts.enumerated() {
                if case var .text(textPart) = part {
                    textPart.text = newValue
                    parts[index] = .text(textPart)
                    return
                }
            }
            // Append text part after any existing parts (e.g. reasoning) to preserve emission order.
            parts.append(.text(TextContentPart(text: newValue)))
        }
    }

    /// The finish reason for this message, stored in metadata.
    var finishReason: FinishReason? {
        get {
            guard let raw = metadata["finishReason"] else { return nil }
            return FinishReason(rawValue: raw)
        }
        set {
            metadata["finishReason"] = newValue?.rawValue
        }
    }

    /// Marks a failed model execution message that is only meant for the current UI session.
    var isTransientExecutionError: Bool {
        get { metadata["transientExecutionError"] == "true" }
        set { metadata["transientExecutionError"] = newValue ? "true" : nil }
    }

    /// User-facing title for a transient execution error card.
    var executionErrorTitle: String? {
        get { metadata["executionErrorTitle"] }
        set { metadata["executionErrorTitle"] = newValue }
    }

    /// User-facing summary for a transient execution error card.
    var executionErrorMessage: String? {
        get { metadata["executionErrorMessage"] }
        set { metadata["executionErrorMessage"] = newValue }
    }

    /// Technical details for copying/debugging a transient execution error.
    var executionErrorDetails: String? {
        get { metadata["executionErrorDetails"] }
        set { metadata["executionErrorDetails"] = newValue }
    }

    /// The reasoning content of this message (first reasoning part), if any.
    var reasoningContent: String? {
        get {
            for part in parts {
                if case let .reasoning(rp) = part {
                    return rp.text
                }
            }
            return nil
        }
        set {
            for (index, part) in parts.enumerated() {
                if case var .reasoning(rp) = part {
                    rp.text = newValue ?? ""
                    parts[index] = .reasoning(rp)
                    return
                }
            }
            if let newValue, !newValue.isEmpty {
                parts.append(.reasoning(ReasoningContentPart(text: newValue)))
            }
        }
    }
}
