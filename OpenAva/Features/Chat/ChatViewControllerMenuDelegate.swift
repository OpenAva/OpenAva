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

    func chatViewControllerDidTapModelTitle(_ controller: ChatViewController) {
        _ = controller
    }

    func chatViewControllerHandleCommand(_ controller: ChatViewController, command _: String) -> Bool {
        _ = controller
        return false
    }
}
