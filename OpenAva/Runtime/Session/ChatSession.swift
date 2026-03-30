import Foundation

/// Lightweight local session record used in the UI session list.
/// Derived from TranscriptStorageProvider's persisted session metadata.
struct ChatSession: Equatable, Identifiable {
    var id: String {
        key
    }

    let key: String
    let displayName: String
    /// Unix timestamp in milliseconds of the last update.
    let updatedAt: Int64
}
