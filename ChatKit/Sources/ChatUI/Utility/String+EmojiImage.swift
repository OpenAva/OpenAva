import UIKit

@MainActor
private let emojiImageCache = NSCache<NSString, UIImage>()

extension String {
    @MainActor
    func emojiImage(canvasSize: CGFloat = 128, scale: CGFloat = 0) -> UIImage? {
        let cacheKey = "\(self)-\(canvasSize)-\(scale)" as NSString
        if let cached = emojiImageCache.object(forKey: cacheKey) {
            return cached
        }

        let dimension = max(1, canvasSize)
        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = false
        format.scale = scale

        let nsString = self as NSString
        let candidateFontSizes: [CGFloat] = [dimension * 0.70, dimension * 0.65, dimension * 0.60, dimension * 0.55]

        let resolvedFontSize = candidateFontSizes.first { fontSize in
            let font = UIFont.systemFont(ofSize: fontSize)
            let measured = nsString.size(withAttributes: [.font: font])
            return measured.width <= dimension * 0.75 && measured.height <= dimension * 0.75
        } ?? dimension * 0.55

        let font = UIFont.systemFont(ofSize: resolvedFontSize)
        let measured = nsString.size(withAttributes: [.font: font])
        let drawRect = CGRect(
            x: (dimension - measured.width) / 2,
            y: (dimension - measured.height) / 2 - dimension * 0.03,
            width: measured.width,
            height: measured.height
        ).integral

        let image = UIGraphicsImageRenderer(size: CGSize(width: dimension, height: dimension), format: format).image { _ in
            nsString.draw(in: drawRect, withAttributes: [.font: font])
        }

        emojiImageCache.setObject(image, forKey: cacheKey)
        return image
    }
}
