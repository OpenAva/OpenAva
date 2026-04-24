//
//  ToolResultContentView.swift
//  ChatUI
//
//  Displays expanded tool result content styled to match ReasoningContentView:
//  left indicator bar + footnote-sized secondary-label text.
//

import Litext
import MarkdownView
import UIKit

final class ToolResultContentView: MessageListRowView {
    private lazy var indicator: UIView = .init()
    private lazy var scrollView: UIScrollView = .init().with {
        $0.showsVerticalScrollIndicator = true
        $0.showsHorizontalScrollIndicator = false
    }

    private var sectionViews: [SectionView] = []

    private static let contentLeading: CGFloat = 14
    private static let indicatorWidth: CGFloat = 2

    override init(frame: CGRect) {
        super.init(frame: frame)

        indicator.layer.cornerRadius = 1
        indicator.backgroundColor = .secondaryLabel
        indicator.alpha = 0.6
        contentView.addSubview(indicator)

        contentView.addSubview(scrollView)
    }

    @available(*, unavailable)
    @MainActor required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(with representation: MessageListView.ToolResultRepresentation) {
        sectionViews.forEach { $0.removeFromSuperview() }
        sectionViews.removeAll()

        if representation.hasParameters {
            let section = SectionView(title: String.localized("Tool Arguments"), content: representation.formattedParameters, theme: theme)
            scrollView.addSubview(section)
            sectionViews.append(section)
        }
        if representation.hasResult {
            let section = SectionView(title: String.localized("Tool Result"), content: representation.formattedResult, theme: theme)
            scrollView.addSubview(section)
            sectionViews.append(section)
        }
        setNeedsLayout()
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

        scrollView.frame = .init(
            x: textX,
            y: 0,
            width: textWidth,
            height: contentView.bounds.height
        )

        var currentY: CGFloat = 0
        for (index, section) in sectionViews.enumerated() {
            let sectionHeight = section.contentHeight(for: textWidth)
            section.frame = CGRect(x: 0, y: currentY, width: textWidth, height: sectionHeight)
            currentY += sectionHeight
            if index < sectionViews.count - 1 {
                currentY += 16
            }
        }

        scrollView.contentSize = CGSize(width: textWidth, height: currentY)
    }
}

private class SectionView: UIView {
    let titleLabel = UILabel()
    let codeContainer = UIView()
    let codeLabel = LTXLabel()
    let theme: MarkdownTheme
    let content: String

    init(title: String, content: String, theme: MarkdownTheme) {
        self.theme = theme
        self.content = content
        super.init(frame: .zero)

        titleLabel.text = title
        titleLabel.font = theme.fonts.footnote.bold
        titleLabel.textColor = theme.colors.body
        titleLabel.numberOfLines = 0
        addSubview(titleLabel)

        codeContainer.backgroundColor = .secondarySystemFill.withAlphaComponent(0.08)
        codeContainer.layer.cornerRadius = 8
        codeContainer.layer.cornerCurve = .continuous
        addSubview(codeContainer)

        codeLabel.isSelectable = true
        codeLabel.backgroundColor = .clear
        codeLabel.selectionBackgroundColor = theme.colors.selectionBackground

        // Ensure character wrapping!

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 4
        paragraphStyle.lineBreakMode = .byCharWrapping

        codeLabel.attributedText = NSAttributedString(string: content, attributes: [
            .font: theme.fonts.code,
            .foregroundColor: theme.colors.code,
            .paragraphStyle: paragraphStyle,
        ])
        codeContainer.addSubview(codeLabel)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func contentHeight(for width: CGFloat) -> CGFloat {
        let titleSize = titleLabel.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        let codeWidth = max(0, width - 16)

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 4
        paragraphStyle.lineBreakMode = .byCharWrapping
        let codeString = NSAttributedString(string: content, attributes: [
            .font: theme.fonts.code,
            .paragraphStyle: paragraphStyle,
        ])

        let codeRect = codeString.boundingRect(with: CGSize(width: codeWidth, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        let codeHeight = ceil(codeRect.height)

        let containerHeight = codeHeight + 16 // 8pt padding top/bottom

        return titleSize.height + 8 + containerHeight
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = bounds.width

        let titleSize = titleLabel.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        titleLabel.frame = CGRect(x: 0, y: 0, width: width, height: titleSize.height)

        let codeWidth = max(0, width - 16)

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 4
        paragraphStyle.lineBreakMode = .byCharWrapping
        let codeString = NSAttributedString(string: content, attributes: [
            .font: theme.fonts.code,
            .paragraphStyle: paragraphStyle,
        ])

        let codeRect = codeString.boundingRect(with: CGSize(width: codeWidth, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        let codeHeight = ceil(codeRect.height)

        let containerHeight = codeHeight + 16 // 8pt padding top/bottom
        codeContainer.frame = CGRect(x: 0, y: titleLabel.frame.maxY + 8, width: width, height: containerHeight)

        codeLabel.preferredMaxLayoutWidth = codeWidth
        codeLabel.frame = CGRect(x: 8, y: 8, width: codeWidth, height: codeHeight)
    }
}
