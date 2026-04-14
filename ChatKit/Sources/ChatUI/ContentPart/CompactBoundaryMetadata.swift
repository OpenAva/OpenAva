import Foundation

public enum ConversationMarkers {
    public static let compactBoundaryPrefix = "[Compact Boundary]"
    public static let contextSummaryPrefix = "[Context Summary]"
    public static let compactAttachmentPrefix = "[Compact Attachment]"
    public static let toolUseSummaryPrefix = "[Tool Use Summary]"

    public static func isContextSummary(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(contextSummaryPrefix)
    }

    public static func isToolUseSummary(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(toolUseSummaryPrefix)
    }

    public static func stripContextSummaryPrefix(from text: String) -> String {
        guard isContextSummary(text) else { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        return text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: contextSummaryPrefix, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum PartialCompactDirection: String, Sendable {
    case from
    case upTo = "up_to"
}

public struct CompactBoundaryMetadata: Codable, Sendable, Equatable {
    public struct PreservedSegment: Codable, Sendable, Equatable {
        public let headUUID: String
        public let anchorUUID: String
        public let tailUUID: String

        public init(headUUID: String, anchorUUID: String, tailUUID: String) {
            self.headUUID = headUUID
            self.anchorUUID = anchorUUID
            self.tailUUID = tailUUID
        }

        enum CodingKeys: String, CodingKey {
            case headUUID = "headUuid"
            case anchorUUID = "anchorUuid"
            case tailUUID = "tailUuid"
        }
    }

    public let trigger: String
    public let preTokens: Int
    public let userContext: String?
    public let messagesSummarized: Int?
    public let preCompactDiscoveredTools: [String]?
    public let preservedSegment: PreservedSegment?

    public init(
        trigger: String,
        preTokens: Int,
        userContext: String? = nil,
        messagesSummarized: Int? = nil,
        preCompactDiscoveredTools: [String]? = nil,
        preservedSegment: PreservedSegment? = nil
    ) {
        self.trigger = trigger
        self.preTokens = preTokens
        self.userContext = userContext
        self.messagesSummarized = messagesSummarized
        self.preCompactDiscoveredTools = preCompactDiscoveredTools
        self.preservedSegment = preservedSegment
    }
}

public extension ConversationMessage {
    var isCompactionSummary: Bool {
        metadata["isCompactionSummary"] == "true"
    }

    var isCompactAttachment: Bool {
        metadata["isCompactAttachment"] == "true" || subtype == "compact_attachment"
    }

    var subtype: String? {
        get { metadata["subtype"] }
        set { metadata["subtype"] = newValue }
    }

    var compactBoundaryMetadata: CompactBoundaryMetadata? {
        get {
            guard let raw = metadata["compactBoundaryMetadata"],
                  let data = raw.data(using: .utf8)
            else {
                return nil
            }
            return try? JSONDecoder().decode(CompactBoundaryMetadata.self, from: data)
        }
        set {
            guard let newValue else {
                metadata.removeValue(forKey: "compactBoundaryMetadata")
                return
            }
            guard let data = try? JSONEncoder().encode(newValue),
                  let raw = String(data: data, encoding: .utf8)
            else {
                metadata.removeValue(forKey: "compactBoundaryMetadata")
                return
            }
            metadata["compactBoundaryMetadata"] = raw
        }
    }

    var isCompactBoundary: Bool {
        subtype == "compact_boundary"
    }
}
