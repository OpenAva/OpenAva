//
//  AttachmentsBar+Delegate.swift
//  ChatUI
//

import Foundation

extension AttachmentsBar {
    @MainActor
    protocol Delegate: AnyObject {
        func attachmentBarDidUpdateAttachments(_ attachments: [Item])
    }
}
