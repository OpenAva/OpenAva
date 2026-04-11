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
        doWithAnimation { [self] in
            bossButton.transform = .identity
            moreButton.transform = .identity
            sendButton.transform = .identity
            voiceButton.transform = .identity
            stopVoiceButton.transform = .identity
            cancelVoiceButton.transform = .identity
            if isVoiceRecording {
                layoutStatus = .voiceRecording
                return
            }
            if isExecuting {
                layoutStatus = .executing
                return
            }
            if textView.isFirstResponder {
                if textView.text.isEmpty {
                    layoutStatus = .preFocusText
                } else {
                    layoutStatus = .editingText
                }
            } else {
                if textView.text.isEmpty {
                    layoutStatus = .standard
                } else {
                    layoutStatus = .editingText
                }
            }
        }
    }

    func layoutAsEditingText() {
        stopVoiceButton.alpha = 0
        cancelVoiceButton.alpha = 0
        voiceActivityIndicator.alpha = 0
        sendButton.frame = CGRect(
            x: bounds.width - inset.right - iconSize.width,
            y: bounds.height - iconSize.height - inset.bottom,
            width: iconSize.width,
            height: iconSize.height
        )
        sendButton.alpha = 1
        moreButton.frame = CGRect(
            x: bounds.width - inset.right - iconSize.width,
            y: bounds.height - iconSize.height - inset.bottom,
            width: iconSize.width,
            height: iconSize.height
        )
        defer { moreButton.transform = CGAffineTransform(scaleX: 0.5, y: 0.5) }
        moreButton.alpha = 0
        voiceButton.frame = CGRect(
            x: sendButton.frame.minX - iconSize.width - iconSpacing,
            y: sendButton.frame.minY,
            width: iconSize.width,
            height: iconSize.height
        )
        voiceButton.alpha = 1

        let textLayoutHeight = textLayoutHeight(textHeight.value)
        textView.frame = CGRect(
            x: inset.left,
            y: (bounds.height - textLayoutHeight) / 2,
            width: voiceButton.frame.minX - inset.left - iconSpacing,
            height: textLayoutHeight
        )
        placeholderLabel.frame = textView.frame

        bossButton.frame = CGRect(
            x: 0 - inset.left - iconSize.width,
            y: inset.top,
            width: iconSize.width,
            height: iconSize.height
        )
        bossButton.alpha = 0
    }

    func layoutAsPreEditingText() {
        defer { bossButton.transform = CGAffineTransform(scaleX: 0.5, y: 0.5) }
        defer { sendButton.transform = CGAffineTransform(scaleX: 0.5, y: 0.5) }
        stopVoiceButton.alpha = 0
        cancelVoiceButton.alpha = 0
        voiceActivityIndicator.alpha = 0

        bossButton.frame = CGRect(
            x: 0 - inset.left - iconSize.width,
            y: inset.top,
            width: iconSize.width,
            height: iconSize.height
        )
        bossButton.alpha = 0

        moreButton.frame = CGRect(
            x: bounds.width - inset.right - iconSize.width,
            y: inset.top,
            width: iconSize.width,
            height: iconSize.height
        )
        moreButton.alpha = 1
        voiceButton.frame = CGRect(
            x: moreButton.frame.minX - iconSize.width - iconSpacing,
            y: inset.top,
            width: iconSize.width,
            height: iconSize.height
        )
        voiceButton.alpha = 1
        let textLayoutHeight = textLayoutHeight(textHeight.value)
        textView.frame = CGRect(
            x: inset.left,
            y: (bounds.height - textLayoutHeight) / 2,
            width: voiceButton.frame.minX - inset.left - iconSpacing,
            height: textLayoutHeight
        )
        textView.alpha = 1
        placeholderLabel.frame = textView.frame

        sendButton.frame = CGRect(
            x: bounds.width + iconSpacing + inset.right,
            y: bounds.height - iconSize.height - inset.bottom,
            width: iconSize.width,
            height: iconSize.height
        )
        sendButton.alpha = 0
    }

    func layoutAsStandard() {
        defer { sendButton.transform = CGAffineTransform(scaleX: 0.5, y: 0.5) }
        stopVoiceButton.alpha = 0
        cancelVoiceButton.alpha = 0
        voiceActivityIndicator.alpha = 0

        bossButton.frame = CGRect(
            x: inset.left,
            y: inset.top,
            width: iconSize.width,
            height: iconSize.height
        )
        bossButton.alpha = 1
        moreButton.frame = CGRect(
            x: bounds.width - inset.right - iconSize.width,
            y: inset.top,
            width: iconSize.width,
            height: iconSize.height
        )
        moreButton.alpha = 1
        moreButton.transform = .identity
        voiceButton.frame = CGRect(
            x: moreButton.frame.minX - iconSize.width - iconSpacing,
            y: inset.top,
            width: iconSize.width,
            height: iconSize.height
        )
        voiceButton.alpha = 1
        let textLayoutHeight = textLayoutHeight(textHeight.value)
        textView.frame = CGRect(
            x: bossButton.frame.maxX + iconSpacing,
            y: (bounds.height - textLayoutHeight) / 2,
            width: voiceButton.frame.minX - bossButton.frame.maxX - iconSpacing * 2,
            height: textLayoutHeight
        )
        textView.alpha = 1
        placeholderLabel.frame = textView.frame

        sendButton.frame = CGRect(
            x: bounds.width + inset.right,
            y: inset.top,
            width: iconSize.width,
            height: iconSize.height
        )
        sendButton.alpha = 0
    }

    func layoutAsVoiceRecording() {
        defer { bossButton.transform = CGAffineTransform(scaleX: 0.5, y: 0.5) }
        defer { moreButton.transform = CGAffineTransform(scaleX: 0.5, y: 0.5) }
        defer { sendButton.transform = CGAffineTransform(scaleX: 0.5, y: 0.5) }
        defer { voiceButton.transform = CGAffineTransform(scaleX: 0.5, y: 0.5) }

        bossButton.frame = CGRect(x: -inset.left - iconSize.width, y: inset.top, width: iconSize.width, height: iconSize.height)
        bossButton.alpha = 0
        moreButton.frame = CGRect(x: bounds.width + iconSpacing, y: inset.top, width: iconSize.width, height: iconSize.height)
        moreButton.alpha = 0
        sendButton.frame = CGRect(x: bounds.width + iconSpacing, y: inset.top, width: iconSize.width, height: iconSize.height)
        sendButton.alpha = 0
        voiceButton.frame = CGRect(x: bounds.width + iconSpacing, y: inset.top, width: iconSize.width, height: iconSize.height)
        voiceButton.alpha = 0
        placeholderLabel.alpha = 0

        let controlsY = (bounds.height - iconSize.height) / 2
        stopVoiceButton.frame = CGRect(
            x: bounds.width - inset.right - iconSize.width,
            y: controlsY,
            width: iconSize.width,
            height: iconSize.height
        )
        stopVoiceButton.alpha = 1
        cancelVoiceButton.frame = CGRect(
            x: stopVoiceButton.frame.minX - iconSize.width - iconSpacing,
            y: controlsY,
            width: iconSize.width,
            height: iconSize.height
        )
        cancelVoiceButton.alpha = 1

        voiceActivityIndicator.frame = CGRect(
            x: cancelVoiceButton.frame.minX - iconSize.width - iconSpacing,
            y: controlsY,
            width: iconSize.width,
            height: iconSize.height
        )
        voiceActivityIndicator.alpha = 1

        let textLayoutHeight = textLayoutHeight(textHeight.value)
        textView.frame = CGRect(
            x: inset.left,
            y: (bounds.height - textLayoutHeight) / 2,
            width: voiceActivityIndicator.frame.minX - inset.left - iconSpacing,
            height: max(textLayoutHeight, font.lineHeight)
        )
        textView.alpha = 1
        placeholderLabel.frame = textView.frame
    }

    func layoutAsExecuting() {
        stopVoiceButton.alpha = 0
        cancelVoiceButton.alpha = 0
        voiceActivityIndicator.alpha = 0

        sendButton.frame = CGRect(
            x: bounds.width - inset.right - iconSize.width,
            y: bounds.height - iconSize.height - inset.bottom,
            width: iconSize.width,
            height: iconSize.height
        )
        sendButton.alpha = 1

        moreButton.frame = CGRect(
            x: bounds.width + iconSpacing,
            y: inset.top,
            width: iconSize.width,
            height: iconSize.height
        )
        moreButton.alpha = 0
        moreButton.transform = CGAffineTransform(scaleX: 0.5, y: 0.5)

        voiceButton.frame = CGRect(
            x: bounds.width + iconSpacing,
            y: inset.top,
            width: iconSize.width,
            height: iconSize.height
        )
        voiceButton.alpha = 0
        voiceButton.transform = CGAffineTransform(scaleX: 0.5, y: 0.5)

        let hasText = !(textView.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if hasText {
            let textLayoutHeight = textLayoutHeight(textHeight.value)
            textView.frame = CGRect(
                x: inset.left,
                y: (bounds.height - textLayoutHeight) / 2,
                width: sendButton.frame.minX - inset.left - iconSpacing,
                height: textLayoutHeight
            )
            textView.alpha = 1
        } else {
            textView.frame = CGRect(
                x: inset.left,
                y: inset.top,
                width: 0,
                height: max(textLayoutHeight(textHeight.value), font.lineHeight)
            )
            textView.alpha = 0
        }
        placeholderLabel.frame = textView.frame
        placeholderLabel.alpha = 0

        bossButton.frame = CGRect(
            x: 0 - inset.left - iconSize.width,
            y: inset.top,
            width: iconSize.width,
            height: iconSize.height
        )
        bossButton.alpha = 0
        bossButton.transform = CGAffineTransform(scaleX: 0.5, y: 0.5)
    }
}
