//
//  QuickSettingBar+Delegate.swift
//  LanguageModelChatUI
//

import Foundation

extension QuickSettingBar {
    @MainActor
    protocol Delegate: AnyObject {
        func quickSettingBarOnValueChanged()
        func quickSettingBarDidTriggerCommand(_ command: String)
        func quickSettingBarDidTriggerSkill(prompt: String, autoSubmit: Bool)
    }
}
