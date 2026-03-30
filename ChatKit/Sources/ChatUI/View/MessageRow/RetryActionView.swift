import UIKit

final class RetryActionView: MessageListRowView {
    static let rowHeight: CGFloat = 44

    var title: String = "" {
        didSet { button.setTitle(title, for: .normal) }
    }

    var tapHandler: (() -> Void)?

    private let button: UIButton = {
        var configuration = UIButton.Configuration.filled()
        configuration.cornerStyle = .capsule
        configuration.baseBackgroundColor = .systemOrange.withAlphaComponent(0.16)
        configuration.baseForegroundColor = .systemOrange
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14)

        let button = UIButton(configuration: configuration)
        button.titleLabel?.font = UIFont.preferredFont(forTextStyle: .footnote)
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        return button
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.addSubview(button)
        button.addTarget(self, action: #selector(handleTap), for: .touchUpInside)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        button.sizeToFit()
        let width = min(contentView.bounds.width, button.bounds.width + 24)
        button.frame = CGRect(
            x: 0,
            y: max(0, (contentView.bounds.height - button.bounds.height) / 2),
            width: width,
            height: button.bounds.height
        )
    }

    @objc
    private func handleTap() {
        tapHandler?()
    }
}
