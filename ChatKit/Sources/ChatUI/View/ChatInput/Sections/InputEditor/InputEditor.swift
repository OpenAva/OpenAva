//
//  InputEditor.swift
//  ChatUI
//

import Combine
import UIKit

final class InputEditor: EditorSectionView {
    private let primaryActionSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 15, weight: .bold)
    let font = UIFont.systemFont(ofSize: 16, weight: .regular)
    let textHeight: CurrentValueSubject<CGFloat, Never> = .init(0)
    let maxTextEditorHeight: CGFloat = 200
    private var isApplyingTextPresentation = false

    let elementClipper = UIView()

    let bossButton = IconButton(icon: "plus")
    let contextButton = IconButton(icon: "gauge")
    let modelButton: UIButton = {
        let button = UIButton(type: .custom)
        #if targetEnvironment(macCatalyst)
            if #available(macCatalyst 15.0, *) {
                button.preferredBehavioralStyle = .pad
            }
        #endif
        let config = UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        let chevronImage = UIImage(systemName: "chevron.down", withConfiguration: config)
        button.setImage(chevronImage, for: .normal)

        button.titleLabel?.font = UIFont.systemFont(ofSize: 14, weight: .medium)

        if #available(iOS 15.0, *) {
            var configuration = UIButton.Configuration.plain()
            configuration.imagePlacement = .trailing
            configuration.imagePadding = 4
            configuration.contentInsets = .zero
            button.configuration = configuration
        } else {
            button.imageEdgeInsets = UIEdgeInsets(top: 0, left: 4, bottom: 0, right: 0)
        }

        button.showsMenuAsPrimaryAction = true
        return button
    }()

    let textView = TextEditorView()
    let placeholderLabel = UILabel()
    let voiceButton = IconButton(icon: "mic")
    let stopVoiceButton = IconButton(icon: "stop.fill")
    let cancelVoiceButton = IconButton(icon: "xmark")
    let voiceActivityIndicator = VoiceWaveIndicatorView()
    let moreButton = IconButton(icon: "plus.circle") // Can remove moreButton later, or use bossButton
    let sendButton = IconButton(icon: "arrow.up.circle.fill")

    let inset: UIEdgeInsets = .init(top: 14, left: 14, bottom: 10, right: 14)
    let iconSpacing: CGFloat = 16
    let iconSize = CGSize(width: 24, height: 24)
    let sendButtonSize = CGSize(width: 36, height: 36)

    var isControlPanelOpened: Bool = false {
        didSet { moreButton.change(icon: isControlPanelOpened ? "x.circle" : "plus.circle") }
    }

    var isExecuting = false {
        didSet {
            guard oldValue != isExecuting else { return }
            updatePrimaryActionButtonAppearance()
            textView.returnKeyType = isExecuting ? .default : .send
            switchToRequiredStatus()
        }
    }

    enum LayoutStatus {
        case standard
        case preFocusText
        case editingText
        case voiceRecording
        case executing
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
            self?.delegate?.onInputEditorToggleMoreButtonTapped()
        }
        addSubview(elementClipper)
        elementClipper.clipsToBounds = true
        elementClipper.addSubview(bossButton)

        contextButton.tapAction = { [weak self] in
            self?.delegate?.onInputEditorContextButtonTapped()
        }
        elementClipper.addSubview(contextButton)
        elementClipper.addSubview(modelButton)

        let secondaryColor = ChatUIDesign.Color.black60
        bossButton.imageView.tintColor = secondaryColor
        contextButton.imageView.tintColor = secondaryColor
        modelButton.tintColor = secondaryColor
        voiceButton.imageView.tintColor = secondaryColor

        for item in [cancelVoiceButton, stopVoiceButton] {
            item.backgroundColor = ChatUIDesign.Color.offBlack
            item.layer.cornerRadius = sendButtonSize.height / 2
            item.layer.cornerCurve = .continuous
            item.clipsToBounds = true
            item.imageInsets = .init(top: 10, left: 10, bottom: 10, right: 10)
            item.imageView.tintColor = ChatUIDesign.Color.pureWhite
        }
        cancelVoiceButton.imageView.image = UIImage(
            systemName: "xmark",
            withConfiguration: primaryActionSymbolConfiguration
        )?.withRenderingMode(.alwaysTemplate)
        stopVoiceButton.imageView.image = UIImage(
            systemName: "stop.fill",
            withConfiguration: primaryActionSymbolConfiguration
        )?.withRenderingMode(.alwaysTemplate)

        sendButton.backgroundColor = ChatUIDesign.Color.offBlack
        sendButton.layer.cornerRadius = sendButtonSize.height / 2
        sendButton.layer.cornerCurve = .continuous
        sendButton.clipsToBounds = true
        sendButton.imageInsets = .init(top: 10, left: 10, bottom: 10, right: 10)
        sendButton.imageView.tintColor = ChatUIDesign.Color.pureWhite
        updatePrimaryActionButtonAppearance()

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
        textView.clipsToBounds = true
        textView.isSelectable = true
        textView.isScrollEnabled = false
        textView.isEditable = true
        textView.returnKeyType = .send
        textView.onReturnKeyPressed = { [weak self] in
            guard let self else { return }
            textView.insertText("\n")
        }
        textView.onCommandReturnKeyPressed = { [weak self] in
            guard let self, !self.isExecuting else { return }
            let text = (self.textView.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { return } // Do not allow submit via shortcut if text is empty or only whitespace
            self.sendButton.tapAction()
        }
        textView.onImagePasted = { [weak self] image in
            self?.delegate?.onInputEditorPastingImage(image: image)
        }
        elementClipper.addSubview(textView)
        placeholderLabel.text = String.localized("Ask anything or type / for skills")
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
            guard let self else { return }
            if isExecuting {
                delegate?.onInputEditorStopButtonTapped()
            } else {
                delegate?.onInputEditorSubmitButtonTapped()
            }
        }
        elementClipper.addSubview(sendButton)

        textHeight.removeDuplicates()
            .compactMap { [weak self] textHeight -> CGFloat? in
                guard let self else { return nil }
                // Calculate height for two rows: Text View (top) + Toolbar (bottom)
                // Note: sendButtonSize.height is slightly larger than iconSize.height
                return textLayoutHeight(textHeight) + max(iconSize.height, sendButtonSize.height) + inset.top + inset.bottom + 12 // 12 is spacing between text and icons
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
        case .executing:
            layoutAsExecuting()
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

    private var originalTextBeforeVoice = ""

    func beginVoiceRecording() {
        isVoiceRecording = true
        originalTextBeforeVoice = textView.text ?? ""
        voiceTranscriptText = ""

        // We do not clear the text entirely, we will show originalTextBeforeVoice + current transcript
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

        let needsSpace = !originalTextBeforeVoice.isEmpty &&
            !originalTextBeforeVoice.hasSuffix(" ") &&
            !originalTextBeforeVoice.hasSuffix("\n")
        let space = needsSpace ? " " : ""

        textView.text = originalTextBeforeVoice + space + text
        updateTextHeight()
    }

    func finishVoiceRecording(applyTranscript: Bool) -> String {
        let transcript = voiceTranscriptText.trimmingCharacters(in: .whitespacesAndNewlines)
        isVoiceRecording = false
        voiceTranscriptText = ""
        textView.isEditable = true
        textView.isSelectable = true
        voiceActivityIndicator.stopAnimating()

        if !applyTranscript {
            // Restore original text if cancelled
            textView.text = originalTextBeforeVoice
        } else {
            // We already updated the textView in updateVoiceTranscript, but let's make sure it's set
            let needsSpace = !originalTextBeforeVoice.isEmpty &&
                !originalTextBeforeVoice.hasSuffix(" ") &&
                !originalTextBeforeVoice.hasSuffix("\n")
            let space = needsSpace ? " " : ""
            textView.text = originalTextBeforeVoice + (transcript.isEmpty ? "" : (space + transcript))
        }

        originalTextBeforeVoice = ""
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
        for range in highlightedMentionRanges(in: text) {
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

    func highlightedMentionRanges(in text: String) -> [NSRange] {
        guard !text.isEmpty else { return [] }

        let nsText = text as NSString
        var ranges: [NSRange] = []
        var index = 0

        while index < nsText.length {
            let character = nsText.character(at: index)
            if character == 64,
               index == 0 || isMentionBoundaryCharacter(nsText.character(at: index - 1))
            {
                var upperBound = index + 1
                while upperBound < nsText.length,
                      !isMentionBoundaryCharacter(nsText.character(at: upperBound))
                {
                    upperBound += 1
                }

                if upperBound > index + 1 {
                    ranges.append(NSRange(location: index, length: upperBound - index))
                }

                index = upperBound
                continue
            }

            index += 1
        }

        return ranges
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

    private var mentionBoundarySet: CharacterSet {
        CharacterSet.whitespacesAndNewlines
            .union(.punctuationCharacters)
            .union(.symbols)
    }

    private func isMentionBoundaryCharacter(_ character: unichar) -> Bool {
        guard let scalar = UnicodeScalar(character) else { return false }
        return mentionBoundarySet.contains(scalar)
    }

    private func updatePrimaryActionButtonAppearance() {
        let symbolName = isExecuting ? "stop.fill" : "arrow.up"
        sendButton.imageView.image = UIImage(
            systemName: symbolName,
            withConfiguration: primaryActionSymbolConfiguration
        )?.withRenderingMode(.alwaysTemplate)
    }
}

private extension NSRange {
    func clamped(to upperBound: Int) -> NSRange {
        NSRange(location: min(location, upperBound), length: 0)
    }
}

final class VoiceWaveIndicatorView: UIView {
    private let barCount = 7
    private let bars: [UIView] = (0 ..< 7).map { _ in
        let bar = UIView()
        bar.layer.cornerRadius = 1.5
        bar.layer.cornerCurve = .continuous
        bar.layer.shadowOffset = .zero
        bar.layer.shadowOpacity = 0.16
        bar.layer.shadowRadius = 1.5
        return bar
    }

    private let baseHeights: [CGFloat] = [6, 10, 14, 18, 14, 10, 6]
    private let amplitudes: [Double] = [0.82, 1.08, 1.28, 1.56, 1.28, 1.08, 0.82]
    private let delays: [CFTimeInterval] = [0.24, 0.16, 0.08, 0.0, 0.08, 0.16, 0.24]

    private var isAnimating = false

    override var tintColor: UIColor! {
        didSet {
            for bar in bars {
                bar.backgroundColor = tintColor
                bar.layer.shadowColor = tintColor.cgColor
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
        let barWidth: CGFloat = 3
        let spacing: CGFloat = 5
        let totalWidth = (barWidth * CGFloat(barCount)) + (spacing * CGFloat(barCount - 1))
        let startX = (bounds.width - totalWidth) / 2

        for (index, bar) in bars.enumerated() {
            let height = baseHeights[index]
            let x = startX + CGFloat(index) * (barWidth + spacing)
            bar.frame = CGRect(
                x: x,
                y: (bounds.height - height) / 2,
                width: barWidth,
                height: height
            )
        }
    }

    func startAnimating() {
        guard !isAnimating else { return }
        isAnimating = true
        alpha = 1

        for (index, bar) in bars.enumerated() {
            let scaleAnim = CABasicAnimation(keyPath: "transform.scale.y")
            scaleAnim.fromValue = NSNumber(value: 0.72)
            scaleAnim.toValue = NSNumber(value: amplitudes[index])

            let alphaAnim = CABasicAnimation(keyPath: "opacity")
            alphaAnim.fromValue = NSNumber(value: 0.42)
            alphaAnim.toValue = NSNumber(value: min(1.0, 0.72 + amplitudes[index] * 0.18))

            let glowAnim = CABasicAnimation(keyPath: "shadowOpacity")
            glowAnim.fromValue = NSNumber(value: 0.08)
            glowAnim.toValue = NSNumber(value: 0.22)

            let group = CAAnimationGroup()
            group.animations = [scaleAnim, alphaAnim, glowAnim]
            group.duration = 0.58
            group.autoreverses = true
            group.repeatCount = .infinity
            group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            group.beginTime = CACurrentMediaTime() + delays[index]

            bar.layer.add(group, forKey: "voice.track")
        }
    }

    func stopAnimating() {
        guard isAnimating else { return }
        isAnimating = false
        for bar in bars {
            bar.layer.removeAnimation(forKey: "voice.track")
        }
        alpha = 0
    }
}
