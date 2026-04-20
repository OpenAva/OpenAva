import Foundation

public enum PartialCompactDirection: String, Sendable {
    case from
    case upTo = "up_to"
}

public struct CompactBoundaryMetadata: Codable, Sendable, Equatable {
    public struct PreservedSegment: Codable, Sendable, Equatable {
        public let headUuid: String
        public let anchorUuid: String
        public let tailUuid: String

        public init(headUuid: String, anchorUuid: String, tailUuid: String) {
            self.headUuid = headUuid
            self.anchorUuid = anchorUuid
            self.tailUuid = tailUuid
        }
    }

    public let trigger: String
    public let preTokens: Int
    public let userContext: String?
    public let messagesSummarized: Int?
    public let preCompactDiscoveredTools: [String]?
    public let autoCompactThreshold: Int?
    public let querySource: String?
    public let isRecompactionInChain: Bool?
    public let turnsSincePreviousCompact: Int?
    public let previousCompactTurnId: String?
    public let preservedSegment: PreservedSegment?

    public init(
        trigger: String,
        preTokens: Int,
        userContext: String? = nil,
        messagesSummarized: Int? = nil,
        preCompactDiscoveredTools: [String]? = nil,
        autoCompactThreshold: Int? = nil,
        querySource: String? = nil,
        isRecompactionInChain: Bool? = nil,
        turnsSincePreviousCompact: Int? = nil,
        previousCompactTurnId: String? = nil,
        preservedSegment: PreservedSegment? = nil
    ) {
        self.trigger = trigger
        self.preTokens = preTokens
        self.userContext = userContext
        self.messagesSummarized = messagesSummarized
        self.preCompactDiscoveredTools = preCompactDiscoveredTools
        self.autoCompactThreshold = autoCompactThreshold
        self.querySource = querySource
        self.isRecompactionInChain = isRecompactionInChain
        self.turnsSincePreviousCompact = turnsSincePreviousCompact
        self.previousCompactTurnId = previousCompactTurnId
        self.preservedSegment = preservedSegment
    }
}

public extension ConversationMessage {
    var isCompactSummary: Bool {
        metadata["isCompactSummary"] == "true"
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

public extension Array where Element == ConversationMessage {
    func findLastCompactBoundaryIndex() -> Int? {
        lastIndex(where: { $0.isCompactBoundary })
    }

    func getMessagesAfterCompactBoundary(includingBoundary: Bool = true) -> [ConversationMessage] {
        guard let boundaryIndex = findLastCompactBoundaryIndex() else {
            return self
        }

        let startIndex = includingBoundary ? boundaryIndex : index(after: boundaryIndex)
        guard startIndex < endIndex else {
            return []
        }

        return Array(self[startIndex...])
    }
}
