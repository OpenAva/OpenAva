//
//  Created by ktiays on 2025/2/7.
//  Copyright (c) 2025 ktiays. All rights reserved.
//

import ListViewKit
import Litext
import MarkdownView
import SnapKit
import UIKit

/// Base row view intended for specialized message row subclasses.
class MessageListRowView: ListRowView, UIContextMenuInteractionDelegate {
    var theme: MarkdownTheme = .default {
        didSet {
            themeDidUpdate()
            setNeedsLayout()
        }
    }

    let contentView = UIView()
    var contextMenuProvider: ((CGPoint) -> UIMenu?)?

    /// Tiny transparent anchor used as UITargetedPreview target so no content
    /// is lifted/zoomed during context menu presentation.
    private let contextMenuAnchor: UIView = {
        let v = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        v.backgroundColor = .clear
        v.isUserInteractionEnabled = false
        return v
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = false // tool tip will extend out
        addSubview(contentView)
        contentView.isUserInteractionEnabled = true
        contentView.addSubview(contextMenuAnchor)

        contentView.addInteraction(UIContextMenuInteraction(delegate: self))
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        themeDidUpdate()
        super.layoutSubviews()

        let insets = MessageListView.listRowInsets
        contentView.frame = CGRect(
            x: insets.left,
            y: 0,
            width: bounds.width - insets.horizontal,
            height: bounds.height - insets.bottom
        )
    }

    func themeDidUpdate() {}

    override func prepareForReuse() {
        super.prepareForReuse()
        contextMenuProvider = nil

        // clear any LTXLabel selection
        var queue = subviews
        while let v = queue.first {
            queue.removeFirst()
            queue.append(contentsOf: v.subviews)
            (v as? LTXLabel)?.clearSelection()
        }
    }

    // MARK: - UIContextMenuInteractionDelegate

    func contextMenuInteraction(
        _: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let menu = contextMenuProvider?(location) else { return nil }
        // Move the invisible anchor to the touch location so the menu appears there.
        contextMenuAnchor.frame = CGRect(origin: location, size: CGSize(width: 1, height: 1))
        return .init(previewProvider: nil) { _ in menu }
    }

    func contextMenuInteraction(
        _: UIContextMenuInteraction,
        previewForHighlightingMenuWithConfiguration _: UIContextMenuConfiguration
    ) -> UITargetedPreview? {
        // Suppress the lift/zoom highlight by using a clear background preview.
        suppressedTargetedPreview()
    }

    func contextMenuInteraction(
        _: UIContextMenuInteraction,
        previewForDismissingMenuWithConfiguration _: UIContextMenuConfiguration
    ) -> UITargetedPreview? {
        suppressedTargetedPreview()
    }

    private func suppressedTargetedPreview() -> UITargetedPreview {
        let params = UIPreviewParameters()
        params.backgroundColor = .clear
        params.shadowPath = UIBezierPath()
        // Target the 1×1 anchor so the system animates nothing visible.
        return UITargetedPreview(view: contextMenuAnchor, parameters: params)
    }
}
