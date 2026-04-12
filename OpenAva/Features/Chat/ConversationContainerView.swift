//
//  ConversationContainerView.swift
//  ChatUI
//
//  The main embeddable chat view. Manages a message list and input editor.
//

import ChatUI
import Combine
import Foundation
import OSLog
import SnapKit
import UIKit

private let logger = Logger(subsystem: "com.day1-labs.openava", category: "chat.stop.container")

/// The main chat container view that third-party apps embed.
///
/// Usage:
///
///     let container = ConversationContainerView()
///     container.load(sessionID: "conv-1", sessionConfiguration: configuration)
///     parentView.addSubview(container)
///
open class ConversationContainerView: UIView {
    private var draftInputObject: ChatInputContent?
    private var activeSessionConfiguration: ConversationSession.Configuration?
    private weak var currentSession: ConversationSession?
    private var sessionCancellables = Set<AnyCancellable>()
    public var conversationModels: ConversationSession.Models = .init()
    public var newSessionIDProvider: @MainActor () -> String = { UUID().uuidString }

    public let messageListView = MessageListView()
    public let chatInputView = ChatInputView()

    public var inputConfiguration: ChatInputConfiguration {
        get { chatInputView.configuration }
        set { chatInputView.configuration = newValue }
    }

    public init() {
        super.init(frame: .zero)
        setupUI()
    }

    @available(*, unavailable)
    public required init?(coder _: NSCoder) {
        fatalError()
    }

    private func setupUI() {
        backgroundColor = .clear
        addSubview(messageListView)
        addSubview(chatInputView)
        chatInputView.delegate = self

        chatInputView.snp.makeConstraints { make in
            make.left.right.equalToSuperview()
            make.bottom.equalTo(keyboardLayoutGuide.snp.top)
        }

        messageListView.snp.makeConstraints { make in
            make.top.left.right.equalToSuperview()
            make.bottom.equalTo(chatInputView.snp.top)
        }
    }

    /// Load a session by ID. This sets up the message list and session.
    public func load(
        sessionID: String,
        models: ConversationSession.Models = .init(),
        sessionConfiguration: ConversationSession.Configuration
    ) {
        conversationModels = models
        activeSessionConfiguration = sessionConfiguration
        let session = ConversationSessionManager.shared.session(for: sessionID, configuration: sessionConfiguration)
        applyConversationModels(models, to: session)
        currentSession = session
        sessionCancellables.removeAll()
        messageListView.prepareForNewSession()
        messageListView.onToggleReasoningCollapse = { [weak self] messageID in
            self?.currentSession?.toggleReasoningCollapse(for: messageID)
        }
        messageListView.onToggleToolResultCollapse = { [weak self] messageID, toolCallID in
            self?.currentSession?.toggleToolResultCollapse(for: messageID, toolCallID: toolCallID)
        }
        messageListView.onRetryInterruptedInference = { [weak self] in
            guard let self, let session = self.currentSession else { return }
            session.retryInterruptedInference(messageListView: self.messageListView)
        }
        session.messagesDidChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] messages, scrolling in
                self?.messageListView.showsInterruptedRetryAction = session.showsInterruptedRetryAction
                self?.messageListView.render(messages: messages, scrolling: scrolling)
            }
            .store(in: &sessionCancellables)
        chatInputView.bind(sessionID: sessionID)
    }
}

extension ConversationContainerView: ChatInputDelegate {
    public func chatInputDidSubmit(_ input: ChatInputView, object: ChatInputContent, completion: @escaping @Sendable (Bool) -> Void) {
        _ = input
        guard let session = currentSession else {
            logger.notice("submit ignored reason=no_active_session")
            completion(false)
            return
        }
        guard let model = session.models.chat else {
            logger.notice("submit ignored session=\(session.id, privacy: .public) reason=no_chat_model")
            completion(false)
            return
        }
        logger.notice(
            "submit accepted session=\(session.id, privacy: .public) textLength=\(object.text.count) attachments=\(object.attachments.count) hasTask=\(String(session.currentTask != nil), privacy: .public)"
        )
        let userInput = makeUserInput(from: object)
        draftInputObject = nil
        messageListView.markNextUpdateAsUserInitiated()
        input.setExecuting(true)
        session.runInference(model: model, messageListView: messageListView, input: userInput) {
            Task { @MainActor [weak input] in
                logger.notice("submit completion session=\(session.id, privacy: .public)")
                input?.setExecuting(false)
            }
            completion(true)
        }
    }

    public func chatInputDidRequestStop(_ input: ChatInputView) {
        _ = input
        logger.notice(
            "stop tapped session=\(self.currentSession?.id ?? "nil", privacy: .public) hasTask=\(String(self.currentSession?.currentTask != nil), privacy: .public)"
        )
        currentSession?.interruptCurrentTurn(reason: .userStop)
        chatInputView.setExecuting(false)
    }

    public func chatInputDidUpdateObject(_: ChatInputView, object: ChatInputContent) {
        draftInputObject = object
    }

    public func chatInputDidRequestObjectForRestore(_: ChatInputView) -> ChatInputContent? {
        draftInputObject
    }

    public func chatInputDidReportError(_: ChatInputView, error: String) {
        guard let viewController = parentViewController else { return }
        let alert = UIAlertController(title: String.localized("Error"), message: error, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String.localized("OK"), style: .default))
        viewController.present(alert, animated: true)
    }

    public func chatInputDidTriggerCommand(_: ChatInputView, command: String) {
        let normalized = command.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "/new":
            guard currentSession != nil else { return }
            Task { @MainActor in
                guard let config = activeSessionConfiguration else { return }
                let newSessionID = newSessionIDProvider()
                load(sessionID: newSessionID, models: conversationModels, sessionConfiguration: config)
            }
        default:
            chatInputDidReportError(chatInputView, error: String.localized("Unsupported command: \(command)"))
        }
    }

    public func chatInputDidTriggerSkill(_ input: ChatInputView, prompt: String, autoSubmit: Bool) {
        if autoSubmit {
            return
        }
        input.refill(withText: prompt, attachments: [])
        input.focus()
    }

    private var parentViewController: UIViewController? {
        var responder: UIResponder? = self
        while let next = responder?.next {
            if let vc = next as? UIViewController { return vc }
            responder = next
        }
        return nil
    }
}
