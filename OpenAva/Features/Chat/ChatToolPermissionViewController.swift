import ChatUI
import UIKit

@MainActor
protocol ChatToolPermissionViewControllerDelegate: AnyObject {
    func toolPermissionViewController(_ controller: ChatToolPermissionViewController, didSelectAction action: ChatToolPermissionViewController.Action)
}

/// Tool approval sheet.
///
/// Visual language follows `DESIGN.md`:
/// - Warm Cream background, Off Black text, Oat borders
/// - 4px radius for buttons, 8px radius for cards
/// - Depth is expressed with borders and surface contrast, not shadows
/// - Brand Orange is reserved for the AI-forward primary affordance only when
///   a key emphasis is required; this dialog uses the standard Primary Dark
///   button because the decision is not AI-initiated beyond the request itself
@MainActor
final class ChatToolPermissionViewController: UIViewController {
    enum Action {
        case allowOnce
        case alwaysAllowExact
        case alwaysAllowTool
        case deny
    }

    weak var delegate: ChatToolPermissionViewControllerDelegate?

    private let toolName: String
    private let requestMessage: String
    private let apiName: String
    private let argumentsText: String?

    private var rememberExpanded = false
    private var rememberOptionsContainer: UIStackView!
    private var rememberChevron: UIImageView!
    private var rememberChoice: RememberChoice = .once

    private enum RememberChoice {
        case once
        case alwaysTool
        case alwaysExact

        var tagValue: Int {
            switch self {
            case .once: return 0
            case .alwaysTool: return 1
            case .alwaysExact: return 2
            }
        }
    }

    init(toolName: String, message: String, apiName: String, argumentsText: String?) {
        self.toolName = toolName
        self.requestMessage = message
        self.apiName = apiName
        self.argumentsText = argumentsText
        super.init(nibName: nil, bundle: nil)
        self.modalPresentationStyle = .formSheet
        self.isModalInPresentation = true
        if let sheet = self.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
            sheet.preferredCornerRadius = 16
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = ChatUIDesign.Color.warmCream

        let scrollView = UIScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = true
        view.addSubview(scrollView)

        let contentStack = UIStackView()
        contentStack.axis = .vertical
        contentStack.spacing = 20
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(contentStack)

        let footerSeparator = UIView()
        footerSeparator.backgroundColor = ChatUIDesign.Color.oatBorder
        footerSeparator.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(footerSeparator)

        let footerStack = UIStackView()
        footerStack.axis = .vertical
        footerStack.spacing = 12
        footerStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(footerStack)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: footerSeparator.topAnchor),

            contentStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 24),
            contentStack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 20),
            contentStack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -20),
            contentStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -16),
            contentStack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -40),

            footerSeparator.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            footerSeparator.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            footerSeparator.bottomAnchor.constraint(equalTo: footerStack.topAnchor, constant: -16),
            footerSeparator.heightAnchor.constraint(equalToConstant: 1.0 / UIScreen.main.scale),

            footerStack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
            footerStack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            footerStack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
        ])

        contentStack.addArrangedSubview(makeHeaderView())
        contentStack.addArrangedSubview(makeDetailsCard())

        footerStack.addArrangedSubview(makeRememberChoiceSection())
        footerStack.addArrangedSubview(makePrimaryActionsRow())
    }

    // MARK: - Header

    private func makeHeaderView() -> UIView {
        let container = UIStackView()
        container.axis = .vertical
        container.spacing = 12
        container.alignment = .leading

        let iconBackground = UIView()
        iconBackground.backgroundColor = ChatUIDesign.Color.pureWhite
        iconBackground.layer.borderColor = ChatUIDesign.Color.oatBorder.cgColor
        iconBackground.layer.borderWidth = 1
        iconBackground.layer.cornerRadius = ChatUIDesign.Radius.card
        iconBackground.translatesAutoresizingMaskIntoConstraints = false

        let icon = UIImageView(image: UIImage(systemName: "wrench.and.screwdriver"))
        icon.tintColor = ChatUIDesign.Color.offBlack
        icon.contentMode = .scaleAspectFit
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 20, weight: .regular)
        icon.translatesAutoresizingMaskIntoConstraints = false
        iconBackground.addSubview(icon)

        NSLayoutConstraint.activate([
            iconBackground.widthAnchor.constraint(equalToConstant: 40),
            iconBackground.heightAnchor.constraint(equalToConstant: 40),
            icon.centerXAnchor.constraint(equalTo: iconBackground.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: iconBackground.centerYAnchor),
        ])

        let titleLabel = UILabel()
        titleLabel.attributedText = makeEditorialTitle(
            String.localized("Run tool “\(toolName)”?")
        )
        titleLabel.numberOfLines = 0

        container.addArrangedSubview(iconBackground)
        container.addArrangedSubview(titleLabel)

        if !requestMessage.isEmpty {
            let messageLabel = UILabel()
            messageLabel.text = requestMessage
            messageLabel.font = .systemFont(ofSize: 14, weight: .regular)
            messageLabel.textColor = ChatUIDesign.Color.black60
            messageLabel.numberOfLines = 0
            container.addArrangedSubview(messageLabel)
        }

        return container
    }

    /// Headings keep the editorial feel described in DESIGN.md §4:
    /// bold Saans-like weight, line-height 1.0, negative tracking.
    private func makeEditorialTitle(_ text: String) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = 24
        paragraph.maximumLineHeight = 24
        return NSAttributedString(string: text, attributes: [
            .font: UIFont.systemFont(ofSize: 24, weight: .bold),
            .foregroundColor: ChatUIDesign.Color.offBlack,
            .kern: -0.5,
            .paragraphStyle: paragraph,
        ])
    }

    // MARK: - Details Card

    private func makeDetailsCard() -> UIView {
        let card = UIStackView()
        card.axis = .vertical
        card.spacing = 12
        card.backgroundColor = ChatUIDesign.Color.pureWhite
        card.layer.cornerRadius = ChatUIDesign.Radius.card
        card.layer.borderColor = ChatUIDesign.Color.oatBorder.cgColor
        card.layer.borderWidth = 1
        card.isLayoutMarginsRelativeArrangement = true
        card.layoutMargins = UIEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)

        card.addArrangedSubview(makeFieldBlock(
            key: String.localized("API"),
            valueView: makeMonoLabel(apiName)
        ))

        if let args = argumentsText, !args.isEmpty {
            let separator = UIView()
            separator.backgroundColor = ChatUIDesign.Color.oatBorder
            separator.translatesAutoresizingMaskIntoConstraints = false
            separator.heightAnchor.constraint(equalToConstant: 1.0 / UIScreen.main.scale).isActive = true
            card.addArrangedSubview(separator)

            card.addArrangedSubview(makeFieldBlock(
                key: String.localized("Arguments"),
                valueView: makeScrollableCodeBlock(args)
            ))
        }

        return card
    }

    /// A labeled field stacked vertically: uppercase mono key above the value.
    private func makeFieldBlock(key: String, valueView: UIView) -> UIView {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 8
        stack.alignment = .fill

        let keyLabel = UILabel()
        keyLabel.text = key.uppercased()
        keyLabel.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        keyLabel.textColor = ChatUIDesign.Color.black50
        keyLabel.setContentCompressionResistancePriority(.required, for: .vertical)
        // Approximate Mono Label tracking from DESIGN.md (0.6–1.2px uppercase).
        keyLabel.attributedText = NSAttributedString(string: key.uppercased(), attributes: [
            .font: UIFont.monospacedSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: ChatUIDesign.Color.black50,
            .kern: 0.8,
        ])

        stack.addArrangedSubview(keyLabel)
        stack.addArrangedSubview(valueView)
        return stack
    }

    private func makeMonoLabel(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        label.textColor = ChatUIDesign.Color.offBlack
        label.numberOfLines = 0
        return label
    }

    /// Arguments can be arbitrarily long and wide (JSON, Markdown bodies).
    /// Cap its visible height so the action area never gets pushed off-screen,
    /// and let the user scroll horizontally and vertically inside the block.
    private func makeScrollableCodeBlock(_ text: String) -> UIView {
        let container = UIView()
        container.backgroundColor = ChatUIDesign.Color.warmCream
        container.layer.cornerRadius = ChatUIDesign.Radius.button
        container.layer.borderColor = ChatUIDesign.Color.oatBorder.cgColor
        container.layer.borderWidth = 1
        container.clipsToBounds = true
        container.translatesAutoresizingMaskIntoConstraints = false

        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.showsVerticalScrollIndicator = true
        scroll.showsHorizontalScrollIndicator = false
        scroll.alwaysBounceVertical = true
        container.addSubview(scroll)

        let label = UILabel()
        label.text = text
        label.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        label.textColor = ChatUIDesign.Color.offBlack
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(label)

        let heightCap = container.heightAnchor.constraint(lessThanOrEqualToConstant: 180)
        heightCap.priority = .required
        let preferredHeight = container.heightAnchor.constraint(equalToConstant: 180)
        preferredHeight.priority = .defaultHigh

        NSLayoutConstraint.activate([
            heightCap,
            preferredHeight,

            scroll.topAnchor.constraint(equalTo: container.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            label.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 12),
            label.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -12),
            label.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -12),
            label.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -24),
        ])
        return container
    }

    // MARK: - Remember Choice

    private func makeRememberChoiceSection() -> UIView {
        let container = UIStackView()
        container.axis = .vertical
        container.spacing = 10

        let row = UIStackView()
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 6

        let label = UILabel()
        label.attributedText = NSAttributedString(
            string: String.localized("Remember my choice").uppercased(),
            attributes: [
                .font: UIFont.monospacedSystemFont(ofSize: 11, weight: .medium),
                .foregroundColor: ChatUIDesign.Color.black50,
                .kern: 0.8,
            ]
        )

        let chevron = UIImageView(image: UIImage(systemName: "chevron.down"))
        chevron.tintColor = ChatUIDesign.Color.black50
        chevron.contentMode = .scaleAspectFit
        chevron.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        chevron.translatesAutoresizingMaskIntoConstraints = false
        chevron.widthAnchor.constraint(equalToConstant: 12).isActive = true
        chevron.heightAnchor.constraint(equalToConstant: 12).isActive = true
        self.rememberChevron = chevron

        row.addArrangedSubview(label)
        row.addArrangedSubview(chevron)
        row.addArrangedSubview(UIView())

        let tap = UITapGestureRecognizer(target: self, action: #selector(toggleRememberExpanded))
        row.isUserInteractionEnabled = true
        row.addGestureRecognizer(tap)

        let options = UIStackView()
        options.axis = .vertical
        options.spacing = 8
        options.isHidden = true
        self.rememberOptionsContainer = options

        options.addArrangedSubview(makeRememberOption(
            title: String.localized("Always allow for this tool"),
            subtitle: String.localized("Skip approval for any future call to this tool."),
            choice: .alwaysTool
        ))
        options.addArrangedSubview(makeRememberOption(
            title: String.localized("Always allow for this exact request"),
            subtitle: String.localized("Skip approval only when the same arguments are used again."),
            choice: .alwaysExact
        ))

        container.addArrangedSubview(row)
        container.addArrangedSubview(options)
        return container
    }

    private func makeRememberOption(title: String, subtitle: String, choice: RememberChoice) -> UIView {
        let button = UIButton(type: .system)
        var config = UIButton.Configuration.plain()
        config.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12)

        let titleAttr = AttributedString(title, attributes: AttributeContainer([
            .font: UIFont.systemFont(ofSize: 14, weight: .semibold),
            .foregroundColor: ChatUIDesign.Color.offBlack,
        ]))
        var subtitleAttr = AttributedString("\n" + subtitle)
        subtitleAttr.font = .systemFont(ofSize: 12, weight: .regular)
        subtitleAttr.foregroundColor = ChatUIDesign.Color.black60

        var combined = titleAttr
        combined.append(subtitleAttr)
        config.attributedTitle = combined

        config.image = UIImage(systemName: "circle")
        config.imagePadding = 10
        config.imagePlacement = .leading
        config.baseForegroundColor = ChatUIDesign.Color.black50
        button.configuration = config
        button.contentHorizontalAlignment = .leading
        button.titleLabel?.numberOfLines = 0
        button.backgroundColor = ChatUIDesign.Color.pureWhite
        button.layer.cornerRadius = ChatUIDesign.Radius.card
        button.layer.borderWidth = 1
        button.layer.borderColor = ChatUIDesign.Color.oatBorder.cgColor

        button.addAction(UIAction { [weak self] _ in
            self?.selectRemember(choice: choice)
        }, for: .touchUpInside)

        button.tag = choice.tagValue
        return button
    }

    @objc private func toggleRememberExpanded() {
        rememberExpanded.toggle()
        UIView.animate(withDuration: 0.2) {
            self.rememberOptionsContainer.isHidden = !self.rememberExpanded
            self.rememberChevron.transform = self.rememberExpanded
                ? CGAffineTransform(rotationAngle: .pi)
                : .identity
            self.view.layoutIfNeeded()
        }
    }

    private func selectRemember(choice: RememberChoice) {
        rememberChoice = (rememberChoice == choice) ? .once : choice
        refreshRememberOptionStyles()
    }

    private func refreshRememberOptionStyles() {
        for case let button as UIButton in rememberOptionsContainer.arrangedSubviews {
            let isSelected = button.tag == rememberChoice.tagValue && rememberChoice != .once
            var config = button.configuration
            config?.image = UIImage(systemName: isSelected ? "largecircle.fill.circle" : "circle")
            config?.baseForegroundColor = isSelected
                ? ChatUIDesign.Color.offBlack
                : ChatUIDesign.Color.black50
            button.configuration = config
            button.layer.borderColor = (isSelected
                ? ChatUIDesign.Color.offBlack
                : ChatUIDesign.Color.oatBorder).cgColor
            button.layer.borderWidth = isSelected ? 1.5 : 1
        }
    }

    // MARK: - Primary Actions

    private func makePrimaryActionsRow() -> UIView {
        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = 12
        row.distribution = .fillEqually

        let denyButton = makeOutlinedButton(title: String.localized("Deny")) { [weak self] in
            guard let self else { return }
            self.delegate?.toolPermissionViewController(self, didSelectAction: .deny)
        }

        let allowButton = makePrimaryDarkButton(title: String.localized("Allow")) { [weak self] in
            guard let self else { return }
            let action: Action
            switch self.rememberChoice {
            case .once: action = .allowOnce
            case .alwaysTool: action = .alwaysAllowTool
            case .alwaysExact: action = .alwaysAllowExact
            }
            self.delegate?.toolPermissionViewController(self, didSelectAction: action)
        }

        row.addArrangedSubview(denyButton)
        row.addArrangedSubview(allowButton)
        return row
    }

    /// Primary Dark button from DESIGN.md §5 (Off Black fill, white label, 4px radius).
    private func makePrimaryDarkButton(title: String, onTap: @escaping () -> Void) -> UIButton {
        var config = UIButton.Configuration.plain()
        config.attributedTitle = AttributedString(title, attributes: AttributeContainer([
            .font: UIFont.systemFont(ofSize: 16, weight: .semibold),
            .foregroundColor: ChatUIDesign.Color.pureWhite,
        ]))
        config.contentInsets = NSDirectionalEdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16)
        config.background.backgroundColor = ChatUIDesign.Color.offBlack
        config.background.cornerRadius = ChatUIDesign.Radius.button

        let button = UIButton(configuration: config)
        button.addAction(UIAction { _ in onTap() }, for: .touchUpInside)
        return button
    }

    /// Outlined button from DESIGN.md §5 (transparent fill, off-black label + border, 4px radius).
    private func makeOutlinedButton(title: String, onTap: @escaping () -> Void) -> UIButton {
        var config = UIButton.Configuration.plain()
        config.attributedTitle = AttributedString(title, attributes: AttributeContainer([
            .font: UIFont.systemFont(ofSize: 16, weight: .semibold),
            .foregroundColor: ChatUIDesign.Color.offBlack,
        ]))
        config.contentInsets = NSDirectionalEdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16)
        config.background.backgroundColor = .clear
        config.background.strokeColor = ChatUIDesign.Color.offBlack
        config.background.strokeWidth = 1
        config.background.cornerRadius = ChatUIDesign.Radius.button

        let button = UIButton(configuration: config)
        button.addAction(UIAction { _ in onTap() }, for: .touchUpInside)
        return button
    }
}
