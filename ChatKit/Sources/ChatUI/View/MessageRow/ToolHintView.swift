//
//  Created by ktiays on 2025/2/28.
//  Copyright (c) 2025 ktiays. All rights reserved.
//

import UIKit

final class ToolHintView: MessageListRowView {
    // Inline, lightweight style to match reasoning tile.
    private static let chevronSymbolPointSize: CGFloat = 13
    private static let chevronSymbolWeight: UIImage.SymbolWeight = .medium

    var text: String?

    var toolName: String = .init() {
        didSet { updateContentText() }
    }

    var hasResult: Bool = false {
        didSet { updateContentText() }
    }

    var isExpanded: Bool = false {
        didSet {
            updateContentText()
            updateChevronRotation()
        }
    }

    var state: ToolCallState = .running {
        didSet {
            updateContentText()
            updateStateImage()
        }
    }

    var clickHandler: (() -> Void)?

    private let label: ShimmerTextLabel = .init().with {
        $0.font = UIFont.preferredFont(forTextStyle: .body)
        $0.textColor = .label
        $0.minimumScaleFactor = 0.5
        $0.adjustsFontForContentSizeCategory = true
        $0.lineBreakMode = .byTruncatingTail
        $0.numberOfLines = 1
        $0.adjustsFontSizeToFitWidth = true
        $0.textAlignment = .left
        $0.animationDuration = 1.6
    }

    private let symbolView: UIImageView = .init().with {
        $0.contentMode = .scaleAspectFit
    }

    private let chevronView: UIImageView = .init().with {
        $0.contentMode = .scaleAspectFit
        $0.tintColor = .tertiaryLabel
        $0.isHidden = true
    }

    private var isClickable: Bool = false
    private let chevronSize: CGFloat = 14
    private let symbolSize: CGFloat = 14

    override init(frame: CGRect) {
        super.init(frame: frame)

        contentView.backgroundColor = .clear
        contentView.addSubview(symbolView)
        contentView.addSubview(label)
        contentView.addSubview(chevronView)

        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        contentView.addGestureRecognizer(tapGesture)

        updateStateImage()
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        let labelSize = label.intrinsicContentSize

        symbolView.frame = .init(
            x: 0,
            y: (contentView.bounds.height - symbolSize) / 2,
            width: symbolSize,
            height: symbolSize
        )

        label.frame = .init(
            x: symbolView.frame.maxX + 6,
            y: (contentView.bounds.height - labelSize.height) / 2,
            width: labelSize.width,
            height: labelSize.height
        )

        chevronView.frame = .init(
            x: label.frame.maxX + 6,
            y: (contentView.bounds.height - chevronSize) / 2,
            width: chevronSize,
            height: chevronSize
        )

        let contentWidth = chevronView.isHidden ? label.frame.maxX : chevronView.frame.maxX
        contentView.frame.size.width = contentWidth
    }

    override func themeDidUpdate() {
        super.themeDidUpdate()
        label.font = theme.fonts.body
        chevronView.tintColor = .tertiaryLabel
    }

    private func updateStateImage() {
        let configuration = UIImage.SymbolConfiguration(
            pointSize: symbolSize,
            weight: .medium
        )
        switch state {
        case .succeeded:
            let image = UIImage(systemName: "checkmark.circle", withConfiguration: configuration)
            symbolView.image = image
            symbolView.tintColor = .systemGreen
            label.stopShimmer()
        case .running:
            let image = UIImage(systemName: "hourglass", withConfiguration: configuration)
            symbolView.image = image
            symbolView.tintColor = .systemBlue
            label.startShimmer()
        case .failed:
            let image = UIImage(systemName: "xmark.circle", withConfiguration: configuration)
            symbolView.image = image
            symbolView.tintColor = .systemRed
            label.stopShimmer()
        }
        invalidateLayout()
    }

    private func updateContentText() {
        switch state {
        case .running:
            isClickable = false
            label.text = String.localized("Tool call for \(toolName) running")
        case .succeeded:
            isClickable = hasResult
            label.text = hasResult
                ? String.localized("Tool call for \(toolName) completed.")
                : String.localized("Tool call for \(toolName) completed.")
        case .failed:
            isClickable = hasResult
            label.text = hasResult
                ? String.localized("Tool call for \(toolName) failed.")
                : String.localized("Tool call for \(toolName) failed.")
        }
        updateChevronImage()
        updateChevronRotation()
        invalidateLayout()
    }

    private func updateChevronImage() {
        guard isClickable else {
            chevronView.isHidden = true
            chevronView.image = nil
            return
        }

        chevronView.isHidden = false
        // Use chevron.right; rotation is applied via updateChevronRotation()
        let configuration = UIImage.SymbolConfiguration(
            pointSize: Self.chevronSymbolPointSize,
            weight: Self.chevronSymbolWeight
        )
        chevronView.image = UIImage(systemName: "chevron.right", withConfiguration: configuration)
    }

    private func updateChevronRotation() {
        doWithAnimation {
            self.chevronView.transform = self.isExpanded
                ? .init(rotationAngle: .pi / 2)
                : .identity
        }
    }

    func invalidateLayout() {
        label.invalidateIntrinsicContentSize()
        label.sizeToFit()
        setNeedsLayout()

        doWithAnimation {
            self.layoutIfNeeded()
        }
    }

    @objc
    private func handleTap(_ sender: UITapGestureRecognizer) {
        if isClickable, sender.state == .ended {
            clickHandler?()
        }
    }
}
