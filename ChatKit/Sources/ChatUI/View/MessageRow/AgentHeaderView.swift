//
//  AgentHeaderView.swift
//  ChatUI
//
//  Message-level identity header for team/agent assistant turns.
//

import UIKit

final class AgentHeaderView: MessageListRowView {
    private let avatarContainerView = UIView()
    private let avatarImageView = UIImageView()
    private let nameLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)

        avatarContainerView.backgroundColor = ChatUIDesign.Color.warmCream
        avatarContainerView.layer.cornerRadius = MessageListRowView.agentAvatarSize / 2
        avatarContainerView.layer.cornerCurve = .continuous
        avatarContainerView.layer.borderWidth = 1
        avatarContainerView.layer.borderColor = ChatUIDesign.Color.oatBorder.cgColor
        avatarContainerView.clipsToBounds = true

        avatarImageView.contentMode = .center
        avatarContainerView.addSubview(avatarImageView)

        nameLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        nameLabel.textColor = .label

        contentView.addSubview(avatarContainerView)
        contentView.addSubview(nameLabel)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(with header: MessageListView.AgentHeaderRepresentation) {
        avatarImageView.image = header.displayEmoji.emojiImage(canvasSize: MessageListRowView.agentAvatarSize)
        nameLabel.text = header.displayName
        setNeedsLayout()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        avatarImageView.image = nil
        nameLabel.text = nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        let avatarSize = MessageListRowView.agentAvatarSize
        avatarContainerView.frame = CGRect(x: 0, y: 0, width: avatarSize, height: avatarSize)
        avatarImageView.frame = avatarContainerView.bounds

        let nameX = avatarContainerView.frame.maxX + MessageListRowView.agentAvatarSpacing
        nameLabel.frame = CGRect(
            x: nameX,
            y: 0,
            width: max(0, contentView.bounds.width - nameX),
            height: avatarSize
        )
    }
}
