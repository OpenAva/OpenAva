//
//  Created by ktiays on 2025/2/21.
//  Copyright (c) 2025 ktiays. All rights reserved.
//

import GlyphixTextFx
import Litext
import UIKit

final class ReasoningContentView: MessageListRowView {
    private lazy var indicator: UIView = .init()
    private lazy var textContainer: UIView = .init().with {
        $0.backgroundColor = .secondarySystemFill.withAlphaComponent(0.08)
        $0.layer.cornerRadius = 8
        $0.layer.cornerCurve = .continuous
    }

    private lazy var textView: LTXLabel = .init().with {
        $0.isSelectable = true
        $0.backgroundColor = .clear
    }

    private lazy var thinkingTile: ThinkingTile = .init()

    static let paragraphStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 4
        style.lineBreakMode = .byCharWrapping
        return style
    }()

    static let revealedTileHeight: CGFloat = 28
    static let unrevealedTileHeight: CGFloat = 28
    static let spacing: CGFloat = 8
    private static let tileContentLeading: CGFloat = 8
    private static let indicatorWidth: CGFloat = 1

    var thinkingDuration: TimeInterval = 0 {
        didSet {
            thinkingTile.thinkingDuration = thinkingDuration
        }
    }

    var thinkingTileTapHandler: ((_ newValue: Bool) -> Void)?

    var isRevealed: Bool = false {
        didSet {
            thinkingTile.isRevealed = isRevealed
            setNeedsLayout()
            layoutIfNeeded()
        }
    }

    var isThinking: Bool = false {
        didSet {
            thinkingTile.isThinking = isThinking
            setNeedsLayout()
            layoutIfNeeded()
        }
    }

    var text: String? {
        didSet {
            if let text {
                textView.attributedText = .init(string: text, attributes: [
                    .font: theme.fonts.code,
                    .foregroundColor: theme.colors.code,
                    .paragraphStyle: Self.paragraphStyle,
                ])
            } else {
                textView.attributedText = .init()
            }
            setNeedsLayout()
        }
    }

    override init(frame: CGRect) {
        var decisionFrame = frame
        if decisionFrame == .zero {
            // prevent unwanted animation with magic
            decisionFrame = .init(x: 0, y: 0, width: 512, height: 10)
        }
        super.init(frame: decisionFrame)

        contentView.clipsToBounds = false

        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleThinkTileTap(_:)))
        thinkingTile.addGestureRecognizer(tapGesture)
        contentView.addSubview(thinkingTile)

        indicator.layer.cornerRadius = 0.5
        indicator.backgroundColor = .tertiaryLabel
        indicator.alpha = 1.0
        contentView.addSubview(indicator)

        contentView.addSubview(textContainer)
        textContainer.addSubview(textView)
    }

    @available(*, unavailable)
    @MainActor required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func themeDidUpdate() {
        super.themeDidUpdate()
        thinkingTile.titleLabel.font = UIFont.systemFont(ofSize: theme.fonts.body.pointSize, weight: .regular)
        textView.selectionBackgroundColor = theme.colors.selectionBackground
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        thinkingTile.frame = .init(
            x: 0,
            y: 0,
            width: thinkingTile.intrinsicContentSize.width,
            height: isRevealed ? Self.revealedTileHeight : Self.unrevealedTileHeight
        )

        let contentLeading = thinkingTile.frame.minX + Self.tileContentLeading + 14
        let indicatorLeading = thinkingTile.frame.minX + 6.5
        let indicatorY = thinkingTile.frame.maxY + Self.spacing
        if isRevealed {
            indicator.isHidden = false
            indicator.frame = .init(
                x: indicatorLeading,
                y: indicatorY,
                width: Self.indicatorWidth,
                height: max(0, contentView.bounds.height - indicatorY)
            )
        } else {
            indicator.isHidden = true
            indicator.frame = .zero
        }

        let containerOrigin = CGPoint(
            x: contentLeading,
            y: indicatorY
        )
        let containerWidth = max(0, contentView.bounds.width - containerOrigin.x)
        let textWidth = max(0, containerWidth - 16)

        textView.preferredMaxLayoutWidth = textWidth

        let codeHeight: CGFloat
        if let text = text, text.count > 5000 {
            let font = theme.fonts.code
            let charWidth = font.pointSize * 0.6
            let charsPerLine = max(1, Int(textWidth / charWidth))
            let lineHeight = font.lineHeight + 4
            var totalLines = 0
            text.enumerateLines { line, _ in
                let lineLength = max(1, line.count)
                totalLines += Int(ceil(Double(lineLength) / Double(charsPerLine)))
            }
            codeHeight = ceil(CGFloat(totalLines) * lineHeight)
        } else {
            codeHeight = ceil(textView.intrinsicContentSize.height)
        }

        let containerHeight = codeHeight + 16

        textContainer.frame = .init(
            x: containerOrigin.x,
            y: containerOrigin.y,
            width: containerWidth,
            height: containerHeight
        )

        textView.frame = .init(
            x: 8,
            y: 8,
            width: textWidth,
            height: codeHeight
        )

        textContainer.alpha = isRevealed ? 1 : 0
    }

    @objc
    private func handleThinkTileTap(_: UITapGestureRecognizer) {
        thinkingTileTapHandler?(!isRevealed)
    }
}

extension ReasoningContentView {
    final class ThinkingTile: UIView {
        // Keep arrow size stable across collapsed/revealed states.
        private static let arrowSymbolPointSize: CGFloat = 11
        private static let arrowSymbolWeight: UIImage.SymbolWeight = .semibold
        private static let arrowFrameSize: CGFloat = 14

        var thinkingDuration: TimeInterval = 0 {
            didSet {
                updateThinkingDurationText()
            }
        }

        var isRevealed: Bool = false {
            didSet {
                setNeedsLayout()
            }
        }

        var isThinking: Bool = true {
            didSet {
                loadingSymbol.isHidden = !isThinking
                setNeedsLayout()
            }
        }

        lazy var titleLabel: UILabel = .init().with {
            $0.font = UIFont.systemFont(ofSize: UIFont.preferredFont(forTextStyle: .body).pointSize, weight: .regular)
        }

        private lazy var symbolView: UIImageView = .init(image: UIImage(systemName: "sparkles")).with {
            $0.contentMode = .scaleAspectFit
            $0.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
                pointSize: 14,
                weight: .medium
            )
            $0.tintColor = .label
        }

        private lazy var loadingSymbol: LoadingSymbol = .init()
        private lazy var arrowView: UIImageView = .init().with {
            $0.contentMode = .center
            $0.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
                pointSize: Self.arrowSymbolPointSize,
                weight: Self.arrowSymbolWeight
            )
            $0.image = UIImage(systemName: "chevron.right")
        }

        override init(frame: CGRect) {
            super.init(frame: frame)

            addSubview(symbolView)

            titleLabel.textAlignment = .left
            titleLabel.textColor = .label
            addSubview(titleLabel)

            loadingSymbol.dotRadius = 1
            loadingSymbol.spacing = 2
            loadingSymbol.animationDuration = 0.9
            loadingSymbol.animationInterval = 0.24
            addSubview(loadingSymbol)

            arrowView.tintColor = .tertiaryLabel
            addSubview(arrowView)

            updateThinkingDurationText()
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func layoutSubviews() {
            super.layoutSubviews()

            let symbolSize: CGFloat = 14
            symbolView.frame = .init(
                x: 0,
                y: (bounds.height - symbolSize) / 2,
                width: symbolSize,
                height: symbolSize
            )

            let titleSize = titleLabel.intrinsicContentSize
            titleLabel.frame = .init(
                x: symbolView.frame.maxX + 6,
                y: (bounds.height - ceil(titleSize.height)) / 2,
                width: ceil(titleSize.width),
                height: ceil(titleSize.height)
            )
            loadingSymbol.frame = .init(
                x: titleLabel.frame.maxX + 4,
                y: titleLabel.frame.midY - 4.5,
                width: loadingSymbol.intrinsicContentSize.width,
                height: 9
            )

            let arrowSize = CGSize(width: Self.arrowFrameSize, height: Self.arrowFrameSize)
            let arrowAnchorX: CGFloat = {
                if isThinking {
                    return loadingSymbol.frame.maxX + 6
                }
                return titleLabel.frame.maxX + 4
            }()
            arrowView.frame = .init(
                x: arrowAnchorX,
                y: (bounds.height - arrowSize.height) / 2,
                width: arrowSize.width,
                height: arrowSize.height
            )

            if isRevealed {
                arrowView.transform = .init(rotationAngle: .pi / 2)
            } else {
                arrowView.transform = .identity
            }
        }

        private func updateThinkingDurationText() {
            let text = String.localized("Thought for \(Int(thinkingDuration)) seconds")
            titleLabel.text = text
        }

        override var intrinsicContentSize: CGSize {
            let titleSize = titleLabel.intrinsicContentSize
            let symbolWidth: CGFloat = 14 + 6
            let loadingWidth = isThinking ? (loadingSymbol.intrinsicContentSize.width + 4) : 0
            let arrowWidth = Self.arrowFrameSize + (isThinking ? 6 : 4)
            return .init(
                width: symbolWidth + ceil(titleSize.width) + loadingWidth + arrowWidth,
                height: max(ceil(titleSize.height), ReasoningContentView.unrevealedTileHeight)
            )
        }
    }
}
