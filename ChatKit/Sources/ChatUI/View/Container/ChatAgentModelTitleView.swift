//
//  ChatAgentModelTitleView.swift
//  LanguageModelChatUI
//

import UIKit

final class ChatAgentModelTitleView: UIView {
    private enum Layout {
        static let minWidth: CGFloat = 120
        static let horizontalPadding: CGFloat = 6
        static let verticalPadding: CGFloat = 1
        static let verticalSpacing: CGFloat = 0
        static let minHeight: CGFloat = 24
    }

    private let stackView = UIStackView()
    private let agentLabel = UILabel()
    private let modelLabel = UILabel()

    var onAgentTap: (() -> Void)?
    var onModelTap: (() -> Void)?

    var agentTitle: String = "Assistant" {
        didSet {
            updateAgentLabelText()
            updateAccessibilityLabel()
            invalidateIntrinsicContentSize()
        }
    }

    var agentEmoji: String = "" {
        didSet {
            updateAgentLabelText()
            updateAccessibilityLabel()
            invalidateIntrinsicContentSize()
        }
    }

    var modelTitle: String = "Not Selected" {
        didSet {
            modelLabel.text = modelTitle
            updateAccessibilityLabel()
            invalidateIntrinsicContentSize()
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: CGSize {
        let agentSize = agentLabel.intrinsicContentSize
        let modelSize = modelLabel.intrinsicContentSize
        let width = max(agentSize.width, modelSize.width) + Layout.horizontalPadding * 2
        let height = agentSize.height + modelSize.height + Layout.verticalPadding * 2 + Layout.verticalSpacing
        return CGSize(width: max(Layout.minWidth, width), height: max(Layout.minHeight, height))
    }

    private func setupViews() {
        isUserInteractionEnabled = true
        backgroundColor = .clear
        isOpaque = false

        stackView.axis = .vertical
        stackView.alignment = .center
        stackView.distribution = .fill
        stackView.spacing = Layout.verticalSpacing

        agentLabel.font = ChatUIDesign.Typography.agentTitle
        agentLabel.lineBreakMode = .byTruncatingTail
        agentLabel.adjustsFontForContentSizeCategory = true
        agentLabel.textColor = ChatUIDesign.Color.offBlack
        agentLabel.textAlignment = .center
        agentLabel.numberOfLines = 1
        agentLabel.isUserInteractionEnabled = true
        agentLabel.accessibilityTraits = [.button]
        agentLabel.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleAgentTap)))

        modelLabel.font = ChatUIDesign.Typography.agentSubtitle
        modelLabel.lineBreakMode = .byTruncatingTail
        modelLabel.adjustsFontForContentSizeCategory = true
        modelLabel.textColor = ChatUIDesign.Color.black60
        modelLabel.textAlignment = .center
        modelLabel.numberOfLines = 1
        modelLabel.isUserInteractionEnabled = true
        modelLabel.accessibilityTraits = [.button]
        modelLabel.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleModelTap)))

        addSubview(stackView)
        stackView.addArrangedSubview(agentLabel)
        stackView.addArrangedSubview(modelLabel)

        updateAgentLabelText()
        modelLabel.text = modelTitle
        updateAccessibilityLabel()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        stackView.frame = bounds.insetBy(dx: Layout.horizontalPadding, dy: Layout.verticalPadding)
    }

    private func updateAccessibilityLabel() {
        let emojiText = agentEmoji.trimmingCharacters(in: .whitespacesAndNewlines)
        if emojiText.isEmpty {
            agentLabel.accessibilityLabel = "Agent \(agentTitle)"
        } else {
            agentLabel.accessibilityLabel = "Agent \(emojiText) \(agentTitle)"
        }
        modelLabel.accessibilityLabel = "Model \(modelTitle)"
    }

    private func updateAgentLabelText() {
        let trimmedEmoji = agentEmoji.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTitle: String
        if trimmedEmoji.isEmpty {
            resolvedTitle = agentTitle
        } else {
            resolvedTitle = "\(trimmedEmoji) \(agentTitle)"
        }
        agentLabel.text = resolvedTitle
    }

    @objc private func handleAgentTap() {
        onAgentTap?()
    }

    @objc private func handleModelTap() {
        onModelTap?()
    }
}
