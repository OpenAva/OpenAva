//
//  ChatViewControllerConfiguration.swift
//  LanguageModelChatUI
//

import MarkdownView
import UIKit

public extension ChatViewController {
    @MainActor
    struct Configuration {
        public var input: ChatInputConfiguration
        public var messageTheme: MarkdownTheme
        public var newSessionIDProvider: @MainActor () -> String

        public init(
            input: ChatInputConfiguration = .default,
            messageTheme: MarkdownTheme = .default,
            newSessionIDProvider: @escaping @MainActor () -> String = { UUID().uuidString }
        ) {
            self.input = input
            self.messageTheme = messageTheme
            self.newSessionIDProvider = newSessionIDProvider
        }
    }
}
