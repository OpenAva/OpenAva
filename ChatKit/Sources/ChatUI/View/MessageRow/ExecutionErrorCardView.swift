//
//  ExecutionErrorCardView.swift
//  ChatUI
//
//  Dedicated transient execution error presentation for failed model requests.
//

import MarkdownView
import UIKit

final class ExecutionErrorCardView: MessageListRowView {
    private enum Layout {
        static let contentInsets = UIEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        static let iconSize: CGFloat = 22
        static let iconSpacing: CGFloat = 10
        static let titleMessageSpacing: CGFloat = 5
        static let detailsSpacing: CGFloat = 8
        static let detailsVerticalPadding: CGFloat = 4
        static let detailsHorizontalPadding: CGFloat = 8
    }

    private let containerView = UIView()
    private let iconBackgroundView = UIView()
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let messageLabel = UILabel()
    private let detailsHintLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)

        containerView.layer.cornerRadius = ChatUIDesign.Radius.card
        containerView.layer.cornerCurve = .continuous
        containerView.layer.borderWidth = 1

        iconBackgroundView.layer.cornerCurve = .continuous
        iconView.image = UIImage(systemName: "exclamationmark.triangle.fill")
        iconView.contentMode = .scaleAspectFit

        titleLabel.numberOfLines = 0
        messageLabel.numberOfLines = 0
        detailsHintLabel.numberOfLines = 1
        detailsHintLabel.textAlignment = .center
        detailsHintLabel.layer.cornerCurve = .continuous
        detailsHintLabel.clipsToBounds = true

        contentView.addSubview(containerView)
        [iconBackgroundView, titleLabel, messageLabel, detailsHintLabel].forEach { containerView.addSubview($0) }
        iconBackgroundView.addSubview(iconView)

        updateStyle()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func themeDidUpdate() {
        super.themeDidUpdate()
        updateStyle()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        titleLabel.text = nil
        messageLabel.text = nil
        detailsHintLabel.text = nil
        detailsHintLabel.isHidden = true
    }

    func configure(with error: MessageListView.ExecutionErrorRepresentation) {
        titleLabel.text = error.title
        messageLabel.text = error.message

        let details = error.details?.trimmingCharacters(in: .whitespacesAndNewlines)
        if details?.isEmpty == false {
            detailsHintLabel.text = String.localized("Technical details available")
            detailsHintLabel.isHidden = false
        } else {
            detailsHintLabel.text = nil
            detailsHintLabel.isHidden = true
        }

        let copyMessage = error.message
        contextMenuProvider = { _ in
            var actions: [UIAction] = [
                UIAction(title: String.localized("Copy"), image: UIImage(systemName: "doc.on.doc")) { _ in
                    UIPasteboard.general.string = copyMessage
                },
            ]

            if let details, !details.isEmpty {
                actions.append(
                    UIAction(title: String.localized("Copy Details"), image: UIImage(systemName: "ladybug")) { _ in
                        UIPasteboard.general.string = details
                    }
                )
            }

            return UIMenu(children: actions)
        }

        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        containerView.frame = contentView.bounds
        let bounds = containerView.bounds
        let contentWidth = max(0, bounds.width - Layout.contentInsets.horizontal)
        let textX = Layout.contentInsets.left + Layout.iconSize + Layout.iconSpacing
        let textWidth = max(0, bounds.width - textX - Layout.contentInsets.right)

        iconBackgroundView.frame = CGRect(
            x: Layout.contentInsets.left,
            y: Layout.contentInsets.top,
            width: Layout.iconSize,
            height: Layout.iconSize
        )
        iconBackgroundView.layer.cornerRadius = Layout.iconSize / 2
        iconView.frame = iconBackgroundView.bounds.insetBy(dx: 4, dy: 4)

        var y = Layout.contentInsets.top
        let titleHeight = Self.textHeight(titleLabel.text, font: titleLabel.font, width: textWidth)
        titleLabel.frame = CGRect(x: textX, y: y, width: textWidth, height: titleHeight)
        y = max(titleLabel.frame.maxY, iconBackgroundView.frame.maxY)

        if let text = messageLabel.text, !text.isEmpty {
            y += Layout.titleMessageSpacing
            let messageHeight = Self.textHeight(text, font: messageLabel.font, width: textWidth)
            messageLabel.frame = CGRect(x: textX, y: y, width: textWidth, height: messageHeight)
            y = messageLabel.frame.maxY
        } else {
            messageLabel.frame = .zero
        }

        if let text = detailsHintLabel.text, !text.isEmpty, !detailsHintLabel.isHidden {
            y += Layout.detailsSpacing
            let detailSize = detailsHintLabel.sizeThatFits(CGSize(width: contentWidth, height: CGFloat.greatestFiniteMagnitude))
            let detailWidth = min(
                contentWidth,
                ceil(detailSize.width) + Layout.detailsHorizontalPadding * 2
            )
            let detailHeight = ceil(detailSize.height) + Layout.detailsVerticalPadding * 2
            detailsHintLabel.frame = CGRect(
                x: textX,
                y: y,
                width: detailWidth,
                height: detailHeight
            )
            detailsHintLabel.layer.cornerRadius = detailHeight / 2
        } else {
            detailsHintLabel.frame = .zero
        }
    }

    static func contentHeight(
        for error: MessageListView.ExecutionErrorRepresentation,
        theme: MarkdownTheme,
        maxWidth: CGFloat
    ) -> CGFloat {
        let textWidth = max(
            0,
            maxWidth - Layout.contentInsets.horizontal - Layout.iconSize - Layout.iconSpacing
        )

        let titleHeight = textHeight(error.title, font: theme.fonts.body.bold, width: textWidth)
        var height = Layout.contentInsets.top + max(Layout.iconSize, titleHeight)

        let message = error.message.trimmingCharacters(in: .whitespacesAndNewlines)
        if !message.isEmpty {
            height += Layout.titleMessageSpacing
            height += textHeight(message, font: theme.fonts.footnote, width: textWidth)
        }

        let details = error.details?.trimmingCharacters(in: .whitespacesAndNewlines)
        if details?.isEmpty == false {
            height += Layout.detailsSpacing
            height += ceil(UIFont.systemFont(ofSize: 12, weight: .medium).lineHeight) + Layout.detailsVerticalPadding * 2
        }

        height += Layout.contentInsets.bottom
        return ceil(height)
    }

    private func updateStyle() {
        containerView.backgroundColor = UIColor.systemRed.withAlphaComponent(0.07)
        containerView.layer.borderColor = UIColor.systemRed.withAlphaComponent(0.18).cgColor

        iconBackgroundView.backgroundColor = UIColor.systemRed.withAlphaComponent(0.12)
        iconView.tintColor = .systemRed

        titleLabel.font = theme.fonts.body.bold
        titleLabel.textColor = theme.colors.body
        messageLabel.font = theme.fonts.footnote
        messageLabel.textColor = theme.colors.body.withAlphaComponent(0.78)
        detailsHintLabel.font = UIFont.systemFont(ofSize: 12, weight: .medium)
        detailsHintLabel.textColor = .systemRed
        detailsHintLabel.backgroundColor = UIColor.systemRed.withAlphaComponent(0.08)
    }

    private static func textHeight(_ text: String?, font: UIFont, width: CGFloat) -> CGFloat {
        guard let text, !text.isEmpty, width > 0 else { return 0 }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        return ceil(
            NSAttributedString(
                string: text,
                attributes: [
                    .font: font,
                    .paragraphStyle: paragraph,
                ]
            ).boundingRect(
                with: CGSize(width: width, height: CGFloat.greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                context: nil
            ).height
        )
    }
}
