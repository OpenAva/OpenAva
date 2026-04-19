import ChatClient
import ChatUI
import Foundation
import OSLog

private let requestBuildLogger = Logger(subsystem: "ChatUI", category: "RequestBuild")

extension ConversationSession {
    /// Build request messages from conversation history only.
    func buildHistoryRequestMessages(capabilities: Set<ModelCapability>) -> [ChatRequestBody.Message] {
        requestHistoryMessages().flatMap { buildRequestMessages(from: $0, capabilities: capabilities) }
    }

    /// Build the full request payload for execution by combining history and
    /// the current instruction message in one pass.
    func buildExecutionRequestMessages(capabilities: Set<ModelCapability>) async -> [ChatRequestBody.Message] {
        var requestMessages = buildHistoryRequestMessages(capabilities: capabilities)
        guard let instructionMessage = await buildInstructionRequestMessage(
            for: requestMessages,
            capabilities: capabilities
        ) else {
            return requestMessages
        }

        let insertIndex = requestMessages.lastIndex { message in
            switch message {
            case .system, .developer:
                true
            default:
                false
            }
        }.map { $0 + 1 } ?? 0
        requestMessages.insert(instructionMessage, at: insertIndex)
        return requestMessages
    }

    func requestHistoryMessages() -> [ConversationMessage] {
        messages
            .messagesAfterLatestCompactBoundary(includingBoundary: false)
            .filter { !$0.isCompactBoundary }
    }

    func buildRequestMessages(
        from message: ConversationMessage,
        capabilities: Set<ModelCapability>
    ) -> [ChatRequestBody.Message] {
        switch message.role {
        case .system:
            let content = message.textContent.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { return [] }
            if message.isCompactBoundary {
                return []
            }
            if capabilities.contains(.developerRole) {
                return [.developer(content: .text(content))]
            }
            return [.system(content: .text(content))]

        case .user:
            return [
                buildUserRequestMessage(
                    text: message.textContent,
                    attachments: message.parts,
                    capabilities: capabilities
                ),
            ]

        case .assistant:
            let text = message.textContent
            let reasoning = message.reasoningContent
            let toolCalls: [ChatRequestBody.Message.ToolCall] = message.parts.compactMap { part in
                guard case let .toolCall(value) = part else { return nil }
                return .init(
                    id: value.id, function: .init(name: value.apiName.isEmpty ? value.toolName : value.apiName, arguments: value.parameters)
                )
            }
            let toolResults: [ChatRequestBody.Message] = message.parts.compactMap { part in
                guard case let .toolResult(value) = part else { return nil }
                return .tool(content: .text(value.result), toolCallID: value.toolCallID)
            }

            var result: [ChatRequestBody.Message] = [
                .assistant(
                    content: text.isEmpty ? nil : .text(text),
                    toolCalls: toolCalls.isEmpty ? nil : toolCalls,
                    reasoning: reasoning
                ),
            ]
            result.append(contentsOf: toolResults)
            return result

        default:
            return []
        }
    }

    func buildUserRequestMessage(
        text: String,
        attachments: [ContentPart],
        capabilities: Set<ModelCapability>
    ) -> ChatRequestBody.Message {
        var parts: [ChatRequestBody.Message.ContentPart] = []
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedText.isEmpty {
            parts.append(.text(trimmedText))
        }

        for attachment in attachments {
            switch attachment {
            case .text:
                break

            case let .image(imagePart):
                guard capabilities.contains(.visual) else {
                    requestBuildLogger.warning("dropping image attachment because visual capability is disabled")
                    continue
                }
                guard !imagePart.data.isEmpty else {
                    requestBuildLogger.warning("dropping image attachment because image data is empty")
                    continue
                }
                let base64 = imagePart.data.base64EncodedString()
                let dataURL = "data:\(imagePart.mediaType);base64,\(base64)"
                if let url = URL(string: dataURL) {
                    parts.append(.imageURL(url))
                    requestBuildLogger.debug(
                        "appended image part mediaType=\(imagePart.mediaType) bytes=\(imagePart.data.count) previewBytes=\(imagePart.previewData?.count ?? 0)"
                    )
                } else {
                    requestBuildLogger.error("failed to create image data URL for mediaType=\(imagePart.mediaType)")
                }

            case let .audio(audioPart):
                if capabilities.contains(.auditory), !audioPart.data.isEmpty {
                    let base64 = audioPart.data.base64EncodedString()
                    let format = audioPart.mediaType.components(separatedBy: "/").last ?? "m4a"
                    parts.append(.audioBase64(base64, format: format))
                } else if let transcription = audioPart.transcription?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !transcription.isEmpty
                {
                    parts.append(.text("[Audio transcription]: \(transcription)"))
                }

            case let .file(filePart):
                if let textRep = filePart.textContent?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !textRep.isEmpty
                {
                    parts.append(.text("[File: \(filePart.name ?? "unnamed")]\n\(textRep)"))
                }

            case .reasoning, .toolCall, .toolResult:
                break
            }
        }

        if parts.isEmpty {
            parts.append(.text(trimmedText.isEmpty ? "(empty)" : trimmedText))
        }

        if parts.count == 1, case let .text(singleText) = parts.first {
            return .user(content: .text(singleText))
        }
        return .user(content: .parts(parts))
    }
}
