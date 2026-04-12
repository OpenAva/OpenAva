//
//  MediaMessageView.swift
//  ChatUI
//
//  Renders inline media segments extracted from markdown messages.
//

import AVKit
import Combine
import MarkdownView
import SwiftUI
import UIKit

final class MediaMessageView: MessageListRowView {
    private static let horizontalPadding: CGFloat = 12
    private static let verticalPadding: CGFloat = 12
    private static let captionSpacing: CGFloat = 8
    private static let captionFont = UIFont.systemFont(ofSize: 12, weight: .regular)
    private static let mediaCornerRadius: CGFloat = 10

    private let cardView = UIView()
    private let captionLabel = UILabel()
    private let hostingController = UIHostingController(rootView: AnyView(EmptyView()))

    private var media: MessageListView.MediaRepresentation?

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureSubviews()
        themeDidUpdate()
    }

    @available(*, unavailable)
    @MainActor required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func themeDidUpdate() {
        let cardBackground = UIColor { trait in
            if trait.userInterfaceStyle == .dark {
                return UIColor(red: 0.11, green: 0.12, blue: 0.15, alpha: 0.82)
            }
            return UIColor(red: 0.985, green: 0.982, blue: 0.972, alpha: 0.98)
        }
        cardView.backgroundColor = cardBackground
        cardView.layer.borderColor = UIColor.separator.withAlphaComponent(0.22).cgColor
        captionLabel.textColor = .secondaryLabel
        updateMediaRootView()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        media = nil
        captionLabel.text = nil
        captionLabel.isHidden = true
        hostingController.rootView = AnyView(EmptyView())
    }

    func configure(with media: MessageListView.MediaRepresentation) {
        self.media = media
        captionLabel.text = Self.captionText(for: media)
        captionLabel.isHidden = (captionLabel.text ?? "").isEmpty
        updateMediaRootView()
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let media else { return }

        cardView.frame = contentView.bounds

        let innerWidth = max(0, cardView.bounds.width - Self.horizontalPadding * 2)
        let mediaHeight = Self.mediaHeight(for: media.kind, containerWidth: innerWidth)
        hostingController.view.frame = CGRect(
            x: Self.horizontalPadding,
            y: Self.verticalPadding,
            width: innerWidth,
            height: mediaHeight
        )

        let captionHeight = Self.captionHeight(for: media, containerWidth: innerWidth)
        captionLabel.frame = CGRect(
            x: Self.horizontalPadding,
            y: hostingController.view.frame.maxY + (captionHeight > 0 ? Self.captionSpacing : 0),
            width: innerWidth,
            height: captionHeight
        )
    }

    static func contentHeight(for media: MessageListView.MediaRepresentation, containerWidth: CGFloat) -> CGFloat {
        let innerWidth = max(0, containerWidth - horizontalPadding * 2)
        let mediaHeight = mediaHeight(for: media.kind, containerWidth: innerWidth)
        let captionHeight = captionHeight(for: media, containerWidth: innerWidth)
        let spacing = captionHeight > 0 ? captionSpacing : 0
        return ceil(verticalPadding * 2 + mediaHeight + spacing + captionHeight)
    }

    private static func mediaHeight(for kind: MarkdownMediaKind, containerWidth: CGFloat) -> CGFloat {
        switch kind {
        case .image:
            return min(max(containerWidth * 0.58, 170), 280)
        case .video:
            return min(max(containerWidth * 9 / 16, 180), 300)
        }
    }

    private static func captionHeight(for media: MessageListView.MediaRepresentation, containerWidth: CGFloat) -> CGFloat {
        guard let caption = captionText(for: media) else { return 0 }
        let attributed = NSAttributedString(string: caption, attributes: [.font: captionFont])
        let bounds = attributed.boundingRect(
            with: CGSize(width: containerWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        )
        return ceil(bounds.height)
    }

    private static func captionText(for media: MessageListView.MediaRepresentation) -> String? {
        guard let altText = media.altText?.trimmingCharacters(in: .whitespacesAndNewlines), !altText.isEmpty else {
            return nil
        }
        return altText
    }

    private func updateMediaRootView() {
        guard let media, let url = URL(string: media.url) else {
            hostingController.rootView = AnyView(MediaUnavailableView(kind: media?.kind ?? .image))
            return
        }

        hostingController.rootView = AnyView(
            MarkdownMediaRenderView(
                kind: media.kind,
                url: url,
                cornerRadius: Self.mediaCornerRadius
            )
        )
    }

    private func configureSubviews() {
        contentView.addSubview(cardView)
        cardView.layer.cornerRadius = ChatUIDesign.Radius.card
        cardView.layer.cornerCurve = .continuous
        cardView.layer.borderWidth = 1
        cardView.layer.borderColor = ChatUIDesign.Color.oatBorder.cgColor
        cardView.clipsToBounds = true

        hostingController.view.backgroundColor = .clear
        cardView.addSubview(hostingController.view)

        captionLabel.font = Self.captionFont
        captionLabel.numberOfLines = 0
        captionLabel.textColor = .secondaryLabel
        cardView.addSubview(captionLabel)
    }
}

private struct MarkdownMediaRenderView: View {
    let kind: MarkdownMediaKind
    let url: URL
    let cornerRadius: CGFloat

    var body: some View {
        Group {
            switch kind {
            case .image:
                RemoteImageView(url: url)
            case .video:
                InlineVideoPlayerView(url: url)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

private struct RemoteImageView: View {
    let url: URL
    @StateObject private var loader = RemoteImageLoader()

    var body: some View {
        Group {
            switch loader.phase {
            case .idle, .loading:
                mediaPlaceholder(systemImage: "photo", title: String.localized("Loading image..."))
            case let .success(image):
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .background(mediaSurfaceBackgroundColor)
            case .failure:
                MediaUnavailableView(kind: .image)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(mediaSurfaceBackgroundColor)
        .task(id: url) {
            loader.load(from: url)
        }
    }
}

@MainActor
private final class RemoteImageLoader: ObservableObject {
    enum Phase {
        case idle
        case loading
        case success(UIImage)
        case failure
    }

    private static let cache = NSCache<NSURL, UIImage>()

    @Published private(set) var phase: Phase = .idle

    private var currentURL: URL?
    private var currentTask: Task<Void, Never>?

    deinit {
        currentTask?.cancel()
    }

    func load(from url: URL) {
        if currentURL == url {
            switch phase {
            case .loading, .success:
                return
            case .idle, .failure:
                break
            }
        }

        currentTask?.cancel()
        currentURL = url

        if let cachedImage = Self.cache.object(forKey: url as NSURL) {
            phase = .success(cachedImage)
            return
        }

        phase = .loading
        currentTask = Task { [weak self] in
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                guard !Task.isCancelled else { return }

                if let httpResponse = response as? HTTPURLResponse,
                   !(200 ... 299).contains(httpResponse.statusCode)
                {
                    await self?.applyFailure(for: url)
                    return
                }

                guard let image = UIImage(data: data) else {
                    await self?.applyFailure(for: url)
                    return
                }

                Self.cache.setObject(image, forKey: url as NSURL)
                await self?.applySuccess(image, for: url)
            } catch is CancellationError {
                return
            } catch {
                let nsError = error as NSError
                if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
                    return
                }
                await self?.applyFailure(for: url)
            }
        }
    }

    private func applySuccess(_ image: UIImage, for url: URL) {
        guard currentURL == url else { return }
        phase = .success(image)
    }

    private func applyFailure(for url: URL) {
        guard currentURL == url else { return }
        phase = .failure
    }
}

private struct InlineVideoPlayerView: View {
    let url: URL
    @State private var player: AVPlayer

    init(url: URL) {
        self.url = url
        let player = AVPlayer(url: url)
        player.actionAtItemEnd = .pause
        _player = State(initialValue: player)
    }

    var body: some View {
        VideoPlayer(player: player)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black.opacity(0.92))
            .onDisappear {
                player.pause()
            }
    }
}

private struct MediaUnavailableView: View {
    let kind: MarkdownMediaKind

    var body: some View {
        mediaPlaceholder(
            systemImage: kind == .image ? "photo.slash" : "video.slash",
            title: kind == .image ? String.localized("Image unavailable") : String.localized("Video unavailable")
        )
    }
}

private func mediaPlaceholder(systemImage: String, title: String) -> some View {
    VStack(spacing: 10) {
        Image(systemName: systemImage)
            .font(.system(size: 24, weight: .medium))
            .foregroundStyle(Color(uiColor: .secondaryLabel))
        Text(title)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color(uiColor: .secondaryLabel))
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(mediaSurfaceBackgroundColor)
}

private var mediaSurfaceBackgroundColor: Color {
    Color(uiColor: UIColor { trait in
        if trait.userInterfaceStyle == .dark {
            return UIColor(red: 0.15, green: 0.16, blue: 0.19, alpha: 1.0)
        }
        return UIColor(red: 0.965, green: 0.962, blue: 0.952, alpha: 1.0)
    })
}
