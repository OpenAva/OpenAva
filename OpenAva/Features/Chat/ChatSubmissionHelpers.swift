import ChatUI
import Foundation
import OSLog
import UniformTypeIdentifiers

private let submissionLogger = Logger(subsystem: "ChatUI", category: "Submission")

public typealias ConversationPromptSubmissionHandler = @MainActor (
    _ session: ConversationSession,
    _ model: ConversationSession.Model,
    _ prompt: ConversationSession.PromptInput
) async -> Bool

@MainActor
private func defaultPromptSubmissionHandler(
    session: ConversationSession,
    model: ConversationSession.Model,
    prompt: ConversationSession.PromptInput
) async -> Bool {
    session.submitPromptWithoutWaiting(
        model: model,
        prompt: prompt,
        usingExistingReservation: true
    )
}

@MainActor func applyConversationModels(
    _ models: ConversationSession.Models,
    to session: ConversationSession
) {
    if let chat = models.chat {
        session.models.chat = chat
    }
    if let titleGeneration = models.titleGeneration {
        session.models.titleGeneration = titleGeneration
    }
}

func makePromptInput(from object: ChatInputContent) -> ConversationSession.PromptInput {
    let attachmentSummary = object.attachments.map { attachment in
        "\(attachment.type.rawValue)(fileBytes=\(attachment.fileData.count),previewBytes=\(attachment.previewImageData.count),textChars=\(attachment.textContent.count))"
    }.joined(separator: ", ")
    submissionLogger.info(
        "makePromptInput textChars=\(object.text.count) attachments=\(object.attachments.count) [\(attachmentSummary)]"
    )

    return .init(
        text: object.text,
        attachments: object.attachments.map(makeContentPart)
    )
}

@MainActor
func handlePromptSubmit(
    session: ConversationSession?,
    object: ChatInputContent,
    messageListView: MessageListView,
    promptSubmissionHandler: ConversationPromptSubmissionHandler?,
    clearDraft: @escaping @MainActor () -> Void,
    completion: @escaping @Sendable (Bool) -> Void
) {
    guard let session else {
        submissionLogger.notice("submit ignored reason=no_active_session")
        completion(false)
        return
    }
    guard let model = session.models.chat else {
        submissionLogger.notice("submit ignored session=\(session.id, privacy: .public) reason=no_chat_model")
        completion(false)
        return
    }

    submissionLogger.notice(
        "submit accepted session=\(session.id, privacy: .public) textLength=\(object.text.count) attachments=\(object.attachments.count) queryActive=\(String(session.isQueryActive), privacy: .public)"
    )

    let promptInput = makePromptInput(from: object)
    guard session.queryGuard.reserve() else {
        submissionLogger.notice(
            "submit ignored session=\(session.id, privacy: .public) reason=query_already_active"
        )
        completion(false)
        return
    }
    clearDraft()
    messageListView.markNextUpdateAsUserInitiated()

    let handler = promptSubmissionHandler ?? defaultPromptSubmissionHandler
    Task { @MainActor in
        let accepted = await handler(session, model, promptInput)
        if !accepted {
            session.queryGuard.cancelReservation()
        }
        submissionLogger.notice("submit completion session=\(session.id, privacy: .public) accepted=\(String(accepted), privacy: .public)")
        completion(accepted)
    }
}

@MainActor
func handlePromptStop(
    session: ConversationSession?,
    fallbackSessionID: String? = nil
) {
    let sessionID = session?.id ?? fallbackSessionID ?? "nil"
    submissionLogger.notice(
        "stop tapped session=\(sessionID, privacy: .public) hasSession=\(String(session != nil), privacy: .public) queryActive=\(String(session?.isQueryActive ?? false), privacy: .public)"
    )
    session?.interruptCurrentTurn(reason: .userStop)
}

private func makeContentPart(from attachment: ChatInputAttachment) -> ContentPart {
    switch attachment.type {
    case .image:
        .image(.init(
            mediaType: mediaType(for: attachment, fallback: "image/jpeg"),
            data: attachment.fileData,
            previewData: attachment.previewImageData.isEmpty ? nil : attachment.previewImageData,
            name: attachment.name
        ))
    case .document:
        .file(.init(
            mediaType: mediaType(for: attachment, fallback: "text/plain"),
            data: Data(attachment.textContent.utf8),
            textContent: attachment.textContent,
            name: attachment.name,
            sourceFilePath: attachment.sourceFilePath
        ))
    case .audio:
        .audio(.init(
            mediaType: mediaType(for: attachment, fallback: "audio/m4a"),
            data: attachment.fileData,
            transcription: attachment.textContent.isEmpty ? nil : attachment.textContent,
            name: attachment.name
        ))
    }
}

private func mediaType(for attachment: ChatInputAttachment, fallback: String) -> String {
    let ext = URL(fileURLWithPath: attachment.storageFilename).pathExtension
    guard !ext.isEmpty else { return fallback }
    if let type = UTType(filenameExtension: ext), let mimeType = type.preferredMIMEType {
        return mimeType
    }
    return fallback
}
