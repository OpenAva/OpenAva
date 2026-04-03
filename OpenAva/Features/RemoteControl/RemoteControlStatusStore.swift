import Foundation
import Observation

@MainActor
@Observable
final class RemoteControlStatusStore {
    static let shared = RemoteControlStatusStore()

    private(set) var advertisedPort: UInt16?
    private(set) var advertiseStatusText: String?
    private(set) var advertiseRegistrationText: String?
    private(set) var currentPairCode: String?
    private(set) var currentPairPeerName: String?
    private(set) var lastUpdatedAt: Date?

    private init() {}

    func updateAdvertisedPort(_ port: UInt16?) {
        advertisedPort = port
        lastUpdatedAt = Date()
    }

    func updateAdvertiseStatus(_ text: String?) {
        advertiseStatusText = text
        lastUpdatedAt = Date()
    }

    func updateAdvertiseRegistrationStatus(_ text: String?) {
        advertiseRegistrationText = text
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

    func clearAdvertiseState() {
        advertisedPort = nil
        advertiseStatusText = nil
        advertiseRegistrationText = nil
        lastUpdatedAt = Date()
    }
}
