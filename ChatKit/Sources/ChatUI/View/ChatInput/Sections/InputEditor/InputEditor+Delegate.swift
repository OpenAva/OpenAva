//
//  InputEditor+Delegate.swift
//  ChatUI
//

import UIKit

extension InputEditor {
    @MainActor
    protocol Delegate: AnyObject {
        func onInputEditorCaptureButtonTapped()
        func onInputEditorPickAttachmentTapped()
        func onInputEditorContextButtonTapped()
        func onInputEditorMicButtonTapped()
        func onInputEditorToggleMoreButtonTapped()
        func onInputEditorBeginEditing()
        func onInputEditorEndEditing()
        func onInputEditorSubmitButtonTapped()
        func onInputEditorStopButtonTapped()
        func onInputEditorPasteAsAttachmentTapped()
        func onInputEditorTextChanged(text: String)
        func onInputEditorPastingLargeTextAsDocument(content: String)
        func onInputEditorPastingImage(image: UIImage)
        func onInputEditorStopVoiceRecordingTapped()
        func onInputEditorCancelVoiceRecordingTapped()
    }
}
