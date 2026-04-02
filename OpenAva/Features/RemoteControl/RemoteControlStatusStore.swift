import Foundation
import Observation

@MainActor
@Observable
final class RemoteControlStatusStore {
    static let shared = RemoteControlStatusStore()

    private(set) var advertisedPort: UInt16?
    private(set) var currentPairCode: String?
    private(set) var currentPairPeerName: String?
    private(set) var lastUpdatedAt: Date?

    private init() {}

    func updateAdvertisedPort(_ port: UInt16?) {
        advertisedPort = port
        lastUpdatedAt = Date()
    }

    func updatePairingCode(_ code: String?, peerName: String?) {
        currentPairCode = code
        currentPairPeerName = peerName
        lastUpdatedAt = Date()
    }

    func clearPairingCode() {
        currentPairCode = nil
        currentPairPeerName = nil
        lastUpdatedAt = Date()
    }
}
