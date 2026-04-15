//
//  CompactBoundaryMessageView.swift
//  ChatUI
//

import MarkdownView
import UIKit

/// A subtle divider row indicating where conversation history was compacted.
final class CompactBoundaryMessageView: MessageListRowView {
    private let leftLine = UIView()
    private let rightLine = UIView()
    private let titleLabel: UILabel = .init()
    private let detailLabel: UILabel = .init()

    var title: String? {
        get { titleLabel.text }
        set {
            titleLabel.text = newValue
            setNeedsLayout()
        }
    }

    var detail: String? {
        get { detailLabel.text }
        set {
            detailLabel.text = newValue
            detailLabel.isHidden = newValue?.isEmpty ?? true
            setNeedsLayout()
        }
    }

    override var theme: MarkdownTheme {
        didSet { updateStyle() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)

        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 1
        detailLabel.textAlignment = .center
        detailLabel.numberOfLines = 0

        contentView.addSubview(leftLine)
        contentView.addSubview(rightLine)
        contentView.addSubview(titleLabel)
        contentView.addSubview(detailLabel)

        updateStyle()
    }

    @available(*, unavailable)
    @MainActor required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func updateStyle() {
        let lineColor = UIColor.separator.withAlphaComponent(0.45)
        leftLine.backgroundColor = lineColor
        rightLine.backgroundColor = lineColor

        titleLabel.textColor = theme.colors.body.withAlphaComponent(0.72)
        titleLabel.font = theme.fonts.footnote
        detailLabel.textColor = theme.colors.body.withAlphaComponent(0.5)
        detailLabel.font = UIFont.systemFont(ofSize: 11)
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        let bounds = contentView.bounds.insetBy(dx: 8, dy: 0)
        let hasDetail = !(detailLabel.text?.isEmpty ?? true)
        let lineHeight: CGFloat = 1 / UIScreen.main.scale
        let minLineWidth: CGFloat = 24
        let gap: CGFloat = 10
        let titleSize = titleLabel.sizeThatFits(CGSize(width: bounds.width, height: bounds.height))
        let detailMaxWidth = max(0, bounds.width - 32)
        let detailSize = hasDetail
            ? detailLabel.sizeThatFits(CGSize(width: detailMaxWidth, height: bounds.height))
            : .zero
        let titleWidth = min(bounds.width, ceil(titleSize.width))
        let titleHeight = min(bounds.height, ceil(titleSize.height))
        let detailWidth = min(detailMaxWidth, ceil(detailSize.width))
        let detailHeight = min(bounds.height, ceil(detailSize.height))
        let verticalSpacing: CGFloat = hasDetail ? 4 : 0
        let contentHeight = titleHeight + (hasDetail ? detailHeight + verticalSpacing : 0)
        let originY = bounds.midY - contentHeight / 2
        let titleCenterY = originY + titleHeight / 2

        titleLabel.frame = CGRect(
            x: bounds.midX - titleWidth / 2,
            y: originY,
            width: titleWidth,
            height: titleHeight
        )

        if hasDetail {
            detailLabel.frame = CGRect(
                x: bounds.midX - detailWidth / 2,
                y: titleLabel.frame.maxY + verticalSpacing,
                width: detailWidth,
                height: detailHeight
            )
        } else {
            detailLabel.frame = .zero
        }

        let leftEnd = max(bounds.minX, titleLabel.frame.minX - gap)
        let rightStart = min(bounds.maxX, titleLabel.frame.maxX + gap)

        let leftWidth = max(0, leftEnd - bounds.minX)
        let rightWidth = max(0, bounds.maxX - rightStart)

        leftLine.isHidden = leftWidth < minLineWidth
        rightLine.isHidden = rightWidth < minLineWidth

        leftLine.frame = CGRect(x: bounds.minX, y: titleCenterY - lineHeight / 2, width: leftWidth, height: lineHeight)
        rightLine.frame = CGRect(x: rightStart, y: titleCenterY - lineHeight / 2, width: rightWidth, height: lineHeight)
    }

    static func contentHeight(for theme: MarkdownTheme, detail: String?, maxWidth: CGFloat) -> CGFloat {
        let titleHeight = ceil(theme.fonts.footnote.lineHeight)
        guard let detail, !detail.isEmpty else {
            return titleHeight + 16
        }

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        let detailWidth = max(0, maxWidth - 32)
        let detailHeight = ceil(
            NSAttributedString(
                string: detail,
                attributes: [
                    .font: UIFont.systemFont(ofSize: 11),
                    .paragraphStyle: paragraph,
                ]
            ).boundingRect(
                with: CGSize(width: detailWidth, height: CGFloat.greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                context: nil
            ).height
        )
        return titleHeight + detailHeight + 20
    }
}
