import UIKit

final class RetryActionView: MessageListRowView {
    static let rowHeight: CGFloat = 88

    private enum UI {
        static let normalButtonTitle = String.localized("重试")
        static let loadingButtonTitle = String.localized("重试中")
    }

    var title: String = "" {
        didSet { titleLabel.text = title }
    }

    var isLoading = false {
        didSet {
            guard oldValue != isLoading else { return }
            updateLoadingState()
            setNeedsLayout()
        }
    }

    var tapHandler: (() -> Void)?

    private let containerView: UIView = {
        let view = UIView()
        view.backgroundColor = .systemOrange.withAlphaComponent(0.08)
        view.layer.cornerRadius = 14
        view.layer.cornerCurve = .continuous
        view.layer.borderWidth = 1
        view.layer.borderColor = UIColor.systemOrange.withAlphaComponent(0.18).cgColor
        return view
    }()

    private let iconView: UIImageView = {
        let imageView = UIImageView(image: UIImage(systemName: "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90"))
        imageView.tintColor = .systemOrange
        imageView.contentMode = .scaleAspectFit
        return imageView
    }()

    private let titleLabel: UILabel = {
        let label = UILabel()
        label.font = .preferredFont(forTextStyle: .footnote)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .secondaryLabel
        label.numberOfLines = 2
        return label
    }()

    private let button: UIButton = {
        var configuration = UIButton.Configuration.filled()
        configuration.cornerStyle = .capsule
        configuration.baseBackgroundColor = .systemOrange
        configuration.baseForegroundColor = .white
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16)
        configuration.title = UI.normalButtonTitle

        let button = UIButton(configuration: configuration)
        button.titleLabel?.font = UIFont.preferredFont(forTextStyle: .footnote)
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.accessibilityTraits.insert(.button)
        return button
    }()

    private let activityIndicator: UIActivityIndicatorView = {
        let indicator = UIActivityIndicatorView(style: .medium)
        indicator.hidesWhenStopped = true
        indicator.color = .white
        indicator.isUserInteractionEnabled = false
        return indicator
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.addSubview(containerView)
        containerView.addSubview(iconView)
        containerView.addSubview(titleLabel)
        containerView.addSubview(button)
        button.addSubview(activityIndicator)
        button.addTarget(self, action: #selector(handleTap), for: .touchUpInside)
        updateLoadingState()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        containerView.frame = contentView.bounds
        iconView.frame = CGRect(x: 14, y: 16, width: 18, height: 18)

        button.sizeToFit()
        let buttonWidth = min(max(72, button.bounds.width + 20), 96)
        let buttonHeight = max(32, button.bounds.height)
        button.frame = CGRect(
            x: contentView.bounds.width - buttonWidth - 14,
            y: max(12, (contentView.bounds.height - buttonHeight) / 2),
            width: buttonWidth,
            height: buttonHeight
        )
        activityIndicator.center = CGPoint(x: 18, y: button.bounds.midY)

        let titleX = iconView.frame.maxX + 10
        let titleWidth = max(0, button.frame.minX - titleX - 12)
        titleLabel.frame = CGRect(
            x: titleX,
            y: 12,
            width: titleWidth,
            height: contentView.bounds.height - 24
        )
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        tapHandler = nil
        titleLabel.text = nil
        isLoading = false
    }

    @objc
    private func handleTap() {
        guard !isLoading else { return }
        tapHandler?()
    }

    private func updateLoadingState() {
        button.isEnabled = !isLoading
        button.alpha = isLoading ? 0.92 : 1

        var configuration = button.configuration ?? .filled()
        configuration.title = isLoading ? UI.loadingButtonTitle : UI.normalButtonTitle
        configuration.image = nil
        configuration.baseBackgroundColor = isLoading ? .systemOrange.withAlphaComponent(0.8) : .systemOrange
        configuration.baseForegroundColor = .white
        configuration.contentInsets = NSDirectionalEdgeInsets(
            top: 8,
            leading: isLoading ? 34 : 16,
            bottom: 8,
            trailing: 16
        )
        button.configuration = configuration

        if isLoading {
            activityIndicator.startAnimating()
        } else {
            activityIndicator.stopAnimating()
        }
    }
}
