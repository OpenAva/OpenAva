//
//  ChatViewControllerConfiguration.swift
//  ChatUI
//

import ChatUI
import MarkdownView
import UIKit

public extension ChatViewController {
    struct Configuration {
        public var input: ChatInputConfiguration
        public var messageTheme: MarkdownTheme

        public init(
            input: ChatInputConfiguration,
            messageTheme: MarkdownTheme
        ) {
            self.input = input
            self.messageTheme = messageTheme
        }

        @MainActor
        public static func `default`() -> Self {
            .init(input: .default, messageTheme: .default)
        }
    }
}
