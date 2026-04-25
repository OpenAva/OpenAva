//
//  ChatInputView.swift
//  ChatUI
//

import Combine
import UIKit

@MainActor
open class ChatInputView: EditorSectionView {
    var storage: TemporaryStorage = .init(id: "-1")
    public var usesAutoLayoutHeightConstraint = true {
        didSet {
            guard !usesAutoLayoutHeightConstraint, heightContraints.isActive else { return }
            heightContraints.isActive = false
        }
    }

    public var configuration: ChatInputConfiguration = .default {
        didSet { applyConfiguration() }
    }

    public required init() {
        super.init()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationWillResignActive),
            name: UIApplication.willResignActiveNotification,
            object: nil
        )
    }

    @available(*, unavailable)
    public required init?(coder _: NSCoder) {
        fatalError()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    let attachmentsBar = AttachmentsBar()
    let inputEditor = InputEditor()
    let quickSettingBar = QuickSettingBar()
    let controlPanel = ControlPanel()

    let backgroundBlurView = UIVisualEffectView(effect: UIBlurEffect(style: .regular))
    let shadowContainer = UIView()
    let dropContainer = DropView()
    let dropColorView = UIView()
    let attachmentSeprator = UIView()
    let controlPanelSeparator = UIView()
    public var selectedModelName: String? {
        didSet {
            guard let selectedModelName else {
                inputEditor.modelButton.setTitle(nil, for: .normal)
                if #available(iOS 15.0, *) {
                    var configuration = inputEditor.modelButton.configuration ?? .plain()
                    configuration.title = nil
                    inputEditor.modelButton.configuration = configuration
                }
                inputEditor.setNeedsLayout()
                return
            }

            // On iOS/macCatalyst, button size changes require explicit layout passes
            UIView.performWithoutAnimation {
                inputEditor.modelButton.setTitle(selectedModelName, for: .normal)
                if #available(iOS 15.0, *) {
                    var configuration = inputEditor.modelButton.configuration ?? .plain()
                    configuration.title = selectedModelName
                    inputEditor.modelButton.configuration = configuration
                }

                // Force size to update immediately
                inputEditor.modelButton.sizeToFit()
                inputEditor.setNeedsLayout()
                inputEditor.layoutIfNeeded()
            }
        }
    }

    public var modelButtonMenu: UIMenu? {
        get { inputEditor.modelButton.menu }
        set { inputEditor.modelButton.menu = newValue }
    }

    public var isModelButtonHidden: Bool {
        get { inputEditor.modelButton.isHidden }
        set { inputEditor.modelButton.isHidden = newValue }
    }

    var voiceRecognitionSession: SpeechRecognitionSession?

    private var glassEffectView: UIVisualEffectView?

    private var useGlassEffect: Bool {
        if #available(iOS 26, *) { return true }
        return false
    }

    lazy var sectionSubviews: [EditorSectionView] = [
        attachmentsBar,
        inputEditor,
        controlPanel,
    ]

    let spacing: CGFloat = 16
    var keyboardAdditionalHeight: CGFloat = 0 {
        didSet { setNeedsLayout() }
    }

    public var bottomBackgroundExtension: CGFloat = 0 {
        didSet {
            guard oldValue != bottomBackgroundExtension else { return }
            setNeedsLayout()
        }
    }

    public weak var delegate: ChatInputDelegate?
    var objectTransactionInProgress = false
    var heightContraints: NSLayoutConstraint = .init()
    var lastTextForSkillList: String?

    var handlerColor: UIColor = .init {
        switch $0.userInterfaceStyle {
        case .light:
            .white
        default:
            .gray.withAlphaComponent(0.1)
        }
    } {
        didSet {
            if !useGlassEffect {
                shadowContainer.backgroundColor = handlerColor
            }
        }
    }

    override public func initializeViews() {
        super.initializeViews()

        backgroundBlurView.isHidden = true
        addSubview(backgroundBlurView)
        // Make the corner radius larger to match the app window
        shadowContainer.layer.cornerRadius = 24
        shadowContainer.layer.cornerCurve = .continuous
        shadowContainer.layer.borderWidth = 1
        shadowContainer.layer.borderColor = ChatUIDesign.Color.oatBorder.cgColor
        shadowContainer.clipsToBounds = false
        addSubview(shadowContainer)

        if #available(iOS 26, *) {
            let glass = UIGlassEffect()
            glass.isInteractive = true
            let effectView = UIVisualEffectView(effect: glass)
            effectView.layer.cornerRadius = shadowContainer.layer.cornerRadius
            effectView.layer.cornerCurve = .continuous
            effectView.clipsToBounds = true
            addSubview(effectView)
            glassEffectView = effectView

            shadowContainer.backgroundColor = .clear
        } else {
            shadowContainer.backgroundColor = ChatUIDesign.Color.warmCream
            shadowContainer.layer.shadowColor = UIColor.black.cgColor
            shadowContainer.layer.shadowOpacity = 0.08 // subtle shadow for floating effect
            shadowContainer.layer.shadowRadius = 12
            shadowContainer.layer.shadowOffset = CGSize(width: 0, height: 4)
        }

        dropContainer.clipsToBounds = true
        dropContainer.layer.cornerRadius = shadowContainer.layer.cornerRadius
        addSubview(dropContainer)
        dropColorView.backgroundColor = UIColor.tintColor.withAlphaComponent(0.05)
        dropColorView.alpha = 0.01
        dropContainer.addSubview(dropColorView)
        dropContainer.addInteraction(UIDropInteraction(delegate: self))
        defer { bringSubviewToFront(dropContainer) }

        for subview in sectionSubviews {
            addSubview(subview)
        }

        attachmentSeprator.backgroundColor = .gray.withAlphaComponent(0.25)
        addSubview(attachmentSeprator)

        controlPanelSeparator.backgroundColor = .gray.withAlphaComponent(0.25)
        addSubview(controlPanelSeparator)

        inputEditor.delegate = self
        controlPanel.delegate = self
        quickSettingBar.delegate = self
        attachmentsBar.delegate = self

        quickSettingBar.horizontalAdjustment = spacing

        applyConfiguration()

        Task { @MainActor in
            restoreEditorStatusIfPossible()
        }

        heightPublisher
            .removeDuplicates()
            .ensureMainThread()
            .sink { [weak self] output in
                self?.updateHeightConstraint(output)
            }
            .store(in: &cancellables)
    }

    override public func layoutSubviews() {
        super.layoutSubviews()

        backgroundBlurView.frame = bounds
        var y: CGFloat = spacing
        var finalHeight: CGFloat = 0
        for subview in sectionSubviews {
            let viewHeight = subview.heightPublisher.value
            let horizontalAdjustment = subview.horizontalAdjustment

            if viewHeight > 0 {
                subview.frame = CGRect(
                    x: spacing - horizontalAdjustment,
                    y: y,
                    width: bounds.width - spacing * 2 + horizontalAdjustment * 2,
                    height: subview.heightPublisher.value
                )
                finalHeight = subview.frame.maxY
                y = finalHeight + spacing
            } else {
                subview.frame = CGRect(
                    x: spacing - horizontalAdjustment,
                    y: y,
                    width: bounds.width - spacing * 2 + horizontalAdjustment * 2,
                    height: 0
                )
            }
        }

        let containerTopY = attachmentsBar.heightPublisher.value > 0 ? attachmentsBar.frame.minY : inputEditor.frame.minY
        let containerBottomY = controlPanel.heightPublisher.value > 0 ? controlPanel.frame.maxY + spacing : inputEditor.frame.maxY

        shadowContainer.frame = .init(
            x: spacing,
            y: containerTopY,
            width: bounds.width - spacing * 2,
            height: containerBottomY - containerTopY
        )

        if attachmentsBar.heightPublisher.value > 0 {
            attachmentSeprator.alpha = 1
        } else {
            attachmentSeprator.alpha = 0
        }

        if let glassEffectView {
            glassEffectView.frame = shadowContainer.frame
        }

        if !useGlassEffect {
            shadowContainer.layer.shadowPath = UIBezierPath(
                roundedRect: shadowContainer.bounds,
                cornerRadius: shadowContainer.layer.cornerRadius
            ).cgPath
        }

        attachmentSeprator.frame = .init(
            x: shadowContainer.frame.minX,
            y: inputEditor.frame.minY - 0.5,
            width: shadowContainer.frame.width,
            height: 1
        )

        controlPanelSeparator.frame = .init(
            x: shadowContainer.frame.minX,
            y: controlPanel.frame.minY - (spacing / 2),
            width: shadowContainer.frame.width,
            height: 1
        )
        if controlPanel.heightPublisher.value > 0 {
            controlPanelSeparator.alpha = 1
        } else {
            controlPanelSeparator.alpha = 0
        }

        dropContainer.frame = shadowContainer.frame
        dropColorView.frame = dropContainer.bounds

        let totalHeightForLayout = controlPanel.heightPublisher.value > 0 ? finalHeight + spacing : finalHeight
        heightPublisher.send(totalHeightForLayout + keyboardAdditionalHeight + spacing)
    }

    public func quickSettingButton(forCommand command: String) -> UIView? {
        if command == "/context" {
            return inputEditor.contextButton
        }
        return quickSettingBar.button(forCommand: command)
    }

    public func updateQuickSettingCommand(command: String, title: String, icon: String? = nil) {
        quickSettingBar.updateCommand(command: command, title: title, icon: icon)
    }

    public func clearTemporaryStorage() {
        storage.removeAll()
    }

    public func setExecuting(_ executing: Bool) {
        guard inputEditor.isExecuting != executing else { return }
        inputEditor.isExecuting = executing
        if executing {
            controlPanel.close()
        }
        setNeedsLayout()
        layoutIfNeeded()
    }

    func updateHeightConstraint(_ height: CGFloat) {
        guard usesAutoLayoutHeightConstraint else {
            if heightContraints.isActive {
                heightContraints.isActive = false
            }
            setNeedsLayout()
            layoutIfNeeded()
            parentViewController?.view.setNeedsLayout()
            parentViewController?.view.layoutIfNeeded()
            return
        }
        guard heightContraints.constant != height else { return }
        heightContraints.isActive = false
        heightContraints = heightAnchor.constraint(equalToConstant: height)
        heightContraints.priority = .defaultHigh
        heightContraints.isActive = true
        setNeedsLayout()
        layoutIfNeeded()
        parentViewController?.view.setNeedsLayout()
        parentViewController?.view.layoutIfNeeded()
    }

    func doCoordinatedLayoutAnimation(
        duration: TimeInterval = 0.5,
        _ execute: @escaping () -> Void,
        completion: @escaping () -> Void = {}
    ) {
        layoutIfNeeded()
        parentViewController?.view.layoutIfNeeded()
        UIView.animate(
            withDuration: duration,
            delay: 0,
            usingSpringWithDamping: 0.9,
            initialSpringVelocity: 1.0,
            options: .curveEaseInOut
        ) {
            execute()
            self.setNeedsLayout()
            self.layoutIfNeeded()
            self.parentViewController?.view.setNeedsLayout()
            self.parentViewController?.view.layoutIfNeeded()
        } completion: { _ in
            completion()
        }
    }

    public func focus() {
        inputEditor.textView.becomeFirstResponder()
    }

    public func prepareForReuse() {
        storage = .init(id: "-1")
        resetValues()
    }

    public func bind(sessionID: String) {
        storage = .init(id: sessionID)
        restoreEditorStatusIfPossible()
    }

    func applyConfiguration() {
        inputEditor.configuration = configuration
        quickSettingBar.configure(with: configuration.quickSettingItems)
        controlPanel.configure(with: configuration.controlPanelItems)
    }

    func dismissSkillListIfNeeded() {
        guard let parent = parentViewController else { return }
        if let presented = parent.presentedViewController as? SkillListPopoverController {
            presented.dismiss(animated: false)
        }
    }

    func presentSkillList() {
        guard let parent = parentViewController else { return }
        if parent.presentedViewController is SkillListPopoverController { return }

        var validItems: [QuickSettingItem] = []
        for item in configuration.quickSettingItems {
            switch item {
            case .skill:
                validItems.append(item)
            case let .command(_, _, _, command):
                if command != "/context" {
                    validItems.append(item)
                }
            default: break
            }
        }

        guard !validItems.isEmpty else { return }

        let listVC = SkillListPopoverController(
            items: validItems,
            onSelect: { [weak self] selectedItem in
                guard let self else { return }
                switch selectedItem {
                case let .skill(_, _, _, prompt, autoSubmit):
                    self.delegate?.chatInputDidTriggerSkill(self, prompt: prompt, autoSubmit: autoSubmit)
                    if autoSubmit {
                        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        self.refill(withText: trimmed, attachments: [])
                        self.submitValues()
                    } else {
                        self.inputEditor.set(text: prompt + " ")
                        self.inputEditor.textView.becomeFirstResponder()
                    }
                case let .command(_, _, _, command):
                    self.delegate?.chatInputDidTriggerCommand(self, command: command)
                default: break
                }
            },
            onDismiss: { [weak self] in
                guard let self else { return }

                // When the popover is dismissed (e.g. by pressing ESC or clicking outside),
                // we want to return focus to the text view if it's not currently focused.
                // This ensures the user can press Backspace to delete the "/".
                DispatchQueue.main.async {
                    if !self.inputEditor.textView.isFirstResponder {
                        self.inputEditor.textView.becomeFirstResponder()
                    }
                }
            }
        )

        let estimatedRowHeight: CGFloat = 60
        let chromeHeight: CGFloat = 46
        let estimatedHeight = CGFloat(validItems.count) * estimatedRowHeight + chromeHeight
        listVC.preferredContentSize = CGSize(width: 420, height: min(max(estimatedHeight, 240), 460))

        if let popover = listVC.popoverPresentationController {
            popover.sourceView = inputEditor.textView
            if let selectedRange = inputEditor.textView.selectedTextRange {
                let caretRect = inputEditor.textView.caretRect(for: selectedRange.start)
                popover.sourceRect = caretRect
            } else {
                popover.sourceRect = inputEditor.textView.bounds
            }
            popover.permittedArrowDirections = [.down, .up]
        }

        parent.present(listVC, animated: true)
    }

    @objc private func applicationWillResignActive() {
        stopInlineSpeechRecognition(applyTranscript: false)
        publishNewEditorStatus()
    }

    // MARK: - Responder chain helper

    var parentViewController: UIViewController? {
        var responder: UIResponder? = self
        while let next = responder?.next {
            if let vc = next as? UIViewController { return vc }
            responder = next
        }
        return nil
    }
}
