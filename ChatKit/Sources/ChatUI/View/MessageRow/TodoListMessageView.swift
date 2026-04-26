import MarkdownView
import UIKit

private enum TodoListLayout {
    static let contentInsets = UIEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
    static let verticalSpacing: CGFloat = 10
    static let itemSpacing: CGFloat = 8
    static let markerSize: CGFloat = 20
    static let markerTextSpacing: CGFloat = 10
}

final class TodoListMessageView: MessageListRowView {
    private let containerView = UIView()
    private let titleLabel = UILabel()
    private let updatedAtLabel = UILabel()

    private var itemViews: [ItemRowView] = []
    private var metadata: TodoListMetadata?

    override init(frame: CGRect) {
        super.init(frame: frame)

        containerView.layer.cornerRadius = ChatUIDesign.Radius.card
        containerView.layer.cornerCurve = .continuous
        containerView.layer.borderWidth = 1

        titleLabel.numberOfLines = 1
        updatedAtLabel.numberOfLines = 1
        updatedAtLabel.textAlignment = .right

        contentView.addSubview(containerView)
        containerView.addSubview(titleLabel)
        containerView.addSubview(updatedAtLabel)

        updateStyle()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        metadata = nil
        for view in itemViews {
            view.removeFromSuperview()
        }
        itemViews.removeAll()
    }

    override func themeDidUpdate() {
        super.themeDidUpdate()
        updateStyle()
        itemViews.forEach { $0.theme = theme }
    }

    func configure(with metadata: TodoListMetadata) {
        self.metadata = metadata
        titleLabel.text = String.localized("Session todo list")
        updatedAtLabel.text = formattedUpdatedAt(metadata.updatedAt)
        updatedAtLabel.isHidden = updatedAtLabel.text?.isEmpty ?? true

        if itemViews.count != metadata.items.count {
            for view in itemViews {
                view.removeFromSuperview()
            }
            itemViews = metadata.items.map { _ in
                let view = ItemRowView()
                view.theme = theme
                containerView.addSubview(view)
                return view
            }
        }

        for (view, item) in zip(itemViews, metadata.items) {
            view.theme = theme
            view.configure(with: item)
        }

        updateStyle()
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        containerView.frame = contentView.bounds
        let bounds = containerView.bounds
        let contentWidth = max(0, bounds.width - TodoListLayout.contentInsets.left - TodoListLayout.contentInsets.right)

        var y = TodoListLayout.contentInsets.top

        let updatedAtWidth = updatedAtLabel.isHidden ? 0 : min(contentWidth * 0.42, 180)
        let titleWidth = max(0, contentWidth - updatedAtWidth - (updatedAtWidth > 0 ? 8 : 0))
        let titleSize = titleLabel.sizeThatFits(CGSize(width: titleWidth, height: .greatestFiniteMagnitude))
        titleLabel.frame = CGRect(
            x: TodoListLayout.contentInsets.left,
            y: y,
            width: titleWidth,
            height: ceil(titleSize.height)
        )

        if updatedAtWidth > 0 {
            let updatedAtSize = updatedAtLabel.sizeThatFits(CGSize(width: updatedAtWidth, height: .greatestFiniteMagnitude))
            updatedAtLabel.frame = CGRect(
                x: bounds.width - TodoListLayout.contentInsets.right - updatedAtWidth,
                y: y,
                width: updatedAtWidth,
                height: ceil(updatedAtSize.height)
            )
        } else {
            updatedAtLabel.frame = .zero
        }

        y += max(titleLabel.frame.height, updatedAtLabel.frame.height)

        for (index, view) in itemViews.enumerated() {
            y += index == 0 ? TodoListLayout.verticalSpacing : TodoListLayout.itemSpacing
            let height = view.contentHeight(for: contentWidth)
            view.frame = CGRect(
                x: TodoListLayout.contentInsets.left,
                y: y,
                width: contentWidth,
                height: height
            )
            y = view.frame.maxY
        }
    }

    static func contentHeight(for metadata: TodoListMetadata, theme: MarkdownTheme, maxWidth: CGFloat) -> CGFloat {
        let contentWidth = max(0, maxWidth - TodoListLayout.contentInsets.left - TodoListLayout.contentInsets.right)
        let titleHeight = ceil(theme.fonts.body.lineHeight)
        let updatedAtHeight = metadata.updatedAt.flatMap { _ in UIFont.systemFont(ofSize: 11).lineHeight } ?? 0
        var height = TodoListLayout.contentInsets.top + TodoListLayout.contentInsets.bottom + max(titleHeight, ceil(updatedAtHeight))

        for (index, item) in metadata.items.enumerated() {
            height += index == 0 ? TodoListLayout.verticalSpacing : TodoListLayout.itemSpacing
            height += ItemRowView.contentHeight(for: item, theme: theme, width: contentWidth)
        }

        return ceil(height)
    }

    private func updateStyle() {
        containerView.backgroundColor = UIColor.secondarySystemBackground
        containerView.layer.borderColor = UIColor.separator.withAlphaComponent(0.2).cgColor

        titleLabel.font = theme.fonts.body
        titleLabel.textColor = theme.colors.body

        updatedAtLabel.font = UIFont.systemFont(ofSize: 11)
        updatedAtLabel.textColor = theme.colors.body.withAlphaComponent(0.52)
    }

    private func formattedUpdatedAt(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        guard let date = iso8601WithFractionalSeconds.date(from: value) ?? ISO8601DateFormatter().date(from: value) else {
            return value
        }
        return relativeDateFormatter.localizedString(for: date, relativeTo: Date())
    }

    private static let iso8601WithFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private let iso8601WithFractionalSeconds = TodoListMessageView.iso8601WithFractionalSeconds

    private let relativeDateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()
}

private final class ItemRowView: UIView {
    var theme: MarkdownTheme = .default {
        didSet {
            updateStyle()
            setNeedsLayout()
        }
    }

    private let markerLabel = UILabel()
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let markerBackgroundView = UIView()

    private var item: TodoListMetadata.Item?

    override init(frame: CGRect) {
        super.init(frame: frame)

        markerLabel.textAlignment = .center
        markerLabel.numberOfLines = 1

        titleLabel.numberOfLines = 0
        detailLabel.numberOfLines = 0

        addSubview(markerBackgroundView)
        markerBackgroundView.addSubview(markerLabel)
        addSubview(titleLabel)
        addSubview(detailLabel)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(with item: TodoListMetadata.Item) {
        self.item = item
        titleLabel.text = item.content
        detailLabel.text = item.status == "in_progress" ? item.activeForm : nil
        detailLabel.isHidden = detailLabel.text?.isEmpty ?? true
        markerLabel.text = markerText(for: item.status)
        updateStyle()
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = bounds.width
        let textX = TodoListLayout.markerSize + TodoListLayout.markerTextSpacing
        let textWidth = max(0, width - textX)

        markerBackgroundView.frame = CGRect(x: 0, y: 0, width: TodoListLayout.markerSize, height: TodoListLayout.markerSize)
        markerBackgroundView.layer.cornerRadius = TodoListLayout.markerSize / 2
        markerLabel.frame = markerBackgroundView.bounds

        let titleSize = titleLabel.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude))
        titleLabel.frame = CGRect(x: textX, y: 0, width: textWidth, height: ceil(titleSize.height))

        if detailLabel.isHidden {
            detailLabel.frame = .zero
        } else {
            let detailSize = detailLabel.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude))
            detailLabel.frame = CGRect(
                x: textX,
                y: titleLabel.frame.maxY + 3,
                width: textWidth,
                height: ceil(detailSize.height)
            )
        }
    }

    func contentHeight(for width: CGFloat) -> CGFloat {
        guard let item else { return 0 }
        return Self.contentHeight(for: item, theme: theme, width: width)
    }

    static func contentHeight(for item: TodoListMetadata.Item, theme: MarkdownTheme, width: CGFloat) -> CGFloat {
        let textX = TodoListLayout.markerSize + TodoListLayout.markerTextSpacing
        let textWidth = max(0, width - textX)
        let titleHeight = textHeight(item.content, font: theme.fonts.body, width: textWidth)
        let detailHeight: CGFloat
        if item.status == "in_progress", !item.activeForm.isEmpty {
            detailHeight = 3 + textHeight(item.activeForm, font: theme.fonts.footnote, width: textWidth)
        } else {
            detailHeight = 0
        }
        return ceil(max(TodoListLayout.markerSize, titleHeight + detailHeight))
    }

    private func updateStyle() {
        guard let item else { return }
        let palette = palette(for: item.status)

        markerBackgroundView.backgroundColor = palette.markerBackground
        titleLabel.font = theme.fonts.body
        titleLabel.textColor = palette.titleColor
        detailLabel.font = theme.fonts.footnote
        detailLabel.textColor = theme.colors.body.withAlphaComponent(0.62)
        markerLabel.font = UIFont.systemFont(ofSize: 12, weight: .semibold)
        markerLabel.textColor = palette.markerForeground
    }

    private func markerText(for status: String) -> String {
        switch status {
        case "completed":
            return "✓"
        case "in_progress":
            return "…"
        default:
            return "○"
        }
    }

    private func palette(for status: String) -> (markerBackground: UIColor, markerForeground: UIColor, titleColor: UIColor) {
        switch status {
        case "completed":
            return (
                UIColor.systemGreen.withAlphaComponent(0.14),
                .systemGreen,
                theme.colors.body.withAlphaComponent(0.72)
            )
        case "in_progress":
            return (
                UIColor.systemBlue.withAlphaComponent(0.14),
                .systemBlue,
                theme.colors.body
            )
        default:
            return (
                UIColor.tertiarySystemFill,
                theme.colors.body.withAlphaComponent(0.58),
                theme.colors.body.withAlphaComponent(0.76)
            )
        }
    }

    private static func textHeight(_ text: String, font: UIFont, width: CGFloat) -> CGFloat {
        guard width > 0 else { return 0 }
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
