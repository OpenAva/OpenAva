//
//  ToolResultContentView.swift
//  ChatUI
//
//  Displays expanded tool result content styled to match ReasoningContentView:
//  left indicator bar + footnote-sized secondary-label text.
//

import MarkdownView
import UIKit

final class ToolResultContentView: MessageListRowView {
    private lazy var indicator: UIView = .init()
    private lazy var scrollView: ToolResultScrollView = .init().with {
        $0.showsVerticalScrollIndicator = true
        $0.showsHorizontalScrollIndicator = false
        $0.alwaysBounceVertical = false
        $0.delaysContentTouches = false
        $0.canCancelContentTouches = true
        $0.isDirectionalLockEnabled = true
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

        var copySections: [(String, String)] = []

        if representation.hasParameters {
            let section = SectionView(title: String.localized("Tool Arguments"), content: representation.formattedParameters, theme: theme)
            scrollView.addSubview(section)
            sectionViews.append(section)
            copySections.append((String.localized("Tool Arguments"), representation.formattedParameters))
        }
        if representation.hasResult {
            let section = SectionView(title: String.localized("Tool Result"), content: representation.formattedResult, theme: theme)
            scrollView.addSubview(section)
            sectionViews.append(section)
            copySections.append((String.localized("Tool Result"), representation.formattedResult))
        }

        contextMenuProvider = copySections.isEmpty ? nil : { _ in
            let actions = copySections.map { title, content in
                UIAction(title: String.localized("Copy \(title)"), image: UIImage(systemName: "doc.on.doc")) { _ in
                    UIPasteboard.general.string = content
                }
            }
            return UIMenu(children: actions)
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

private final class ToolResultScrollView: UIScrollView, UIGestureRecognizerDelegate {
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === panGestureRecognizer,
              let panGesture = gestureRecognizer as? UIPanGestureRecognizer
        else {
            return super.gestureRecognizerShouldBegin(gestureRecognizer)
        }

        let maxOffsetY = max(0, contentSize.height - bounds.height)
        guard maxOffsetY > 1 else { return false }

        let velocity = panGesture.velocity(in: self)
        guard abs(velocity.y) > abs(velocity.x) else { return false }

        let offsetY = contentOffset.y
        let isAtTop = offsetY <= 0.5
        let isAtBottom = offsetY >= maxOffsetY - 0.5

        if isAtTop, velocity.y > 0 {
            return false
        }
        if isAtBottom, velocity.y < 0 {
            return false
        }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }
}

private class SectionView: UIView {
    private struct TextMetricsCache {
        let width: CGFloat
        let titleSize: CGSize
        let codeHeight: CGFloat
    }

    let titleLabel = UILabel()
    let codeContainer = UIView()
    let codeLabel = LTXLabel()
    let theme: MarkdownTheme
    let content: String
    private var metricsCache: TextMetricsCache?

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
        let metrics = textMetrics(for: width)

        let containerHeight = metrics.codeHeight + 16 // 8pt padding top/bottom

        return metrics.titleSize.height + 8 + containerHeight
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = bounds.width
        let metrics = textMetrics(for: width)
        let titleSize = metrics.titleSize
        titleLabel.frame = CGRect(x: 0, y: 0, width: width, height: titleSize.height)

        let codeWidth = max(0, width - 16)
        let codeHeight = metrics.codeHeight

        let containerHeight = codeHeight + 16 // 8pt padding top/bottom
        codeContainer.frame = CGRect(x: 0, y: titleLabel.frame.maxY + 8, width: width, height: containerHeight)

        codeLabel.preferredMaxLayoutWidth = codeWidth
        codeLabel.frame = CGRect(x: 8, y: 8, width: codeWidth, height: codeHeight)
    }

    private func textMetrics(for width: CGFloat) -> TextMetricsCache {
        if let metricsCache, abs(metricsCache.width - width) < 0.5 {
            return metricsCache
        }

        let titleSize = titleLabel.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        let codeWidth = max(0, width - 16)
        let codeHeight: CGFloat

        if content.count > 5000 {
            let font = theme.fonts.code
            let charWidth = font.pointSize * 0.6 // approximate width of monospaced character
            let charsPerLine = max(1, Int(codeWidth / charWidth))
            let lineHeight = font.lineHeight + 4 // paragraph style line spacing

            var totalLines = 0
            content.enumerateLines { line, _ in
                let lineLength = max(1, line.count)
                totalLines += Int(ceil(Double(lineLength) / Double(charsPerLine)))
            }
            codeHeight = ceil(CGFloat(totalLines) * lineHeight)
        } else {
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.lineSpacing = 4
            paragraphStyle.lineBreakMode = .byCharWrapping
            let codeString = NSAttributedString(string: content, attributes: [
                .font: theme.fonts.code,
                .paragraphStyle: paragraphStyle,
            ])
            let codeRect = codeString.boundingRect(
                with: CGSize(width: codeWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                context: nil
            )
            codeHeight = ceil(codeRect.height)
        }

        let metrics = TextMetricsCache(width: width, titleSize: titleSize, codeHeight: codeHeight)
        metricsCache = metrics
        return metrics
    }
}
