//
//  MapMarkdownParser.swift
//  ChatUI
//
//  Splits markdown into plain markdown segments and map segments.
//

import Foundation

enum MapMarkdownParser {
    private static let mapCodeBlockRegex: NSRegularExpression = {
        // Match fenced code blocks like ```map ... ``` and keep inner JSON payload.
        // Supports optional indentation and both LF/CRLF line endings.
        let pattern = "(?ism)^[ \\t]*```map(?:[ \\t]+[^\\r\\n]*)?\\r?\\n(.*?)(?:\\r?\\n)?[ \\t]*```[ \\t]*(?=\\r?\\n|$)"
        return try! NSRegularExpression(pattern: pattern)
    }()

    static func parseSegments(from markdown: String) -> [ParsedMessageSegment] {
        let nsRange = NSRange(markdown.startIndex ..< markdown.endIndex, in: markdown)
        let matches = mapCodeBlockRegex.matches(in: markdown, options: [], range: nsRange)
        guard !matches.isEmpty else {
            return [.markdown(markdown)]
        }

        var segments: [ParsedMessageSegment] = []
        var cursor = markdown.startIndex

        for match in matches {
            guard let fullRange = Range(match.range, in: markdown),
                  let payloadRange = Range(match.range(at: 1), in: markdown)
            else {
                continue
            }

            if cursor < fullRange.lowerBound {
                segments.append(.markdown(String(markdown[cursor ..< fullRange.lowerBound])))
            }

            let rawBlock = String(markdown[fullRange])
            let payload = String(markdown[payloadRange]).trimmingCharacters(in: .whitespacesAndNewlines)

            if let spec = decodeSpec(from: payload), spec.isValid {
                segments.append(.map(spec: spec, rawBlock: rawBlock))
            } else {
                // Invalid map JSON falls back to normal markdown rendering.
                segments.append(.markdown(rawBlock))
            }

            cursor = fullRange.upperBound
        }

        if cursor < markdown.endIndex {
            segments.append(.markdown(String(markdown[cursor...])))
        }

        return segments
    }

    private static func decodeSpec(from json: String) -> MapSpec? {
        guard let data = json.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        return try? decoder.decode(MapSpec.self, from: data)
    }
}
