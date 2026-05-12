import ChatUI
import SwiftUI
import UIKit

struct AgentAvatarView: View {
    let descriptor: AgentAvatarDescriptor
    let size: CGFloat
    var overrideImage: UIImage?

    var body: some View {
        ZStack {
            Circle()
                .fill(Color(uiColor: ChatUIDesign.Color.warmCream))

            avatarContent
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(
            Circle()
                .stroke(Color(uiColor: ChatUIDesign.Color.oatBorder), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var avatarContent: some View {
        if let overrideImage {
            imageView(overrideImage)
        } else if let avatarImage = AgentAvatarDefaults.localImage(for: descriptor, canvasSize: size) {
            imageView(avatarImage)
        } else {
            switch descriptor.kind {
            case .diceBear:
                diceBearImage
            case .uploaded:
                fallbackImage
            case .emoji:
                Text(descriptor.displayEmoji)
                    .font(.system(size: size * 0.44))
            }
        }
    }

    private func imageView(_ image: UIImage) -> some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFill()
    }

    private var diceBearImage: some View {
        AsyncImage(url: descriptor.diceBearURL) { phase in
            switch phase {
            case let .success(image):
                image
                    .resizable()
                    .scaledToFill()
            case .empty, .failure:
                fallbackImage
            @unknown default:
                fallbackImage
            }
        }
    }

    private var fallbackImage: some View {
        Image(systemName: "person.crop.circle.fill")
            .font(.system(size: size * 0.72))
            .foregroundStyle(Color(uiColor: ChatUIDesign.Color.black50))
    }
}
