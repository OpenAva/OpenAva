//
//  InputEditor+TextView.swift
//  ChatUI
//

import UIKit

extension InputEditor {
    final class TextEditorView: UITextView {
        init() {
            super.init(frame: .zero, textContainer: nil)
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError()
        }

        override var keyCommands: [UIKeyCommand]? {
            [
                UIKeyCommand(input: "\r", modifierFlags: .alternate, action: #selector(insertNewLine)),
                UIKeyCommand(input: "\r", modifierFlags: [], action: #selector(returnPressed)),
                UIKeyCommand(input: "\r", modifierFlags: .command, action: #selector(commandReturnPressed)),
            ]
        }

        var onReturnKeyPressed: (() -> Void) = {}
        var onCommandReturnKeyPressed: (() -> Void) = {}
        var onImagePasted: ((UIImage) -> Void) = { _ in }

        override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
            if action == #selector(paste(_:)) {
                return true
            }
            return super.canPerformAction(action, withSender: sender)
        }

        override func paste(_ sender: Any?) {
            if let image = UIPasteboard.general.image {
                onImagePasted(image)
                return
            }
            // Walk up to find InputEditor to check configuration
            var superView: UIView? = self
            while superView != nil, !(superView is InputEditor) {
                superView = superView?.superview
            }
            if let editor = superView as? InputEditor,
               editor.configuration.pasteLargeTextAsFile,
               let text = UIPasteboard.general.string,
               text.count > 512
            {
                editor.delegate?.onInputEditorPastingLargeTextAsDocument(content: text)
                return
            }
            super.paste(sender)
        }

        @objc private func insertNewLine() {
            insertText("\n")
        }

        @objc private func returnPressed() {
            onReturnKeyPressed()
        }

        @objc private func commandReturnPressed() {
            onCommandReturnKeyPressed()
        }
    }
}

extension InputEditor: UITextViewDelegate {
    public func textViewDidBeginEditing(_ textView: UITextView) {
        applySkillPresentationIfNeeded()
        updateTextHeight()
        delegate?.onInputEditorBeginEditing()
        delegate?.onInputEditorTextChanged(text: textView.text)
        switchToRequiredStatus()
    }

    public func textViewDidEndEditing(_ textView: UITextView) {
        applySkillPresentationIfNeeded()
        updateTextHeight()
        delegate?.onInputEditorTextChanged(text: textView.text)
        delegate?.onInputEditorEndEditing()
        switchToRequiredStatus()
    }

    public func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        // When deleting the trailing space after a completed skill command,
        // delete the entire "/command " together.
        if text.isEmpty, range.length == 1, range.location > 0 {
            let fullText = textView.text ?? ""
            let beforeDeletion = String((fullText as NSString).substring(to: range.location))
            let skillRange = highlightedSkillCommandRange(in: beforeDeletion)
            if let skillRange, skillRange.location + skillRange.length == beforeDeletion.utf16.count {
                let nsFull = fullText as NSString
                textView.text = nsFull.replacingCharacters(in: NSRange(location: skillRange.location, length: nsFull.length - skillRange.location), with: "")
                applySkillPresentationIfNeeded()
                updatePlaceholderAlpha()
                updateTextHeight()
                delegate?.onInputEditorTextChanged(text: textView.text)
                switchToRequiredStatus()
                return false
            }
        }
        return true
    }

    public func textViewDidChange(_ textView: UITextView) {
        applySkillPresentationIfNeeded()
        updatePlaceholderAlpha()
        updateTextHeight()
        delegate?.onInputEditorTextChanged(text: textView.text)
        switchToRequiredStatus()
    }

    public func textView(_ textView: UITextView, editMenuForTextIn _: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
        let pasteboard = UIPasteboard.general
        let canPasteAttachment = pasteboard.hasStrings

        let actions: [UIAction] = [
            UIAction(title: String.localized("Insert New Line")) { _ in
                textView.insertText("\n")
            },
            UIAction(
                title: String.localized("Paste as Attachment"),
                attributes: canPasteAttachment ? [] : [.disabled]
            ) { [weak self] _ in
                self?.delegate?.onInputEditorPasteAsAttachmentTapped()
            },
            UIAction(title: String.localized("More")) { [weak self] _ in
                self?.delegate?.onInputEditorToggleMoreButtonTapped()
            },
        ]
        return UIMenu(children: suggestedActions + actions)
    }

    func updatePlaceholderAlpha() {
        if isVoiceRecording {
            placeholderLabel.alpha = 0
        } else {
            placeholderLabel.alpha = textView.text.isEmpty ? 1 : 0
        }
    }

    func updateTextHeight() {
        let attrText = textView.attributedText ?? .init()
        let textHeight = TextMeasurementHelper.shared.measureSize(
            of: attrText,
            usingWidth: textView.frame.width
        ).height
        let decision = ceil(max(textHeight, font.lineHeight))
        doEditorLayoutAnimation { self.textHeight.send(decision) }
    }
}
