import Foundation

struct QueryResult {
    let finishReason: FinishReason
    let totalTurns: Int
    let totalToolCalls: Int
    let didCompact: Bool

    init(
        finishReason: FinishReason,
        totalTurns: Int,
        totalToolCalls: Int,
        didCompact: Bool = false
    ) {
        self.finishReason = finishReason
        self.totalTurns = totalTurns
        self.totalToolCalls = totalToolCalls
        self.didCompact = didCompact
    }
}
