//
//  MarkdownMediaParser.swift
//  ChatUI
//
//  Splits markdown into plain markdown segments and inline media segments.
//

import Foundation

enum MarkdownMediaParser {
    private struct CandidateMatch {
        let range: Range<String.Index>
        let payload: MarkdownMediaPayload
    }

    private static let markdownImageRegex: NSRegularExpression = {
        let pattern = #"!\[([^\]]*)\]\(\s*(?:<([^>]+)>|([^\s)]+))(?:\s+(?:"([^"]*)"|'([^']*)'))?\s*\)"#
        return try! NSRegularExpression(pattern: pattern)
    }()

    private static let htmlImageRegex: NSRegularExpression = try! NSRegularExpression(pattern: #"(?is)<img\b[^>]*>"#)

    private static let htmlVideoRegex: NSRegularExpression = {
        let pattern = #"(?is)<video\b[^>]*>.*?</video>|<video\b[^>]*/?>"#
        return try! NSRegularExpression(pattern: pattern)
    }()

    private static let htmlAttributeRegex: NSRegularExpression = {
        let pattern = #"(?i)\b([a-zA-Z_:][-a-zA-Z0-9_:.]*)\s*=\s*(?:"([^"]*)"|'([^']*)')"#
        return try! NSRegularExpression(pattern: pattern)
    }()

    private static let fencedCodeBlockRegex: NSRegularExpression = {
        let pattern = #"(?ism)(^|\n)[ \t]*(```|~~~).*?\n[ \t]*\2[ \t]*(?=\n|$)"#
        return try! NSRegularExpression(pattern: pattern)
    }()

    private static let inlineCodeRegex: NSRegularExpression = try! NSRegularExpression(pattern: #"`[^`\n]+`"#)

    static func parseSegments(from markdown: String) -> [ParsedMessageSegment] {
        let ignoredRanges = ignoredRanges(in: markdown)
        let matches = collectMatches(in: markdown, ignoredRanges: ignoredRanges)
        guard !matches.isEmpty else {
            return [.markdown(markdown)]
        }

        var segments: [ParsedMessageSegment] = []
        var cursor = markdown.startIndex

        for match in matches {
            guard match.range.lowerBound >= cursor else { continue }

            if cursor < match.range.lowerBound {
                segments.append(.markdown(String(markdown[cursor ..< match.range.lowerBound])))
            }

            segments.append(.media(match.payload))
            cursor = match.range.upperBound
        }

        if cursor < markdown.endIndex {
            segments.append(.markdown(String(markdown[cursor...])))
        }

        return segments
    }

    private static func collectMatches(
        in markdown: String,
        ignoredRanges: [Range<String.Index>]
    ) -> [CandidateMatch] {
        let nsRange = NSRange(markdown.startIndex ..< markdown.endIndex, in: markdown)
        var candidates: [CandidateMatch] = []

        candidates += markdownImageRegex.matches(in: markdown, options: [], range: nsRange).compactMap { match in
            guard let fullRange = Range(match.range, in: markdown),
                  !intersectsIgnoredRange(fullRange, ignoredRanges: ignoredRanges),
                  let url = capturedValue(in: markdown, match: match, groups: [2, 3]),
                  let normalizedURL = normalizedMediaURL(from: url)
            else {
                return nil
            }

            let altText = capturedValue(in: markdown, match: match, groups: [1])
            return CandidateMatch(
                range: fullRange,
                payload: .init(kind: .image, url: normalizedURL, altText: altText)
            )
        }

        candidates += htmlImageRegex.matches(in: markdown, options: [], range: nsRange).compactMap { match in
            guard let fullRange = Range(match.range, in: markdown),
                  !intersectsIgnoredRange(fullRange, ignoredRanges: ignoredRanges)
            else {
                return nil
            }

            let tag = String(markdown[fullRange])
            guard let url = htmlAttribute(named: "src", in: tag),
                  let normalizedURL = normalizedMediaURL(from: url)
            else {
                return nil
            }

            let altText = htmlAttribute(named: "alt", in: tag)
            return CandidateMatch(
                range: fullRange,
                payload: .init(kind: .image, url: normalizedURL, altText: altText)
            )
        }

        candidates += htmlVideoRegex.matches(in: markdown, options: [], range: nsRange).compactMap { match in
            guard let fullRange = Range(match.range, in: markdown),
                  !intersectsIgnoredRange(fullRange, ignoredRanges: ignoredRanges)
            else {
                return nil
            }

            let tag = String(markdown[fullRange])
            let url = htmlAttribute(named: "src", in: tag)
                ?? htmlAttribute(named: "src", in: firstHTMLTag(named: "source", in: tag) ?? "")
            guard let url, let normalizedURL = normalizedMediaURL(from: url) else {
                return nil
            }

            let altText = htmlAttribute(named: "title", in: tag)
                ?? htmlAttribute(named: "aria-label", in: tag)
            return CandidateMatch(
                range: fullRange,
                payload: .init(kind: .video, url: normalizedURL, altText: altText)
            )
        }

        candidates.sort { lhs, rhs in
            if lhs.range.lowerBound == rhs.range.lowerBound {
                return lhs.range.upperBound < rhs.range.upperBound
            }
            return lhs.range.lowerBound < rhs.range.lowerBound
        }

        var deduplicated: [CandidateMatch] = []
        for candidate in candidates {
            if let last = deduplicated.last, candidate.range.lowerBound < last.range.upperBound {
                continue
            }
            deduplicated.append(candidate)
        }
        return deduplicated
    }

    private static func ignoredRanges(in markdown: String) -> [Range<String.Index>] {
        let nsRange = NSRange(markdown.startIndex ..< markdown.endIndex, in: markdown)
        let regexes = [fencedCodeBlockRegex, inlineCodeRegex]
        return regexes.flatMap { regex in
            regex.matches(in: markdown, options: [], range: nsRange).compactMap { Range($0.range, in: markdown) }
        }
        .sorted { $0.lowerBound < $1.lowerBound }
    }

    private static func intersectsIgnoredRange(
        _ range: Range<String.Index>,
        ignoredRanges: [Range<String.Index>]
    ) -> Bool {
        ignoredRanges.contains { ignoredRange in
            range.overlaps(ignoredRange)
        }
    }

    private static func capturedValue(
        in markdown: String,
        match: NSTextCheckingResult,
        groups: [Int]
    ) -> String? {
        for group in groups where group < match.numberOfRanges {
            guard let range = Range(match.range(at: group), in: markdown) else { continue }
            let value = String(markdown[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private static func normalizedMediaURL(from rawValue: String) -> String? {
        let trimmed = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
        guard !trimmed.isEmpty, let url = URL(string: trimmed), url.scheme != nil else {
            return nil
        }
        return url.absoluteString
    }

    private static func htmlAttribute(named attributeName: String, in html: String) -> String? {
        let nsRange = NSRange(html.startIndex ..< html.endIndex, in: html)
        for match in htmlAttributeRegex.matches(in: html, options: [], range: nsRange) {
            guard let nameRange = Range(match.range(at: 1), in: html) else { continue }
            let name = String(html[nameRange]).lowercased()
            guard name == attributeName.lowercased() else { continue }
            return capturedValue(in: html, match: match, groups: [2, 3])
        }
        return nil
    }

    private static func firstHTMLTag(named name: String, in html: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "(?is)<\(name)\\b[^>]*>") else {
            return nil
        }
        let nsRange = NSRange(html.startIndex ..< html.endIndex, in: html)
        guard let match = regex.firstMatch(in: html, options: [], range: nsRange),
              let range = Range(match.range, in: html)
        else {
            return nil
        }
        return String(html[range])
    }
}
