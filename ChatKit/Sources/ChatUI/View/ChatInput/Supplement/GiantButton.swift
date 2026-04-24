//
//  GiantButton.swift
//  ChatUI
//

import UIKit

final class GiantButton: UIView {
    let imageView = UIImageView()
    let backgroundView = UIView()
    let labelView = UILabel()

    var actionBlock: () -> Void = {}

    init(title _: String, icon: String) {
        super.init(frame: .zero)

        backgroundView.backgroundColor = .label.withAlphaComponent(0.05)
        backgroundView.layer.cornerRadius = ChatUIDesign.Radius.card
        backgroundView.layer.cornerCurve = .continuous
        addSubview(backgroundView)

        imageView.contentMode = .scaleAspectFit
        imageView.tintColor = ChatUIDesign.Color.black60
        imageView.image = UIImage.chatInputIcon(named: icon)
        backgroundView.addSubview(imageView)

        labelView.isHidden = true
        addSubview(labelView)

        let tap = UITapGestureRecognizer(target: self, action: #selector(onTapped))
        addGestureRecognizer(tap)
        isUserInteractionEnabled = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        backgroundView.frame = bounds
        let imageSize = CGSize(width: 24, height: 24)
        imageView.frame = .init(
            x: (backgroundView.bounds.width - imageSize.width) / 2,
            y: (backgroundView.bounds.height - imageSize.height) / 2,
            width: imageSize.width,
            height: imageSize.height
        )
    }

    @objc private func onTapped() {
        puddingAnimate()
        actionBlock()
    }
}
