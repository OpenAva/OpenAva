import ChatUI
import Foundation

enum AgentMemorySurfacingSupport {
    static let metadataKey = "dynamicMemorySurfacedSlugs"

    static func encodeMetadataValue(for slugs: Set<String>) -> String? {
        let normalized = normalizedSlugs(slugs).sorted()
        guard !normalized.isEmpty else { return nil }
        return normalized.joined(separator: ",")
    }

    static func decodeMetadataValue(_ rawValue: String?) -> Set<String> {
        guard let rawValue else { return [] }
        return normalizedSlugs(
            rawValue.split(separator: ",").map(String.init)
        )
    }

    static func surfacedSlugs(from messages: [ConversationMessage]) -> Set<String> {
        messages.reduce(into: Set<String>()) { result, message in
            result.formUnion(decodeMetadataValue(message.metadata[metadataKey]))
            if message.role == .system {
                result.formUnion(surfacedSlugs(fromRenderedSection: message.textContent))
            }
        }
    }

    static func surfacedSlugs(from persistedConversation: [SubAgentTaskStore.PersistedConversationMessage]) -> Set<String> {
        persistedConversation.reduce(into: Set<String>()) { result, message in
            guard message.role == .system else { return }
            result.formUnion(surfacedSlugs(fromRenderedSection: message.text))
        }
    }

    static func surfacedSlugs(fromRenderedSection text: String?) -> Set<String> {
        guard let text = nonEmpty(text), text.contains("## Dynamic Memory Recall") else {
            return []
        }

        let pattern = #"slug=([A-Za-z0-9-]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }

        let fullRange = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, options: [], range: fullRange)
        let slugs = matches.compactMap { match -> String? in
            guard match.numberOfRanges >= 2,
                  let range = Range(match.range(at: 1), in: text)
            else {
                return nil
            }
            return String(text[range])
        }
        return normalizedSlugs(slugs)
    }

    static func normalizedSlugs<S: Sequence>(_ slugs: S) -> Set<String> where S.Element == String {
        Set(slugs.compactMap(normalizedSlug))
    }

    private static func normalizedSlug(_ rawValue: String) -> String? {
        let trimmed = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !trimmed.isEmpty else { return nil }

        let sanitized = trimmed
            .replacingOccurrences(of: #"[^a-z0-9-]+"#, with: "-", options: .regularExpression)
            .replacingOccurrences(of: #"-+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return sanitized.isEmpty ? nil : sanitized
    }

    private static func nonEmpty(_ rawValue: String?) -> String? {
        guard let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty
        else {
            return nil
        }
        return rawValue
    }
}
