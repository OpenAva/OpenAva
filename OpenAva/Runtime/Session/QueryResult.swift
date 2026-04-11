import ChatUI
import Foundation

struct QueryResult {
    let finishReason: FinishReason
    let totalTurns: Int
    let totalToolCalls: Int
    let didCompact: Bool
    let interruptReason: String?

    init(
        finishReason: FinishReason,
        totalTurns: Int,
        totalToolCalls: Int,
        didCompact: Bool = false,
        interruptReason: String? = nil
    ) {
        self.finishReason = finishReason
        self.totalTurns = totalTurns
        self.totalToolCalls = totalToolCalls
        self.didCompact = didCompact
        self.interruptReason = interruptReason
    }
}
