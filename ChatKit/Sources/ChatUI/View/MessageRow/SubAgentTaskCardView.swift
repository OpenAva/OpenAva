import MarkdownView
import UIKit

final class SubAgentTaskCardView: MessageListRowView {
    private enum Layout {
        static let contentInsets = UIEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        static let verticalSpacing: CGFloat = 6
        static let sectionSpacing: CGFloat = 10
        static let badgeHorizontalPadding: CGFloat = 8
        static let badgeVerticalPadding: CGFloat = 4
        static let chevronSize: CGFloat = 14
        static let chevronReserve: CGFloat = 24
    }

    var tapHandler: (() -> Void)?

    private var task: MessageListView.SubAgentTaskRepresentation?

    private let containerView = UIView()
    private let titleLabel = UILabel()
    private let agentLabel = UILabel()
    private let statusBadgeView = UIView()
    private let statusLabel = UILabel()
    private let summaryLabel = UILabel()
    private let previewLabel = UILabel()
    private let statsLabel = UILabel()
    private let activitiesTitleLabel = UILabel()
    private let activitiesLabel = UILabel()
    private let resultTitleLabel = UILabel()
    private let resultLabel = UILabel()
    private let chevronView = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)

        titleLabel.numberOfLines = 0
        agentLabel.numberOfLines = 1
        summaryLabel.numberOfLines = 0
        previewLabel.numberOfLines = 0
        statsLabel.numberOfLines = 0
        activitiesTitleLabel.numberOfLines = 1
        activitiesLabel.numberOfLines = 0
        resultTitleLabel.numberOfLines = 1
        resultLabel.numberOfLines = 0

        chevronView.contentMode = .center
        chevronView.tintColor = .secondaryLabel

        containerView.layer.cornerRadius = ChatUIDesign.Radius.card
        containerView.layer.cornerCurve = .continuous
        containerView.layer.borderWidth = 1

        contentView.addSubview(containerView)
        [
            titleLabel,
            agentLabel,
            statusBadgeView,
            summaryLabel,
            previewLabel,
            statsLabel,
            activitiesTitleLabel,
            activitiesLabel,
            resultTitleLabel,
            resultLabel,
            chevronView,
        ].forEach { containerView.addSubview($0) }
        statusBadgeView.addSubview(statusLabel)

        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        contentView.addGestureRecognizer(tapGesture)

        updateStyle()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        tapHandler = nil
        task = nil
    }

    override func themeDidUpdate() {
        super.themeDidUpdate()
        updateStyle()
    }

    func configure(with task: MessageListView.SubAgentTaskRepresentation) {
        self.task = task
        titleLabel.text = task.taskDescription
        agentLabel.text = "\(Self.formattedAgentType(task.agentType)) agent"
        statusLabel.text = Self.statusText(for: task.status)
        summaryLabel.text = task.summary
        previewLabel.text = Self.previewText(for: task)
        statsLabel.text = Self.statsText(for: task)
        activitiesTitleLabel.text = task.isExpanded && !task.recentActivities.isEmpty ? String.localized("Recent activity") : nil
        activitiesLabel.text = task.isExpanded ? Self.activitiesText(for: task) : nil
        resultTitleLabel.text = task.isExpanded ? Self.resultSectionTitle(for: task) : nil
        resultLabel.text = task.isExpanded ? Self.expandedResultText(for: task) : nil
        chevronView.isHidden = !task.hasExpandedContent
        let symbolConfig = UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        chevronView.image = UIImage(systemName: "chevron.right", withConfiguration: symbolConfig)
        chevronView.transform = task.isExpanded ? .init(rotationAngle: .pi / 2) : .identity

        for item in [previewLabel, statsLabel, activitiesTitleLabel, activitiesLabel, resultTitleLabel, resultLabel] {
            item.isHidden = (item.text?.isEmpty ?? true)
        }

        updateStyle()
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        containerView.frame = contentView.bounds
        let hasChevron = !(chevronView.isHidden)
        let availableWidth = max(
            0,
            containerView.bounds.width - Layout.contentInsets.left - Layout.contentInsets.right - (hasChevron ? Layout.chevronReserve : 0)
        )

        let badgeSize = statusBadgeSize()
        let titleWidth = max(0, availableWidth - badgeSize.width - 8)
        let titleSize = titleLabel.sizeThatFits(CGSize(width: titleWidth, height: CGFloat.greatestFiniteMagnitude))

        var y = Layout.contentInsets.top
        titleLabel.frame = CGRect(
            x: Layout.contentInsets.left,
            y: y,
            width: titleWidth,
            height: ceil(titleSize.height)
        )

        statusBadgeView.frame = CGRect(
            x: containerView.bounds.width - Layout.contentInsets.right - badgeSize.width,
            y: y,
            width: badgeSize.width,
            height: badgeSize.height
        )
        statusLabel.frame = CGRect(
            x: Layout.badgeHorizontalPadding,
            y: Layout.badgeVerticalPadding,
            width: badgeSize.width - Layout.badgeHorizontalPadding * 2,
            height: badgeSize.height - Layout.badgeVerticalPadding * 2
        )
        statusBadgeView.layer.cornerRadius = badgeSize.height / 2

        y += max(titleLabel.frame.height, statusBadgeView.frame.height)

        if let text = agentLabel.text, !text.isEmpty {
            y += Layout.verticalSpacing
            let size = agentLabel.sizeThatFits(CGSize(width: availableWidth, height: CGFloat.greatestFiniteMagnitude))
            agentLabel.frame = CGRect(
                x: Layout.contentInsets.left,
                y: y,
                width: availableWidth,
                height: ceil(size.height)
            )
            y = agentLabel.frame.maxY
        } else {
            agentLabel.frame = .zero
        }

        y = layoutLabel(summaryLabel, atY: y, width: availableWidth)
        y = layoutLabel(previewLabel, atY: y, width: availableWidth)
        y = layoutLabel(statsLabel, atY: y, width: availableWidth)
        y = layoutLabel(activitiesTitleLabel, atY: y, width: availableWidth, sectionSpacing: true)
        y = layoutLabel(activitiesLabel, atY: y, width: availableWidth)
        y = layoutLabel(resultTitleLabel, atY: y, width: availableWidth, sectionSpacing: true)
        y = layoutLabel(resultLabel, atY: y, width: availableWidth)

        if hasChevron {
            chevronView.frame = CGRect(
                x: containerView.bounds.width - Layout.contentInsets.right - Layout.chevronSize,
                y: max(Layout.contentInsets.top, y - Layout.chevronSize),
                width: Layout.chevronSize,
                height: Layout.chevronSize
            )
        } else {
            chevronView.frame = .zero
        }
    }

    static func contentHeight(
        for task: MessageListView.SubAgentTaskRepresentation,
        theme: MarkdownTheme,
        maxWidth: CGFloat
    ) -> CGFloat {
        let hasChevron = task.hasExpandedContent
        let availableWidth = max(
            0,
            maxWidth - Layout.contentInsets.left - Layout.contentInsets.right - (hasChevron ? Layout.chevronReserve : 0)
        )
        let badgeSize = statusBadgeSize(for: task, theme: theme)
        let titleWidth = max(0, availableWidth - badgeSize.width - 8)

        var height = Layout.contentInsets.top + Layout.contentInsets.bottom
        height += textHeight(task.taskDescription, font: theme.fonts.body, width: titleWidth)
        height += max(0, badgeSize.height - textHeight(task.taskDescription, font: theme.fonts.body, width: titleWidth))

        let agentText = "\(formattedAgentType(task.agentType)) agent"
        if !agentText.isEmpty {
            height += Layout.verticalSpacing + textHeight(agentText, font: UIFont.systemFont(ofSize: 12, weight: .medium), width: availableWidth)
        }

        height += stackedTextHeight(task.summary, font: theme.fonts.footnote, width: availableWidth)
        height += stackedTextHeight(previewText(for: task), font: theme.fonts.footnote, width: availableWidth)
        height += stackedTextHeight(statsText(for: task), font: UIFont.systemFont(ofSize: 12), width: availableWidth)

        if task.isExpanded {
            let activities = activitiesText(for: task)
            if let activities, !activities.isEmpty {
                height += Layout.sectionSpacing + textHeight(String.localized("Recent activity"), font: UIFont.systemFont(ofSize: 12, weight: .semibold), width: availableWidth)
                height += Layout.verticalSpacing + textHeight(activities, font: theme.fonts.footnote, width: availableWidth)
            }

            let resultTitle = resultSectionTitle(for: task)
            let resultText = expandedResultText(for: task)
            if let resultTitle, !resultTitle.isEmpty, let resultText, !resultText.isEmpty {
                height += Layout.sectionSpacing + textHeight(resultTitle, font: UIFont.systemFont(ofSize: 12, weight: .semibold), width: availableWidth)
                height += Layout.verticalSpacing + textHeight(resultText, font: theme.fonts.footnote, width: availableWidth)
            }
        }

        return ceil(height)
    }

    private func layoutLabel(_ label: UILabel, atY y: CGFloat, width: CGFloat, sectionSpacing: Bool = false) -> CGFloat {
        guard let text = label.text, !text.isEmpty else {
            label.frame = .zero
            return y
        }

        let spacing = sectionSpacing ? Layout.sectionSpacing : Layout.verticalSpacing
        let nextY = y + spacing
        let size = label.sizeThatFits(CGSize(width: width, height: CGFloat.greatestFiniteMagnitude))
        label.frame = CGRect(
            x: Layout.contentInsets.left,
            y: nextY,
            width: width,
            height: ceil(size.height)
        )
        return label.frame.maxY
    }

    private func updateStyle() {
        guard let task else { return }

        let palette = statusPalette(for: task.status)
        containerView.backgroundColor = palette.fill
        containerView.layer.borderColor = palette.border.cgColor

        titleLabel.font = theme.fonts.body
        titleLabel.textColor = theme.colors.body

        agentLabel.font = UIFont.systemFont(ofSize: 12, weight: .medium)
        agentLabel.textColor = theme.colors.body.withAlphaComponent(0.72)

        statusBadgeView.backgroundColor = palette.badge
        statusLabel.font = UIFont.systemFont(ofSize: 12, weight: .semibold)
        statusLabel.textColor = palette.foreground
        statusLabel.textAlignment = .center

        summaryLabel.font = theme.fonts.footnote
        summaryLabel.textColor = theme.colors.body

        previewLabel.font = theme.fonts.footnote
        previewLabel.textColor = theme.colors.body.withAlphaComponent(0.74)

        statsLabel.font = UIFont.systemFont(ofSize: 12)
        statsLabel.textColor = theme.colors.body.withAlphaComponent(0.56)

        activitiesTitleLabel.font = UIFont.systemFont(ofSize: 12, weight: .semibold)
        activitiesTitleLabel.textColor = theme.colors.body.withAlphaComponent(0.82)
        activitiesLabel.font = theme.fonts.footnote
        activitiesLabel.textColor = theme.colors.body.withAlphaComponent(0.74)

        resultTitleLabel.font = UIFont.systemFont(ofSize: 12, weight: .semibold)
        resultTitleLabel.textColor = theme.colors.body.withAlphaComponent(0.82)
        resultLabel.font = theme.fonts.footnote
        resultLabel.textColor = theme.colors.body.withAlphaComponent(0.74)
    }

    private func statusBadgeSize() -> CGSize {
        guard let task else { return .zero }
        return Self.statusBadgeSize(for: task, theme: theme)
    }

    private static func statusBadgeSize(for task: MessageListView.SubAgentTaskRepresentation, theme _: MarkdownTheme) -> CGSize {
        let label = UILabel()
        label.font = UIFont.systemFont(ofSize: 12, weight: .semibold)
        label.text = statusText(for: task.status)
        let size = label.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        return CGSize(
            width: ceil(size.width) + Layout.badgeHorizontalPadding * 2,
            height: ceil(size.height) + Layout.badgeVerticalPadding * 2
        )
    }

    private static func previewText(for task: MessageListView.SubAgentTaskRepresentation) -> String? {
        let preview = (task.errorDescription ?? task.resultPreview)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let preview, !preview.isEmpty else { return nil }
        guard preview != task.summary?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        return preview
    }

    private static func activitiesText(for task: MessageListView.SubAgentTaskRepresentation) -> String? {
        guard !task.recentActivities.isEmpty else { return nil }
        return task.recentActivities.map { "• \($0)" }.joined(separator: "\n")
    }

    private static func expandedResultText(for task: MessageListView.SubAgentTaskRepresentation) -> String? {
        if let error = task.errorDescription?.trimmingCharacters(in: .whitespacesAndNewlines), !error.isEmpty {
            return error
        }
        guard let fullResult = task.fullResult?.trimmingCharacters(in: .whitespacesAndNewlines), !fullResult.isEmpty else {
            return nil
        }
        return fullResult
    }

    private static func resultSectionTitle(for task: MessageListView.SubAgentTaskRepresentation) -> String? {
        if let error = task.errorDescription?.trimmingCharacters(in: .whitespacesAndNewlines), !error.isEmpty {
            return String.localized("Error")
        }
        guard let fullResult = task.fullResult?.trimmingCharacters(in: .whitespacesAndNewlines), !fullResult.isEmpty else {
            return nil
        }
        return String.localized("Result")
    }

    private static func statsText(for task: MessageListView.SubAgentTaskRepresentation) -> String? {
        var parts: [String] = []
        if let totalTurns = task.totalTurns, totalTurns > 0 {
            parts.append("\(totalTurns) turns")
        }
        if let totalToolCalls = task.totalToolCalls, totalToolCalls > 0 {
            parts.append("\(totalToolCalls) tools")
        }
        if let durationMs = task.durationMs, durationMs > 0 {
            parts.append(formattedDuration(durationMs))
        }
        return parts.isEmpty ? nil : parts.joined(separator: "  ·  ")
    }

    private static func formattedDuration(_ durationMs: Int) -> String {
        if durationMs < 1000 {
            return "\(durationMs) ms"
        }
        let totalSeconds = Double(durationMs) / 1000
        if totalSeconds < 60 {
            let rounded = (totalSeconds * 10).rounded() / 10
            return rounded.rounded() == rounded ? "\(Int(rounded)) s" : "\(rounded) s"
        }
        let minutes = Int(totalSeconds) / 60
        let seconds = Int(totalSeconds) % 60
        return "\(minutes)m \(seconds)s"
    }

    private static func formattedAgentType(_ value: String) -> String {
        value
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
            .joined(separator: " ")
    }

    private static func statusText(for status: String) -> String {
        switch status {
        case "running":
            return String.localized("Running")
        case "waiting":
            return String.localized("Waiting")
        case "completed":
            return String.localized("Completed")
        case "failed":
            return String.localized("Failed")
        case "cancelled":
            return String.localized("Cancelled")
        default:
            return status.capitalized
        }
    }

    private func statusPalette(for status: String) -> (fill: UIColor, border: UIColor, badge: UIColor, foreground: UIColor) {
        switch status {
        case "waiting":
            return (
                UIColor.systemTeal.withAlphaComponent(0.08),
                UIColor.systemTeal.withAlphaComponent(0.16),
                UIColor.systemTeal.withAlphaComponent(0.12),
                .systemTeal
            )
        case "completed":
            return (
                UIColor.systemGreen.withAlphaComponent(0.08),
                UIColor.systemGreen.withAlphaComponent(0.16),
                UIColor.systemGreen.withAlphaComponent(0.12),
                .systemGreen
            )
        case "failed":
            return (
                UIColor.systemRed.withAlphaComponent(0.08),
                UIColor.systemRed.withAlphaComponent(0.16),
                UIColor.systemRed.withAlphaComponent(0.12),
                .systemRed
            )
        case "cancelled":
            return (
                UIColor.systemOrange.withAlphaComponent(0.08),
                UIColor.systemOrange.withAlphaComponent(0.16),
                UIColor.systemOrange.withAlphaComponent(0.12),
                .systemOrange
            )
        default:
            return (
                UIColor.systemBlue.withAlphaComponent(0.08),
                UIColor.systemBlue.withAlphaComponent(0.16),
                UIColor.systemBlue.withAlphaComponent(0.12),
                .systemBlue
            )
        }
    }

    private static func stackedTextHeight(_ text: String?, font: UIFont, width: CGFloat) -> CGFloat {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return 0
        }
        return Layout.verticalSpacing + textHeight(text, font: font, width: width)
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

    @objc
    private func handleTap() {
        guard task?.hasExpandedContent == true else { return }
        tapHandler?()
    }
}
