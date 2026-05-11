//
//  AgentHeaderView.swift
//  ChatUI
//
//  Message-level identity header for team/agent assistant turns.
//

import Foundation
import UIKit

@MainActor private let agentHeaderAvatarImageCache = NSCache<NSURL, UIImage>()

final class AgentHeaderView: MessageListRowView {
    private let avatarContainerView = UIView()
    private let avatarImageView = UIImageView()
    private let nameLabel = UILabel()
    private var avatarTask: URLSessionDataTask?
    private var representedAvatarURL: URL?

    override init(frame: CGRect) {
        super.init(frame: frame)

        avatarContainerView.backgroundColor = ChatUIDesign.Color.warmCream
        avatarContainerView.layer.cornerRadius = MessageListRowView.agentAvatarSize / 2
        avatarContainerView.layer.cornerCurve = .continuous
        avatarContainerView.layer.borderWidth = 1
        avatarContainerView.layer.borderColor = ChatUIDesign.Color.oatBorder.cgColor
        avatarContainerView.clipsToBounds = true

        avatarImageView.contentMode = .scaleAspectFill
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
        representedAvatarURL = header.resolvedAvatarURL
        loadAvatarImageIfNeeded(from: header.resolvedAvatarURL)
        setNeedsLayout()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        avatarTask?.cancel()
        avatarTask = nil
        representedAvatarURL = nil
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

    private func loadAvatarImageIfNeeded(from url: URL?) {
        avatarTask?.cancel()
        avatarTask = nil

        guard let url else { return }
        if let cached = agentHeaderAvatarImageCache.object(forKey: url as NSURL) {
            avatarImageView.image = cached
            return
        }

        if url.isFileURL {
            guard let data = try? Data(contentsOf: url),
                  let image = UIImage(data: data)
            else {
                return
            }
            agentHeaderAvatarImageCache.setObject(image, forKey: url as NSURL)
            avatarImageView.image = image
            return
        }

        avatarTask = URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data, let image = UIImage(data: data) else { return }
            DispatchQueue.main.async {
                agentHeaderAvatarImageCache.setObject(image, forKey: url as NSURL)
                guard let self, self.representedAvatarURL == url else { return }
                self.avatarImageView.image = image
            }
        }
        avatarTask?.resume()
    }
}
