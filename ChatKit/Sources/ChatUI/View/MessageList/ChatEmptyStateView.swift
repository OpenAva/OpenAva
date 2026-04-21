//
//  ChatEmptyStateView.swift
//  ChatUI
//

import SnapKit
import UIKit

public final class ChatEmptyStateView: UIView {
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let stackView = UIStackView()

    public var title: String? {
        get { titleLabel.text }
        set {
            titleLabel.text = newValue
            updateVisibility()
        }
    }

    public var subtitle: String? {
        get { subtitleLabel.text }
        set {
            subtitleLabel.text = newValue
            updateVisibility()
        }
    }

    override public init(frame: CGRect) {
        super.init(frame: frame)
        setupViews()
        title = String.localized("Ready for Tasks")
        subtitle = String.localized("Ask a question, run a skill, or call an Agent.")
        updateVisibility()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError()
    }

    private func setupViews() {
        titleLabel.font = .systemFont(ofSize: 24, weight: .semibold)
        titleLabel.textColor = ChatUIDesign.Color.offBlack
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 0

        subtitleLabel.font = .systemFont(ofSize: 15, weight: .regular)
        subtitleLabel.textColor = ChatUIDesign.Color.black60
        subtitleLabel.textAlignment = .center
        subtitleLabel.numberOfLines = 0

        stackView.addArrangedSubview(titleLabel)
        stackView.addArrangedSubview(subtitleLabel)
        stackView.axis = .vertical
        stackView.spacing = 8
        stackView.alignment = .center

        addSubview(stackView)
        stackView.snp.makeConstraints { make in
            make.center.equalToSuperview()
            make.leading.trailing.equalToSuperview().inset(32)
        }
    }

    private func updateVisibility() {
        titleLabel.isHidden = (titleLabel.text ?? "").isEmpty
        subtitleLabel.isHidden = (subtitleLabel.text ?? "").isEmpty
        stackView.isHidden = titleLabel.isHidden && subtitleLabel.isHidden
    }
}
