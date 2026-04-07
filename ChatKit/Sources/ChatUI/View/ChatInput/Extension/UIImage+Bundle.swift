import UIKit

public extension UIImage {
    static func chatInputIcon(named name: String) -> UIImage? {
        // Prefer packaged asset icons, then fallback to SF Symbols by name.
        if let assetImage = UIImage(named: name, in: .module, compatibleWith: nil) {
            return assetImage.withRenderingMode(.alwaysTemplate)
        }

        if let symbolImage = UIImage(systemName: name)?.withRenderingMode(.alwaysTemplate) {
            return symbolImage
        }

        return emojiIcon(from: name)
    }

    private static func emojiIcon(from value: String) -> UIImage? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.containsEmoji else {
            return nil
        }

        let size = CGSize(width: 18, height: 18)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { _ in
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center

            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 15),
                .paragraphStyle: paragraph,
            ]

            let text = trimmed as NSString
            let textSize = text.size(withAttributes: attributes)
            let rect = CGRect(
                x: (size.width - textSize.width) / 2,
                y: (size.height - textSize.height) / 2,
                width: textSize.width,
                height: textSize.height
            )
            text.draw(in: rect, withAttributes: attributes)
        }

        return image.withRenderingMode(.alwaysOriginal)
    }
}

private extension String {
    var containsEmoji: Bool {
        unicodeScalars.contains { scalar in
            scalar.properties.isEmojiPresentation || scalar.properties.isEmoji
        }
    }
}
