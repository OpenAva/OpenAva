//
//  BlockButton.swift
//  LanguageModelChatUI
//

import UIKit

/// Reusable base button for chat input supplement actions.
class BlockButton: UIButton {
    let borderView = UIView()
    let iconView = UIImageView()
    let textLabel = UILabel()

    override var titleLabel: UILabel? {
        get { nil }
        set { assertionFailure() }
    }

    var actionBlock: () -> Void = {}

    let font = UIFont.systemFont(ofSize: 13, weight: .regular)
    let spacing: CGFloat = 6
    let inset: CGFloat = 7
    let iconSize: CGFloat = 15

    var strikeThrough: Bool = false {
        didSet { updateStrikes() }
    }

    init(text: String, icon: String) {
        super.init(frame: .zero)

        addSubview(borderView)
        addSubview(iconView)
        addSubview(textLabel)

        iconView.image = UIImage.chatInputIcon(named: icon)
        textLabel.text = text

        applyDefaultAppearance()

        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (button: Self, _) in
            button.applyDefaultAppearance()
            button.updateAppearanceAfterTraitChange()
        }

        isUserInteractionEnabled = true
        let gesture = UITapGestureRecognizer(target: self, action: #selector(onTapped))
        addGestureRecognizer(gesture)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }

    override var intrinsicContentSize: CGSize {
        .init(
            width: ceil(inset + iconSize + spacing + textLabel.intrinsicContentSize.width + inset),
            height: ceil(max(iconSize, textLabel.intrinsicContentSize.height) + inset * 2)
        )
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        borderView.frame = bounds
        iconView.frame = .init(
            x: inset,
            y: (bounds.height - iconSize) / 2,
            width: iconSize,
            height: iconSize
        )
        textLabel.frame = .init(
            x: iconView.frame.maxX + spacing,
            y: inset,
            width: bounds.width - iconView.frame.maxX - spacing - inset,
            height: bounds.height - inset * 2
        )
    }

    @objc private func onTapped() {
        guard !showsMenuAsPrimaryAction else { return }
        puddingAnimate()
        actionBlock()
    }

    func applyDefaultAppearance() {
        borderView.backgroundColor = .clear
        borderView.layer.borderColor = ChatUIDesign.Color.oatBorder.cgColor
        borderView.layer.borderWidth = 1
        borderView.layer.cornerRadius = ChatUIDesign.Radius.button
        borderView.layer.cornerCurve = .continuous

        iconView.tintColor = ChatUIDesign.Color.offBlack
        iconView.contentMode = .scaleAspectFit

        textLabel.font = font
        textLabel.textColor = ChatUIDesign.Color.offBlack
        textLabel.numberOfLines = 1
        textLabel.textAlignment = .center

        updateStrikes()
    }

    func updateStrikes() {
        let baseText = textLabel.text ?? ""
        let attributed = (textLabel.attributedText?.mutableCopy() as? NSMutableAttributedString)
            ?? NSMutableAttributedString(string: baseText)

        attributed.addAttribute(
            .strikethroughStyle,
            value: strikeThrough ? 1 : 0,
            range: NSRange(location: 0, length: attributed.length)
        )

        textLabel.attributedText = attributed
    }

    func updateAppearanceAfterTraitChange() {}

    func updateContent(text: String, icon: String? = nil) {
        textLabel.attributedText = nil
        textLabel.text = text
        if let icon {
            iconView.image = UIImage.chatInputIcon(named: icon)
        }
        updateStrikes()
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }
}
