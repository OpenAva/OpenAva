import Foundation
import UIKit

enum TextImageRenderServiceError: LocalizedError {
    case emptyText
    case renderFailed

    var errorDescription: String? {
        switch self {
        case .emptyText:
            return "Text content is empty"
        case .renderFailed:
            return "Failed to render text image"
        }
    }
}

struct TextImageRenderResult {
    struct Page {
        let index: Int
        let total: Int
        let width: Int
        let height: Int
        let format: String
        let data: Data
        let text: String
    }

    let pages: [Page]
    let truncated: Bool
    let theme: String
}

/// Generate social-friendly image cards from plain text with automatic pagination.
final class TextImageRenderService {
    struct Request {
        var text: String
        var title: String?
        var theme: String?
        var width: Int?
        var aspectRatio: String?
        var maxPages: Int?
    }

    private struct ThemePalette {
        let backgroundTop: UIColor
        let backgroundBottom: UIColor
        let cardBackground: UIColor
        let cardBorder: UIColor
        let accent: UIColor
        let titleColor: UIColor
        let bodyColor: UIColor
        let footerColor: UIColor
    }

    private struct RenderConfig {
        let theme: String
        let width: Int
        let height: Int
        let maxPages: Int
    }

    func render(request: Request) throws -> TextImageRenderResult {
        let normalizedText = Self.normalizedText(request.text)
        guard !normalizedText.isEmpty else {
            throw TextImageRenderServiceError.emptyText
        }

        let config = Self.resolveConfig(from: request)
        let palette = Self.palette(for: config.theme)
        let canvasSize = CGSize(width: CGFloat(config.width), height: CGFloat(config.height))

        let cardInset = max(32, CGFloat(config.width) * 0.06)
        let cardRect = CGRect(
            x: cardInset,
            y: cardInset,
            width: canvasSize.width - cardInset * 2,
            height: canvasSize.height - cardInset * 2
        )
        let contentInset = max(26, CGFloat(config.width) * 0.045)
        let contentRect = cardRect.insetBy(dx: contentInset, dy: contentInset)

        let titleText = Self.normalizedTitle(request.title)
        let titleFont = UIFont.systemFont(ofSize: max(34, CGFloat(config.width) * 0.053), weight: .semibold)
        let bodyFont = UIFont.systemFont(ofSize: max(28, CGFloat(config.width) * 0.037), weight: .regular)
        let footerFont = UIFont.systemFont(ofSize: max(20, CGFloat(config.width) * 0.024), weight: .medium)

        let titleHeight = titleText == nil ? 0 : ceil(titleFont.lineHeight * 1.6)
        let titleSpacing = titleText == nil ? 0 : max(14, CGFloat(config.width) * 0.015)
        let footerHeight = ceil(footerFont.lineHeight) + max(10, CGFloat(config.width) * 0.01)

        let bodyRect = CGRect(
            x: contentRect.minX,
            y: contentRect.minY + titleHeight + titleSpacing,
            width: contentRect.width,
            height: contentRect.height - titleHeight - titleSpacing - footerHeight
        )

        let bodyAttributes = Self.bodyAttributes(font: bodyFont, color: palette.bodyColor, width: bodyRect.width)
        var pagesText = Self.paginate(
            normalizedText,
            maxWidth: bodyRect.width,
            maxHeight: bodyRect.height,
            attributes: bodyAttributes,
            maxPages: config.maxPages
        )

        if pagesText.pages.isEmpty {
            pagesText.pages = [normalizedText]
            pagesText.truncated = false
        }

        var renderedPages: [TextImageRenderResult.Page] = []
        for (index, pageText) in pagesText.pages.enumerated() {
            guard let data = drawPage(
                text: pageText,
                title: titleText,
                pageIndex: index + 1,
                totalPages: pagesText.pages.count,
                size: canvasSize,
                cardRect: cardRect,
                contentRect: contentRect,
                bodyRect: bodyRect,
                palette: palette,
                titleFont: titleFont,
                bodyAttributes: bodyAttributes,
                footerFont: footerFont,
                config: config
            ) else {
                throw TextImageRenderServiceError.renderFailed
            }

            renderedPages.append(
                TextImageRenderResult.Page(
                    index: index + 1,
                    total: pagesText.pages.count,
                    width: config.width,
                    height: config.height,
                    format: "png",
                    data: data,
                    text: pageText
                )
            )
        }

        return TextImageRenderResult(
            pages: renderedPages,
            truncated: pagesText.truncated,
            theme: config.theme
        )
    }

    // MARK: - Drawing

    private func drawPage(
        text: String,
        title: String?,
        pageIndex: Int,
        totalPages: Int,
        size: CGSize,
        cardRect: CGRect,
        contentRect: CGRect,
        bodyRect: CGRect,
        palette: ThemePalette,
        titleFont: UIFont,
        bodyAttributes: [NSAttributedString.Key: Any],
        footerFont: UIFont,
        config _: RenderConfig
    ) -> Data? {
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { rendererContext in
            let ctx = rendererContext.cgContext
            drawBackground(in: ctx, size: size, palette: palette)
            drawCard(in: ctx, rect: cardRect, palette: palette)

            if let title {
                let titleStyle = NSMutableParagraphStyle()
                titleStyle.lineBreakMode = .byTruncatingTail

                let titleAttributes: [NSAttributedString.Key: Any] = [
                    .font: titleFont,
                    .foregroundColor: palette.titleColor,
                    .paragraphStyle: titleStyle,
                ]

                let titleRect = CGRect(
                    x: contentRect.minX,
                    y: contentRect.minY,
                    width: contentRect.width,
                    height: ceil(titleFont.lineHeight * 1.6)
                )
                (title as NSString).draw(with: titleRect, options: [.usesLineFragmentOrigin], attributes: titleAttributes, context: nil)
            }

            (text as NSString).draw(
                with: bodyRect,
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: bodyAttributes,
                context: nil
            )

            let footerStyle = NSMutableParagraphStyle()
            footerStyle.alignment = .right
            let footerAttributes: [NSAttributedString.Key: Any] = [
                .font: footerFont,
                .foregroundColor: palette.footerColor,
                .paragraphStyle: footerStyle,
            ]

            let footerText = "\(pageIndex)/\(totalPages)"
            let footerRect = CGRect(
                x: contentRect.minX,
                y: contentRect.maxY - ceil(footerFont.lineHeight),
                width: contentRect.width,
                height: ceil(footerFont.lineHeight)
            )
            (footerText as NSString).draw(with: footerRect, options: [.usesLineFragmentOrigin], attributes: footerAttributes, context: nil)
        }
        return image.pngData()
    }

    private func drawBackground(in context: CGContext, size: CGSize, palette: ThemePalette) {
        let colors = [palette.backgroundTop.cgColor, palette.backgroundBottom.cgColor] as CFArray
        let space = CGColorSpaceCreateDeviceRGB()
        if let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]) {
            context.drawLinearGradient(
                gradient,
                start: CGPoint(x: 0, y: 0),
                end: CGPoint(x: size.width, y: size.height),
                options: []
            )
        } else {
            context.setFillColor(palette.backgroundTop.cgColor)
            context.fill(CGRect(origin: .zero, size: size))
        }
    }

    private func drawCard(in context: CGContext, rect: CGRect, palette: ThemePalette) {
        let radius = min(rect.width, rect.height) * 0.045

        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: 12), blur: 30, color: UIColor.black.withAlphaComponent(0.16).cgColor)
        let shadowPath = UIBezierPath(roundedRect: rect, cornerRadius: radius)
        palette.cardBackground.setFill()
        shadowPath.fill()
        context.restoreGState()

        let cardPath = UIBezierPath(roundedRect: rect, cornerRadius: radius)
        palette.cardBackground.setFill()
        cardPath.fill()

        palette.cardBorder.setStroke()
        cardPath.lineWidth = 1
        cardPath.stroke()

        let accentHeight = max(4, rect.height * 0.01)
        let accentRect = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: accentHeight)
        let accentPath = UIBezierPath(
            roundedRect: accentRect,
            byRoundingCorners: [.topLeft, .topRight],
            cornerRadii: CGSize(width: radius, height: radius)
        )
        palette.accent.setFill()
        accentPath.fill()
    }

    // MARK: - Pagination

    private static func paginate(
        _ text: String,
        maxWidth: CGFloat,
        maxHeight: CGFloat,
        attributes: [NSAttributedString.Key: Any],
        maxPages: Int
    ) -> (pages: [String], truncated: Bool) {
        let pageLimit = max(1, min(maxPages, 12))
        var remaining = text
        var pages: [String] = []

        for _ in 0 ..< pageLimit {
            let trimmed = remaining.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                break
            }

            let (pageText, rest) = fittedChunk(
                text: trimmed,
                maxWidth: maxWidth,
                maxHeight: maxHeight,
                attributes: attributes
            )

            pages.append(pageText)
            remaining = rest
            if rest.isEmpty {
                break
            }
        }

        let truncated = !remaining.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return (pages, truncated)
    }

    private static func fittedChunk(
        text: String,
        maxWidth: CGFloat,
        maxHeight: CGFloat,
        attributes: [NSAttributedString.Key: Any]
    ) -> (chunk: String, rest: String) {
        if measuredHeight(for: text, width: maxWidth, attributes: attributes) <= maxHeight {
            return (text, "")
        }

        let totalCount = text.count
        var low = 1
        var high = totalCount
        var best = 1

        while low <= high {
            let mid = (low + high) / 2
            let candidate = Self.prefix(text, length: mid)
            if measuredHeight(for: candidate, width: maxWidth, attributes: attributes) <= maxHeight {
                best = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }

        let minimumReasonable = max(1, Int(Double(best) * 0.6))
        var resolvedLength = adjustedBreakLength(in: text, around: best, minLength: minimumReasonable)

        var chunk = Self.prefix(text, length: resolvedLength)
        while measuredHeight(for: chunk, width: maxWidth, attributes: attributes) > maxHeight, resolvedLength > 1 {
            resolvedLength -= 1
            chunk = Self.prefix(text, length: resolvedLength)
        }

        chunk = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
        if chunk.isEmpty {
            chunk = Self.prefix(text, length: 1)
            resolvedLength = 1
        }

        let remainderStart = text.index(text.startIndex, offsetBy: min(resolvedLength, totalCount))
        let rest = String(text[remainderStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (chunk, rest)
    }

    private static func adjustedBreakLength(in text: String, around proposed: Int, minLength: Int) -> Int {
        guard proposed > minLength else { return max(1, proposed) }
        let separators: Set<Character> = ["\n", "。", "！", "？", ".", "!", "?", "；", ";", "，", ",", "、", " "]

        var result = proposed
        while result > minLength {
            let checkPosition = result - 1
            let index = text.index(text.startIndex, offsetBy: checkPosition)
            if separators.contains(text[index]) {
                return result
            }
            result -= 1
        }
        return proposed
    }

    private static func measuredHeight(
        for text: String,
        width: CGFloat,
        attributes: [NSAttributedString.Key: Any]
    ) -> CGFloat {
        let rect = (text as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes,
            context: nil
        )
        return ceil(rect.height)
    }

    private static func prefix(_ text: String, length: Int) -> String {
        guard length > 0 else { return "" }
        let bounded = min(length, text.count)
        let index = text.index(text.startIndex, offsetBy: bounded)
        return String(text[..<index])
    }

    private static func bodyAttributes(font: UIFont, color: UIColor, width: CGFloat) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = max(6, width * 0.01)
        paragraph.paragraphSpacing = max(10, width * 0.012)

        return [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ]
    }

    // MARK: - Configuration

    private static func resolveConfig(from request: Request) -> RenderConfig {
        let defaultWidth = 1080
        let defaultAspect = (4, 5)

        let width = max(720, min(request.width ?? defaultWidth, 2000))
        let ratio = parseAspectRatio(request.aspectRatio) ?? defaultAspect
        let height = max(720, Int(round(CGFloat(width) * CGFloat(ratio.1) / CGFloat(ratio.0))))
        let maxPages = max(1, min(request.maxPages ?? 6, 12))

        return RenderConfig(
            theme: normalizedTheme(request.theme),
            width: width,
            height: height,
            maxPages: maxPages
        )
    }

    private static func normalizedTheme(_ raw: String?) -> String {
        let value = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch value {
        case "dark", "dark-mode":
            return "dark"
        case "paper", "light", "notes":
            return "notes"
        default:
            return "notes"
        }
    }

    private static func parseAspectRatio(_ raw: String?) -> (Int, Int)? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let parts = trimmed.split(separator: ":", maxSplits: 1).map { String($0) }
        guard parts.count == 2,
              let w = Int(parts[0]),
              let h = Int(parts[1]),
              w > 0,
              h > 0
        else {
            return nil
        }

        return (w, h)
    }

    private static func normalizedText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizedTitle(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(48))
    }

    private static func palette(for theme: String) -> ThemePalette {
        switch theme {
        case "dark":
            return ThemePalette(
                backgroundTop: UIColor(red: 0.12, green: 0.13, blue: 0.16, alpha: 1),
                backgroundBottom: UIColor(red: 0.05, green: 0.06, blue: 0.09, alpha: 1),
                cardBackground: UIColor(red: 0.13, green: 0.14, blue: 0.18, alpha: 0.96),
                cardBorder: UIColor.white.withAlphaComponent(0.12),
                accent: UIColor(red: 0.46, green: 0.67, blue: 1.0, alpha: 1),
                titleColor: UIColor.white,
                bodyColor: UIColor(red: 0.92, green: 0.93, blue: 0.95, alpha: 1),
                footerColor: UIColor.white.withAlphaComponent(0.64)
            )
        default:
            return ThemePalette(
                backgroundTop: UIColor(red: 0.97, green: 0.94, blue: 0.86, alpha: 1),
                backgroundBottom: UIColor(red: 0.96, green: 0.89, blue: 0.73, alpha: 1),
                cardBackground: UIColor(red: 1.0, green: 0.99, blue: 0.96, alpha: 0.96),
                cardBorder: UIColor(red: 0.89, green: 0.84, blue: 0.73, alpha: 1),
                accent: UIColor(red: 1.0, green: 0.75, blue: 0.33, alpha: 1),
                titleColor: UIColor(red: 0.20, green: 0.16, blue: 0.08, alpha: 1),
                bodyColor: UIColor(red: 0.24, green: 0.20, blue: 0.12, alpha: 1),
                footerColor: UIColor(red: 0.42, green: 0.34, blue: 0.18, alpha: 1)
            )
        }
    }
}
