//
//  ChatViewControllerMenuDelegate.swift
//  LanguageModelChatUI
//

import UIKit

@MainActor
public protocol ChatViewControllerMenuDelegate: AnyObject {
    /// Return the trailing menu shown in the navigation bar. Return nil to hide the trailing item.
    func chatViewControllerMenu(_ controller: ChatViewController) -> UIMenu?

    /// Configure the leading avatar button for custom interactions (e.g., session switching).
    /// Override to add menu, actions, or other button configurations.
    func chatViewControllerLeadingButton(_ controller: ChatViewController, button: UIButton)

    /// Called when user taps the primary title row (Agent).
    func chatViewControllerDidTapAgentTitle(_ controller: ChatViewController)

    /// Called when user taps the secondary title row (Model/Provider).
    func chatViewControllerDidTapModelTitle(_ controller: ChatViewController)

    /// Called when ChatUI requests a new conversation (e.g. `/new`).
    /// Return a new conversation ID to switch immediately, or nil to reject.
    func chatViewControllerRequestNewConversationID(_ controller: ChatViewController, from conversationID: String) -> String?
}

public extension ChatViewControllerMenuDelegate {
    func chatViewControllerMenu(_ controller: ChatViewController) -> UIMenu? {
        _ = controller
        return nil
    }

    func chatViewControllerLeadingButton(_ controller: ChatViewController, button: UIButton) {
        _ = controller
        _ = button
    }

    func chatViewControllerDidTapAgentTitle(_ controller: ChatViewController) {
        _ = controller
    }

    func chatViewControllerDidTapModelTitle(_ controller: ChatViewController) {
        _ = controller
    }

    func chatViewControllerRequestNewConversationID(_ controller: ChatViewController, from _: String) -> String? {
        _ = controller
        return nil
    }
}
