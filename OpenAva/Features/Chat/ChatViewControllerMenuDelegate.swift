//
//  ChatViewControllerMenuDelegate.swift
//  ChatUI
//

import UIKit

@MainActor
public protocol ChatViewControllerMenuDelegate: AnyObject {
    /// Return the trailing menu shown in the navigation bar. Return nil to hide the trailing item.
    func chatViewControllerMenu(_ controller: ChatViewController) -> UIMenu?

    /// Configure the leading avatar button for custom interactions (e.g., session switching).
    /// Override to add menu, actions, or other button configurations.
    func chatViewControllerLeadingButton(_ controller: ChatViewController, button: UIButton)

    /// Called when user taps the title control shown by the host platform.
    func chatViewControllerDidTapModelTitle(_ controller: ChatViewController)

    /// Called when ChatUI receives a local slash command that the host may want to handle.
    /// Return true when handled and ChatUI should stop further processing.
    func chatViewControllerHandleCommand(_ controller: ChatViewController, command: String) -> Bool

    /// Return the menu for the model selection button in the input editor. Return nil to hide or disable.
    func chatViewControllerModelMenu(_ controller: ChatViewController) -> UIMenu?
}

public extension ChatViewControllerMenuDelegate {
    func chatViewControllerMenu(_: ChatViewController) -> UIMenu? {
        nil
    }

    func chatViewControllerLeadingButton(_: ChatViewController, button _: UIButton) {}

    func chatViewControllerDidTapModelTitle(_: ChatViewController) {}

    func chatViewControllerHandleCommand(_: ChatViewController, command _: String) -> Bool {
        false
    }

    func chatViewControllerModelMenu(_: ChatViewController) -> UIMenu? {
        nil
    }
}
