//
//  ToolResultContentView.swift
//  ChatUI
//
//  Displays expanded tool result content styled to match ReasoningContentView:
//  left indicator bar + footnote-sized secondary-label text.
//

import Litext
import UIKit

final class ToolResultContentView: MessageListRowView {
    private lazy var indicator: UIView = .init()
    private lazy var textView: LTXLabel = .init().with {
        $0.isSelectable = true
    }

    // Match ReasoningContentView constants.
    static let paragraphStyle: NSParagraphStyle = ReasoningContentView.paragraphStyle
    private static let contentLeading: CGFloat = 14
    private static let indicatorWidth: CGFloat = 2

    private var rawText: String?

    var text: String? {
        didSet {
            rawText = text
            applyText()
            setNeedsLayout()
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)

        indicator.layer.cornerRadius = 1
        indicator.backgroundColor = .secondaryLabel
        indicator.alpha = 0.6
        contentView.addSubview(indicator)

        textView.backgroundColor = .clear
        contentView.addSubview(textView)
    }

    @available(*, unavailable)
    @MainActor required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func themeDidUpdate() {
        super.themeDidUpdate()
        applyText()
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        indicator.frame = .init(
            x: 0,
            y: 0,
            width: Self.indicatorWidth,
            height: contentView.bounds.height
        )

        let textX = Self.contentLeading
        let textWidth = max(0, contentView.bounds.width - textX)
        textView.preferredMaxLayoutWidth = textWidth
        textView.frame = .init(
            x: textX,
            y: 0,
            width: textWidth,
            height: ceil(textView.intrinsicContentSize.height)
        )
    }

    /// Apply attributed text using current theme fonts/colors.
    private func applyText() {
        guard let rawText else {
            textView.attributedText = .init()
            return
        }
        textView.attributedText = .init(string: rawText, attributes: [
            .font: theme.fonts.footnote,
            .foregroundColor: UIColor.secondaryLabel,
            .paragraphStyle: Self.paragraphStyle,
        ])
    }
}
