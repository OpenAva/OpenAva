//
//  InputEditor.swift
//  LanguageModelChatUI
//

import Combine
import UIKit

final class InputEditor: EditorSectionView {
    let font = UIFont.systemFont(ofSize: 15, weight: .regular)
    let textHeight: CurrentValueSubject<CGFloat, Never> = .init(0)
    let maxTextEditorHeight: CGFloat = 200
    private var isApplyingTextPresentation = false

    let elementClipper = UIView()

    #if targetEnvironment(macCatalyst)
        let bossButton = IconButton(icon: "attachment")
    #else
        let bossButton = IconButton(icon: "camera")
    #endif
    let textView = TextEditorView()
    let placeholderLabel = UILabel()
    let voiceButton = IconButton(icon: "mic")
    let stopVoiceButton = IconButton(icon: "stop.circle.fill")
    let cancelVoiceButton = IconButton(icon: "xmark.circle")
    let voiceActivityIndicator = VoiceWaveIndicatorView()
    let moreButton = IconButton(icon: "plus.circle")
    let sendButton = IconButton(icon: "send")

    let inset: UIEdgeInsets = .init(top: 8, left: 8, bottom: 8, right: 8)
    let iconSpacing: CGFloat = 8
    let iconSize = CGSize(width: 28, height: 28)

    var isControlPanelOpened: Bool = false {
        didSet { moreButton.change(icon: isControlPanelOpened ? "x.circle" : "plus.circle") }
    }

    enum LayoutStatus {
        case standard
        case preFocusText
        case editingText
        case voiceRecording
    }

    var layoutStatus: LayoutStatus = .standard {
        didSet {
            guard oldValue != layoutStatus else { return }
            setNeedsLayout()
        }
    }

    /// Configuration injected from ChatInputView.
    var configuration: ChatInputConfiguration = .default

    weak var delegate: Delegate?

    private(set) var isVoiceRecording = false
    private(set) var voiceTranscriptText = ""

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func initializeViews() {
        super.initializeViews()

        bossButton.tapAction = { [weak self] in
            #if targetEnvironment(macCatalyst)
                self?.delegate?.onInputEditorPickAttachmentTapped()
            #else
                self?.delegate?.onInputEditorCaptureButtonTapped()
            #endif
        }
        addSubview(elementClipper)
        elementClipper.clipsToBounds = true
        elementClipper.addSubview(bossButton)
        textView.font = font
        textView.delegate = self
        textView.showsVerticalScrollIndicator = false
        textView.showsHorizontalScrollIndicator = false
        textView.alwaysBounceVertical = false
        textView.alwaysBounceHorizontal = false
        textView.textColor = ChatUIDesign.Color.offBlack
        textView.textAlignment = .natural
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer.lineBreakMode = .byTruncatingTail
        textView.textContainer.lineFragmentPadding = .zero
        textView.textContainer.maximumNumberOfLines = 0
        textView.clipsToBounds = false
        textView.isSelectable = true
        textView.isScrollEnabled = true
        textView.isEditable = true
        textView.onReturnKeyPressed = { [weak self] in
            guard let self else { return }
            textView.insertText("\n")
        }
        textView.onCommandReturnKeyPressed = { [weak self] in
            self?.sendButton.tapAction()
        }
        textView.onImagePasted = { [weak self] image in
            self?.delegate?.onInputEditorPastingImage(image: image)
        }
        elementClipper.addSubview(textView)
        placeholderLabel.text = String.localized("Type something...")
        placeholderLabel.font = font
        placeholderLabel.textColor = ChatUIDesign.Color.black50
        elementClipper.addSubview(placeholderLabel)
        voiceButton.tapAction = { [weak self] in
            self?.delegate?.onInputEditorMicButtonTapped()
        }
        elementClipper.addSubview(voiceButton)
        stopVoiceButton.tapAction = { [weak self] in
            self?.delegate?.onInputEditorStopVoiceRecordingTapped()
        }
        elementClipper.addSubview(stopVoiceButton)
        cancelVoiceButton.tapAction = { [weak self] in
            self?.delegate?.onInputEditorCancelVoiceRecordingTapped()
        }
        elementClipper.addSubview(cancelVoiceButton)
        // Voice-like animation replaces static listening text.
        voiceActivityIndicator.tintColor = ChatUIDesign.Color.black60
        elementClipper.addSubview(voiceActivityIndicator)
        moreButton.tapAction = { [weak self] in
            self?.isControlPanelOpened.toggle()
            self?.setNeedsLayout()
            self?.delegate?.onInputEditorToggleMoreButtonTapped()
        }
        elementClipper.addSubview(moreButton)
        sendButton.tapAction = { [weak self] in
            self?.delegate?.onInputEditorSubmitButtonTapped()
        }
        elementClipper.addSubview(sendButton)

        textHeight.removeDuplicates()
            .compactMap { [weak self] textHeight -> CGFloat? in
                guard let self else { return nil }
                return max(textLayoutHeight(textHeight), iconSize.height)
                    + inset.top + inset.bottom
            }
            .ensureMainThread()
            .sink { [weak self] height in self?.heightPublisher.send(height) }
            .store(in: &cancellables)
        updateTextHeight()
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        elementClipper.frame = bounds

        switch layoutStatus {
        case .standard:
            layoutAsStandard()
        case .preFocusText:
            layoutAsPreEditingText()
        case .editingText:
            layoutAsEditingText()
        case .voiceRecording:
            layoutAsVoiceRecording()
        }

        updatePlaceholderAlpha()
    }

    func set(text: String) {
        textView.text = text
        applySkillPresentationIfNeeded()
        updatePlaceholderAlpha()
        switchToRequiredStatus()
        updateTextHeight()
    }

    func beginVoiceRecording() {
        isVoiceRecording = true
        voiceTranscriptText = ""
        textView.text = ""
        textView.resignFirstResponder()
        textView.isEditable = false
        textView.isSelectable = false
        voiceActivityIndicator.startAnimating()
        updateTextHeight()
        switchToRequiredStatus()
    }

    func updateVoiceTranscript(_ text: String) {
        guard isVoiceRecording else { return }
        voiceTranscriptText = text
        textView.text = text
        updateTextHeight()
    }

    func finishVoiceRecording(applyTranscript: Bool) -> String {
        let transcript = voiceTranscriptText.trimmingCharacters(in: .whitespacesAndNewlines)
        isVoiceRecording = false
        voiceTranscriptText = ""
        textView.isEditable = true
        textView.isSelectable = true
        voiceActivityIndicator.stopAnimating()
        textView.text = ""
        updateTextHeight()
        switchToRequiredStatus()
        return applyTranscript ? transcript : ""
    }

    func applySkillPresentationIfNeeded() {
        guard !isApplyingTextPresentation else { return }

        let originalText = textView.text ?? ""
        let originalSelection = textView.selectedRange
        let completed = autocompleteSkillCommandIfNeeded(text: originalText, selection: originalSelection)
        let text = completed?.text ?? originalText
        let selection = completed?.selection ?? originalSelection

        isApplyingTextPresentation = true
        defer { isApplyingTextPresentation = false }

        if textView.text != text {
            textView.text = text
        }

        let attributed = NSMutableAttributedString(
            string: text,
            attributes: baseTextAttributes()
        )
        if let range = highlightedSkillCommandRange(in: text) {
            attributed.addAttributes([
                .foregroundColor: ChatUIDesign.Color.brandOrange,
                .font: UIFont.systemFont(ofSize: font.pointSize, weight: .semibold),
            ], range: range)
        }

        textView.attributedText = attributed
        textView.typingAttributes = baseTextAttributes()
        textView.selectedRange = selection.clamped(to: text.utf16.count)
    }

    private func baseTextAttributes() -> [NSAttributedString.Key: Any] {
        [
            .font: font,
            .foregroundColor: ChatUIDesign.Color.offBlack,
        ]
    }

    private func autocompleteSkillCommandIfNeeded(text: String, selection: NSRange) -> (text: String, selection: NSRange)? {
        guard selection.length == 0,
              selection.location == text.utf16.count,
              text.hasPrefix("/"),
              !text.contains(where: \.isWhitespace)
        else {
            return nil
        }

        let command = text
        guard command.count > 1 else { return nil }

        let matches = availableSkillCommands().filter { $0.hasPrefix(command) }
        guard matches.count == 1, let match = matches.first, match != command else {
            return nil
        }

        let completedText = match + " "
        return (
            completedText,
            NSRange(location: completedText.utf16.count, length: 0)
        )
    }

    func highlightedSkillCommandRange(in text: String) -> NSRange? {
        guard text.hasPrefix("/") else { return nil }
        let commandEnd = text.firstIndex(where: \.isWhitespace) ?? text.endIndex
        let command = String(text[..<commandEnd])
        guard availableSkillCommands().contains(command) else { return nil }
        return NSRange(text.startIndex ..< commandEnd, in: text)
    }

    private func availableSkillCommands() -> [String] {
        var commands: [String] = []
        for item in configuration.quickSettingItems {
            guard case let .skill(_, _, _, prompt, _) = item,
                  let command = extractSlashCommand(from: prompt)
            else {
                continue
            }
            commands.append(command)
        }
        return Array(Set(commands)).sorted()
    }

    private func extractSlashCommand(from prompt: String) -> String? {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }
        let commandEnd = trimmed.firstIndex(where: \.isWhitespace) ?? trimmed.endIndex
        let command = String(trimmed[..<commandEnd])
        return command.count > 1 ? command : nil
    }
}

private extension NSRange {
    func clamped(to upperBound: Int) -> NSRange {
        NSRange(location: min(location, upperBound), length: 0)
    }
}

final class VoiceWaveIndicatorView: UIView {
    private let bars: [UIView] = (0 ..< 3).map { _ in
        let bar = UIView()
        bar.layer.cornerRadius = 1.5
        bar.layer.cornerCurve = .continuous
        return bar
    }

    private var isAnimating = false

    override var tintColor: UIColor! {
        didSet {
            for bar in bars {
                bar.backgroundColor = tintColor
            }
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        for bar in bars {
            bar.backgroundColor = .secondaryLabel
            addSubview(bar)
        }
        alpha = 0
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let barWidth: CGFloat = max(2, bounds.width * 0.14)
        let spacing: CGFloat = barWidth * 0.55
        let contentWidth = barWidth * 3 + spacing * 2
        let startX = (bounds.width - contentWidth) / 2
        let minHeight: CGFloat = max(5, bounds.height * 0.28)
        let maxHeight: CGFloat = max(10, bounds.height * 0.68)
        let heights: [CGFloat] = [minHeight, maxHeight, minHeight]

        for (index, bar) in bars.enumerated() {
            let x = startX + CGFloat(index) * (barWidth + spacing)
            let height = heights[index]
            bar.frame = CGRect(x: x, y: (bounds.height - height) / 2, width: barWidth, height: height)
        }
    }

    func startAnimating() {
        guard !isAnimating else { return }
        isAnimating = true
        alpha = 1

        for (index, bar) in bars.enumerated() {
            let animation = CABasicAnimation(keyPath: "transform.scale.y")
            animation.fromValue = 0.45
            animation.toValue = 1.0
            animation.duration = 0.55
            animation.autoreverses = true
            animation.repeatCount = .infinity
            animation.beginTime = CACurrentMediaTime() + Double(index) * 0.14
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            bar.layer.add(animation, forKey: "voice.wave")
        }
    }

    func stopAnimating() {
        guard isAnimating else { return }
        isAnimating = false
        for bar in bars {
            bar.layer.removeAnimation(forKey: "voice.wave")
        }
        alpha = 0
    }
}
