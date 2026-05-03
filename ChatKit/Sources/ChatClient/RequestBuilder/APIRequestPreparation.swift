import Foundation

public enum APIProvider: Sendable, Equatable {
    case openAICompatible
    case openAIResponses
    case anthropic
    case deepSeek
    case moonshot
}

public struct APIRequestPreparationOptions: Sendable, Equatable {
    public static let defaultMaxImageBase64Size = 5 * 1024 * 1024

    public var provider: APIProvider
    public var strictToolResultPairing: Bool
    public var maxImageBase64Size: Int

    public init(
        provider: APIProvider,
        strictToolResultPairing: Bool = false,
        maxImageBase64Size: Int = Self.defaultMaxImageBase64Size
    ) {
        self.provider = provider
        self.strictToolResultPairing = strictToolResultPairing
        self.maxImageBase64Size = maxImageBase64Size
    }
}

public enum APIRequestPreparationError: Error, LocalizedError, Equatable {
    case toolResultPairingMismatch(String)
    case imageTooLarge(index: Int, base64Size: Int, maxSize: Int)

    public var errorDescription: String? {
        switch self {
        case let .toolResultPairingMismatch(details):
            "tool_use/tool_result pairing mismatch detected. \(details)"
        case let .imageTooLarge(index, base64Size, maxSize):
            "Image \(index) base64 size \(base64Size) exceeds API limit \(maxSize)."
        }
    }
}

public let SYNTHETIC_TOOL_RESULT_PLACEHOLDER = "[Tool result missing due to internal error]"

public extension ChatRequestBody {
    func preparingForAPI(_ options: APIRequestPreparationOptions) throws -> ChatRequestBody {
        var body = self
        body.messages = body.normalizeMessagesForAPI(provider: options.provider)
        body.messages = try body.ensureToolResultPairing(
            body.messages,
            strict: options.strictToolResultPairing
        )
        try body.validateImagesForAPI(maxBase64Size: options.maxImageBase64Size)
        return body
    }

    func normalizeMessagesForAPI(provider: APIProvider) -> [Message] {
        ChatRequest.mergeAssistantMessages(messages)
            .compactMap { normalizeMessageForAPI($0, provider: provider) }
    }

    func validateImagesForAPI(maxBase64Size: Int = APIRequestPreparationOptions.defaultMaxImageBase64Size) throws {
        var imageIndex = 0
        for message in messages {
            guard case let .user(content, _) = message else { continue }
            let parts: [Message.ContentPart] = switch content {
            case let .text(text): [.text(text)]
            case let .parts(parts): parts
            }
            for part in parts {
                guard case let .imageURL(url, _) = part else { continue }
                imageIndex += 1
                guard let base64Size = Self.imageBase64Size(from: url) else { continue }
                if base64Size > maxBase64Size {
                    throw APIRequestPreparationError.imageTooLarge(
                        index: imageIndex,
                        base64Size: base64Size,
                        maxSize: maxBase64Size
                    )
                }
            }
        }
    }
}

extension ChatRequestBody {
    func ensureToolResultPairing(
        _ messages: [Message],
        strict: Bool
    ) throws -> [Message] {
        var result: [Message] = []
        var index = 0
        var seenToolCallIDs = Set<String>()

        func failOrRepair(_ details: String) throws {
            if strict {
                throw APIRequestPreparationError.toolResultPairingMismatch(details)
            }
        }

        while index < messages.count {
            let message = messages[index]
            switch message {
            case let .assistant(content, toolCalls, reasoning, thinkingBlocks):
                let normalizedToolCalls = try normalizedAssistantToolCalls(
                    toolCalls,
                    seenToolCallIDs: &seenToolCallIDs,
                    failOrRepair: failOrRepair
                )
                let toolCallIDs = normalizedToolCalls.map(\.id)
                result.append(
                    .assistant(
                        content: content,
                        toolCalls: normalizedToolCalls.isEmpty ? nil : normalizedToolCalls,
                        reasoning: reasoning,
                        thinkingBlocks: thinkingBlocks
                    )
                )
                index += 1

                guard !toolCallIDs.isEmpty else {
                    continue
                }

                var emittedToolResultIDs = Set<String>()
                var toolResultsToAppend: [Message] = []
                while index < messages.count {
                    guard case let .tool(toolContent, toolCallID) = messages[index] else {
                        break
                    }
                    index += 1
                    guard toolCallIDs.contains(toolCallID) else {
                        try failOrRepair("orphaned tool_result id=\(toolCallID)")
                        continue
                    }
                    guard !emittedToolResultIDs.contains(toolCallID) else {
                        try failOrRepair("duplicate tool_result id=\(toolCallID)")
                        continue
                    }
                    emittedToolResultIDs.insert(toolCallID)
                    toolResultsToAppend.append(.tool(content: toolContent, toolCallID: toolCallID))
                }

                for missingID in toolCallIDs where !emittedToolResultIDs.contains(missingID) {
                    try failOrRepair("missing tool_result id=\(missingID)")
                    toolResultsToAppend.append(
                        .tool(
                            content: .text(SYNTHETIC_TOOL_RESULT_PLACEHOLDER),
                            toolCallID: missingID
                        )
                    )
                }
                result.append(contentsOf: toolResultsToAppend)

            case let .tool(_, toolCallID):
                try failOrRepair("orphaned tool_result id=\(toolCallID)")
                index += 1

            default:
                result.append(message)
                index += 1
            }
        }

        return result
    }

    private func normalizedAssistantToolCalls(
        _ toolCalls: [Message.ToolCall]?,
        seenToolCallIDs: inout Set<String>,
        failOrRepair: (String) throws -> Void
    ) throws -> [Message.ToolCall] {
        guard let toolCalls, !toolCalls.isEmpty else { return [] }
        var result: [Message.ToolCall] = []
        var localIDs = Set<String>()
        for call in toolCalls {
            let id = Self.trimmed(call.id) ?? call.id
            let name = Self.trimmed(call.function.name) ?? call.function.name
            guard !localIDs.contains(id), !seenToolCallIDs.contains(id) else {
                try failOrRepair("duplicate tool_use id=\(id)")
                continue
            }
            localIDs.insert(id)
            seenToolCallIDs.insert(id)
            result.append(
                .init(
                    id: id,
                    function: .init(
                        name: name,
                        arguments: Self.trimmed(call.function.arguments)
                    )
                )
            )
        }
        return result
    }

    private func normalizeMessageForAPI(_ message: Message, provider: APIProvider) -> Message? {
        switch message {
        case let .assistant(content, toolCalls, reasoning, thinkingBlocks):
            let normalizedContent = Self.normalizeAssistantContent(content)
            let normalizedToolCalls = Self.normalizeToolCallsPreservingOrder(toolCalls)
            let keepsReasoning = Self.providerKeepsReasoning(provider, toolCalls: normalizedToolCalls)
            let normalizedReasoning = keepsReasoning ? Self.trimmed(reasoning) : nil
            let keepsThinkingBlocks = provider == .anthropic
            let hasToolCalls = !(normalizedToolCalls?.isEmpty ?? true)
            let resolvedContent = normalizedContent ?? (hasToolCalls ? .text("") : .text(""))
            return .assistant(
                content: resolvedContent,
                toolCalls: hasToolCalls ? normalizedToolCalls : nil,
                reasoning: normalizedReasoning,
                thinkingBlocks: keepsThinkingBlocks ? thinkingBlocks : nil
            )

        case let .developer(content, name):
            return .developer(content: Self.normalizeTextContent(content), name: Self.trimmed(name))

        case let .system(content, name):
            return .system(content: Self.normalizeTextContent(content), name: Self.trimmed(name))

        case let .tool(content, toolCallID):
            return .tool(
                content: Self.normalizeTextContent(content),
                toolCallID: Self.trimmed(toolCallID) ?? toolCallID
            )

        case let .user(content, name):
            return .user(content: Self.normalizeUserContent(content), name: Self.trimmed(name))
        }
    }

    private static func providerKeepsReasoning(_ provider: APIProvider, toolCalls: [Message.ToolCall]?) -> Bool {
        switch provider {
        case .anthropic, .deepSeek:
            true
        case .moonshot:
            !(toolCalls?.isEmpty ?? true)
        case .openAICompatible, .openAIResponses:
            false
        }
    }

    private static func normalizeAssistantContent(
        _ content: Message.MessageContent<String, [String]>?
    ) -> Message.MessageContent<String, [String]>? {
        guard let content else { return nil }
        switch content {
        case let .text(text):
            guard let normalized = trimmed(text) else { return nil }
            return .text(normalized)
        case let .parts(parts):
            let normalized = parts.compactMap(trimmed)
            return normalized.isEmpty ? nil : .parts(normalized)
        }
    }

    private static func normalizeTextContent(
        _ content: Message.MessageContent<String, [String]>
    ) -> Message.MessageContent<String, [String]> {
        switch content {
        case let .text(text):
            .text(trimmed(text) ?? "")
        case let .parts(parts):
            .parts(parts.compactMap(trimmed))
        }
    }

    private static func normalizeUserContent(
        _ content: Message.MessageContent<String, [Message.ContentPart]>
    ) -> Message.MessageContent<String, [Message.ContentPart]> {
        switch content {
        case let .text(text):
            return .text(trimmed(text) ?? "")
        case let .parts(parts):
            let normalized = parts.compactMap(normalizeContentPart)
            return normalized.isEmpty ? .text("") : .parts(normalized)
        }
    }

    private static func normalizeContentPart(_ part: Message.ContentPart) -> Message.ContentPart? {
        switch part {
        case let .text(text):
            guard let normalized = trimmed(text) else { return nil }
            return .text(normalized)
        case let .imageURL(url, detail):
            return .imageURL(url, detail: detail)
        case let .audioBase64(data, format):
            guard let normalized = trimmed(data) else { return nil }
            return .audioBase64(normalized, format: format)
        }
    }

    private static func normalizeToolCallsPreservingOrder(
        _ toolCalls: [Message.ToolCall]?
    ) -> [Message.ToolCall]? {
        guard let toolCalls, !toolCalls.isEmpty else { return nil }
        let normalized = toolCalls.map { call in
            Message.ToolCall(
                id: trimmed(call.id) ?? call.id,
                function: .init(
                    name: trimmed(call.function.name) ?? call.function.name,
                    arguments: trimmed(call.function.arguments)
                )
            )
        }
        return normalized.isEmpty ? nil : normalized
    }

    private static func imageBase64Size(from url: URL) -> Int? {
        let value = url.absoluteString
        guard value.hasPrefix("data:"),
              let commaIndex = value.firstIndex(of: ",")
        else {
            return nil
        }
        return value[value.index(after: commaIndex)...].count
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        return trimmed(value)
    }

    private static func trimmed(_ value: String) -> String? {
        let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }
}
