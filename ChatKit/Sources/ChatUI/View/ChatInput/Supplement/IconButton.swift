//
//  IconButton.swift
//  ChatUI
//

import UIKit

final class IconButton: UIView {
    let imageView = UIImageView()
    var imageInsets: UIEdgeInsets = .init(top: 2, left: 2, bottom: 2, right: 2) {
        didSet { setNeedsLayout() }
    }

    var tapAction: () -> Void = {}

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(imageView)
        imageView.tintColor = .label
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentMode = .scaleAspectFit

        let tap = UITapGestureRecognizer(target: self, action: #selector(buttonAction))
        addGestureRecognizer(tap)

        isUserInteractionEnabled = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }

    convenience init(icon: String) {
        self.init(frame: .zero)
        imageView.image = UIImage.chatInputIcon(named: icon)
    }

    func change(icon: String, animated: Bool = true) {
        if animated {
            UIView.transition(with: imageView, duration: 0.3, options: .transitionCrossDissolve, animations: {
                self.change(icon: icon, animated: false)
            }, completion: nil)
        } else {
            imageView.image = UIImage.chatInputIcon(named: icon)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        imageView.frame = bounds.inset(by: imageInsets)
    }

    @objc private func buttonAction() {
        guard !isHidden else { return }
        guard alpha > 0 else { return }
        puddingAnimate()
        tapAction()
    }
}
