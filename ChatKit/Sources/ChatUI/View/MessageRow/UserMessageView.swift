//
//  Created by ktiays on 2025/1/31.
//  Copyright (c) 2025 ktiays. All rights reserved.
//

import ListViewKit
import Litext
import MarkdownView
import UIKit

final class UserMessageView: MessageListRowView {
    static let contentPadding: CGFloat = 20
    static let textPadding: CGFloat = 12
    static let sourceBadgeHeight: CGFloat = 22
    static let sourceBadgeHorizontalPadding: CGFloat = 8
    static let sourceSpacing: CGFloat = 8
    static let maximumIdealWidth: CGFloat = 800

    var text: String? {
        didSet {
            guard let text else {
                attributedText = nil
                return
            }
            let attributed = NSMutableAttributedString(string: text, attributes: [
                .font: theme.fonts.body,
                .foregroundColor: theme.colors.body,
            ])
            if let range = highlightedSkillCommandRange(in: text) {
                attributed.addAttributes([
                    .foregroundColor: ChatUIDesign.Color.brandOrange,
                    .font: UIFont.systemFont(ofSize: theme.fonts.body.pointSize, weight: .semibold),
                ], range: range)
            }
            attributedText = attributed
        }
    }

    var source: MessageListView.MessageSourceRepresentation? {
        didSet {
            let source = source?.showsBadge == true ? source : nil
            sourceBadgeView.isHidden = source == nil
            sourceLabel.text = source?.badgeText
            setNeedsLayout()
            invalidateIntrinsicContentSize()
        }
    }

    private var attributedText: NSAttributedString? {
        didSet {
            textView.attributedText = attributedText ?? .init()
        }
    }

    private let backgroundGradientLayer = CAGradientLayer()
    private let sourceBadgeView: UIView = {
        let view = UIView()
        view.isHidden = true
        view.backgroundColor = UIColor.secondarySystemBackground.withAlphaComponent(0.65)
        view.layer.cornerRadius = UserMessageView.sourceBadgeHeight / 2
        view.layer.cornerCurve = .continuous
        view.layer.borderWidth = 1 / UIScreen.main.scale
        view.layer.borderColor = ChatUIDesign.Color.brandOrange.withAlphaComponent(0.22).cgColor
        return view
    }()

    private let sourceLabel: UILabel = {
        let label = UILabel()
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = ChatUIDesign.Color.brandOrange
        label.numberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        return label
    }()

    private lazy var textView: LTXLabel = .init().with { $0.isSelectable = true }

    override init(frame: CGRect) {
        super.init(frame: frame)

        let accentColor = UIColor.accent
        backgroundGradientLayer.colors = [
            accentColor.withAlphaComponent(0.10).cgColor,
            accentColor.withAlphaComponent(0.15).cgColor,
        ]
        backgroundGradientLayer.startPoint = .init(x: 0.6, y: 0)
        backgroundGradientLayer.endPoint = .init(x: 0.4, y: 1)
        contentView.layer.insertSublayer(backgroundGradientLayer, at: 0)

        contentView.backgroundColor = .clear
        contentView.layer.cornerRadius = ChatUIDesign.Radius.card
        contentView.layer.cornerCurve = .continuous
        contentView.clipsToBounds = true

        sourceBadgeView.addSubview(sourceLabel)
        contentView.addSubview(sourceBadgeView)

        textView.backgroundColor = .clear
        contentView.addSubview(textView)
    }

    @available(*, unavailable)
    @MainActor required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: CGSize {
        let textSize = textView.intrinsicContentSize
        guard !sourceBadgeView.isHidden else { return textSize }
        return .init(
            width: max(textSize.width, sourceBadgeSize(maxWidth: .greatestFiniteMagnitude).width),
            height: textSize.height + Self.sourceBadgeHeight + Self.sourceSpacing
        )
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        let insets = MessageListView.listRowInsets
        let textContainerWidth = Self.availableTextWidth(for: bounds.width - insets.horizontal)
        textView.preferredMaxLayoutWidth = textContainerWidth
        let textSize = textView.intrinsicContentSize
        let maxContentWidth = Self.availableContentWidth(for: bounds.width - insets.horizontal)
        let badgeSize = sourceBadgeView.isHidden ? .zero : sourceBadgeSize(maxWidth: maxContentWidth - Self.textPadding * 2)
        let contentBodyWidth = max(ceil(textSize.width), badgeSize.width)
        let contentWidth = contentBodyWidth + Self.textPadding * 2
        contentView.frame = .init(
            x: bounds.width - contentWidth - insets.right,
            y: 0,
            width: contentWidth,
            height: bounds.height - insets.bottom
        )
        backgroundGradientLayer.frame = contentView.bounds
        backgroundGradientLayer.cornerRadius = contentView.layer.cornerRadius

        var textOriginY = Self.textPadding
        if !sourceBadgeView.isHidden {
            sourceBadgeView.frame = .init(
                x: Self.textPadding,
                y: Self.textPadding,
                width: badgeSize.width,
                height: Self.sourceBadgeHeight
            )
            sourceLabel.frame = sourceBadgeView.bounds.insetBy(dx: Self.sourceBadgeHorizontalPadding, dy: 0)
            textOriginY += Self.sourceBadgeHeight + Self.sourceSpacing
        }

        textView.frame = .init(
            x: Self.textPadding,
            y: textOriginY,
            width: contentView.bounds.width - Self.textPadding * 2,
            height: textSize.height
        )
    }

    @inlinable
    static func availableContentWidth(for width: CGFloat) -> CGFloat {
        max(0, min(maximumIdealWidth, width - contentPadding * 2))
    }

    @inlinable
    static func availableTextWidth(for width: CGFloat) -> CGFloat {
        availableContentWidth(for: width) - textPadding * 2
    }

    private func sourceBadgeSize(maxWidth: CGFloat) -> CGSize {
        let labelWidth = ceil(sourceLabel.intrinsicContentSize.width)
        let width = min(maxWidth, labelWidth + Self.sourceBadgeHorizontalPadding * 2)
        return .init(width: max(0, width), height: Self.sourceBadgeHeight)
    }

    /// Selects all text in the message bubble, showing interactive handles.
    func selectAllText() {
        textView.selectAllText()
    }

    private func highlightedSkillCommandRange(in text: String) -> NSRange? {
        guard text.hasPrefix("/") else { return nil }
        let commandEnd = text.firstIndex(where: \.isWhitespace) ?? text.endIndex
        let command = String(text[..<commandEnd])
        guard command.count > 1 else { return nil }
        return NSRange(text.startIndex ..< commandEnd, in: text)
    }
}
