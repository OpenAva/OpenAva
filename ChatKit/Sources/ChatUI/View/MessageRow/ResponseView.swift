//
//  Created by ktiays on 2025/2/6.
//  Copyright (c) 2025 ktiays. All rights reserved.
//

import ListViewKit
import MarkdownView
import UIKit

final class ResponseView: MessageListRowView {
    private(set) lazy var markdownView: MarkdownTextView = .init().with {
        $0.throttleInterval = 1 / 60
    }

    private lazy var agentHeaderLabel: UILabel = .init().with {
        $0.font = .systemFont(ofSize: 12, weight: .semibold)
        $0.textColor = .secondaryLabel
        $0.isHidden = true
    }

    var linkTapHandler: ((LinkPayload, NSRange, CGPoint) -> Void)? {
        get { markdownView.linkHandler }
        set { markdownView.linkHandler = newValue }
    }

    var codePreviewHandler: ((String?, NSAttributedString) -> Void)? {
        get { markdownView.codePreviewHandler }
        set { markdownView.codePreviewHandler = newValue }
    }

    init() {
        super.init(frame: .zero)
        configureSubviews()
    }

    @available(*, unavailable)
    @MainActor required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func configureSubviews() {
        contentView.addSubview(agentHeaderLabel)
        contentView.addSubview(markdownView)
    }

    func configure(agentName: String?, agentEmoji: String?) {
        if let name = agentName {
            let emojiStr = agentEmoji.map { "\($0) " } ?? ""
            agentHeaderLabel.text = "\(emojiStr)\(name)"
            agentHeaderLabel.isHidden = false
        } else {
            agentHeaderLabel.isHidden = true
        }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        var bounds = contentView.bounds
        if !agentHeaderLabel.isHidden {
            let labelHeight: CGFloat = 16
            let padding: CGFloat = 4
            agentHeaderLabel.frame = CGRect(x: 0, y: 0, width: bounds.width, height: labelHeight)
            let offset = labelHeight + padding
            bounds.origin.y += offset
            bounds.size.height -= offset
        }

        markdownView.frame = bounds
        markdownView.bindContentOffset(from: nearestScrollView)
    }
}
