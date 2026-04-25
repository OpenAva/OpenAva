//
//  InputEditor+Layout.swift
//  ChatUI
//

import UIKit

extension InputEditor {
    func textLayoutHeight(_ input: CGFloat) -> CGFloat {
        var finalHeight = input
        finalHeight = max(font.lineHeight, finalHeight)
        finalHeight = min(finalHeight, maxTextEditorHeight)
        return ceil(finalHeight)
    }

    func switchToRequiredStatus() {
        assert(Thread.isMainThread)
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(switchToRequiredStatusEx), object: nil)
        perform(#selector(switchToRequiredStatusEx), with: nil, afterDelay: 0.1)
    }

    @objc private func switchToRequiredStatusEx() {
        // Without doWithAnimation, which may cause jumpiness when text height updates.
        // We only animate layoutStatus changes if it's not simply editing text growth.
        let oldStatus = layoutStatus
        var newStatus = layoutStatus

        bossButton.transform = .identity
        moreButton.transform = .identity
        sendButton.transform = .identity
        voiceButton.transform = .identity
        stopVoiceButton.transform = .identity
        cancelVoiceButton.transform = .identity

        if isVoiceRecording {
            newStatus = .voiceRecording
        } else if isExecuting {
            newStatus = .executing
        } else if textView.isFirstResponder {
            if textView.text.isEmpty {
                newStatus = .preFocusText
            } else {
                newStatus = .editingText
            }
        } else {
            if textView.text.isEmpty {
                newStatus = .standard
            } else {
                newStatus = .editingText
            }
        }

        if oldStatus != newStatus {
            doWithAnimation { [self] in
                layoutStatus = newStatus
                layoutIfNeeded()
            }
        } else {
            layoutStatus = newStatus
            // Even if status didn't change, we might need to update send button alpha
            // based on whether the text is only whitespaces
            if newStatus == .editingText {
                let isTextValid = !(textView.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                UIView.animate(withDuration: 0.2) {
                    self.sendButton.alpha = isTextValid ? 1 : 0.3
                }
            }
        }
    }

    private func layoutBase() {
        let textLayoutHeight = textLayoutHeight(textHeight.value)
        textView.frame = CGRect(
            x: inset.left,
            y: inset.top,
            width: bounds.width - inset.left - inset.right,
            height: max(textLayoutHeight, font.lineHeight)
        )
        placeholderLabel.frame = textView.frame

        let sendBottomY = bounds.height - inset.bottom - sendButtonSize.height
        let iconBottomY = bounds.height - inset.bottom - iconSize.height - (sendButtonSize.height - iconSize.height) / 2

        bossButton.frame = CGRect(
            x: inset.left,
            y: iconBottomY,
            width: iconSize.width,
            height: iconSize.height
        )

        contextButton.frame = CGRect(
            x: bossButton.frame.maxX + iconSpacing,
            y: iconBottomY,
            width: iconSize.width,
            height: iconSize.height
        )

        let modelButtonSize = modelButton.sizeThatFits(CGSize(width: bounds.width, height: iconSize.height))
        modelButton.frame = CGRect(
            x: contextButton.frame.maxX + iconSpacing,
            y: iconBottomY - (modelButtonSize.height - iconSize.height) / 2,
            width: modelButtonSize.width,
            height: modelButtonSize.height
        )

        sendButton.frame = CGRect(
            x: bounds.width - inset.right - sendButtonSize.width,
            y: sendBottomY,
            width: sendButtonSize.width,
            height: sendButtonSize.height
        )

        voiceButton.frame = CGRect(
            x: sendButton.frame.minX - iconSize.width - iconSpacing,
            y: iconBottomY,
            width: iconSize.width,
            height: iconSize.height
        )

        stopVoiceButton.frame = sendButton.frame
        cancelVoiceButton.frame = voiceButton.frame
        voiceActivityIndicator.frame = CGRect(
            x: cancelVoiceButton.frame.minX - iconSpacing - iconSize.width,
            y: iconBottomY,
            width: iconSize.width,
            height: iconSize.height
        )

        moreButton.frame = bossButton.frame
    }

    func layoutAsEditingText() {
        layoutBase()
        stopVoiceButton.alpha = 0
        cancelVoiceButton.alpha = 0
        voiceActivityIndicator.alpha = 0

        let isTextValid = !(textView.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        sendButton.alpha = isTextValid ? 1 : 0.3

        voiceButton.alpha = 1
        bossButton.alpha = 1
        contextButton.alpha = 1
        modelButton.alpha = 1
        moreButton.alpha = 0
        textView.alpha = 1
        placeholderLabel.alpha = 0
    }

    func layoutAsPreEditingText() {
        layoutBase()
        stopVoiceButton.alpha = 0
        cancelVoiceButton.alpha = 0
        voiceActivityIndicator.alpha = 0

        sendButton.alpha = 0.3
        voiceButton.alpha = 1
        bossButton.alpha = 1
        contextButton.alpha = 1
        modelButton.alpha = 1
        moreButton.alpha = 0
        textView.alpha = 1
        placeholderLabel.alpha = 1
    }

    func layoutAsStandard() {
        layoutBase()
        stopVoiceButton.alpha = 0
        cancelVoiceButton.alpha = 0
        voiceActivityIndicator.alpha = 0

        sendButton.alpha = 0.3
        voiceButton.alpha = 1
        bossButton.alpha = 1
        contextButton.alpha = 1
        modelButton.alpha = 1
        moreButton.alpha = 0
        textView.alpha = 1
        placeholderLabel.alpha = 1
    }

    func layoutAsVoiceRecording() {
        layoutBase()
        stopVoiceButton.alpha = 1
        cancelVoiceButton.alpha = 1
        voiceActivityIndicator.alpha = 1

        let recordingButtonY = bounds.height - inset.bottom - sendButtonSize.height
        let indicatorY = recordingButtonY + (sendButtonSize.height - iconSize.height) / 2

        // Cancel button on the far left
        cancelVoiceButton.frame = CGRect(
            x: inset.left,
            y: recordingButtonY,
            width: sendButtonSize.width,
            height: sendButtonSize.height
        )

        // Stop button on the far right
        stopVoiceButton.frame = CGRect(
            x: bounds.width - inset.right - sendButtonSize.width,
            y: recordingButtonY,
            width: sendButtonSize.width,
            height: sendButtonSize.height
        )

        // Voice activity indicator fills the space between cancel and stop buttons
        let indicatorX = cancelVoiceButton.frame.maxX + iconSpacing
        let indicatorWidth = stopVoiceButton.frame.minX - indicatorX - iconSpacing
        voiceActivityIndicator.frame = CGRect(
            x: indicatorX,
            y: indicatorY,
            width: indicatorWidth,
            height: iconSize.height
        )

        sendButton.alpha = 0
        voiceButton.alpha = 0
        bossButton.alpha = 0
        contextButton.alpha = 0
        modelButton.alpha = 0
        moreButton.alpha = 0
        textView.alpha = 1
        placeholderLabel.alpha = 0
    }

    func layoutAsExecuting() {
        layoutBase()
        stopVoiceButton.alpha = 0
        cancelVoiceButton.alpha = 0
        voiceActivityIndicator.alpha = 0

        sendButton.alpha = 1
        voiceButton.alpha = 0.3
        bossButton.alpha = 0.3
        contextButton.alpha = 0.3
        modelButton.alpha = 0.3
        moreButton.alpha = 0
        textView.alpha = 1
        placeholderLabel.alpha = 0
    }
}
