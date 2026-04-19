import ChatUI
import Foundation

struct QueryResult {
    let finishReason: FinishReason
    let totalTurns: Int
    let totalToolCalls: Int
}
