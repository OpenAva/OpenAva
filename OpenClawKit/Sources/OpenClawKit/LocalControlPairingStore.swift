import Foundation

public struct LocalControlPairingPeer: Codable, Sendable, Equatable {
    public var instanceId: String
    public var displayName: String
    public var token: String
    public var pairedAtMs: Int64

    public init(instanceId: String, displayName: String, token: String, pairedAtMs: Int64) {
        self.instanceId = instanceId
        self.displayName = displayName
        self.token = token
        self.pairedAtMs = pairedAtMs
    }
}

public actor LocalControlPairingStore {
    public static let shared = LocalControlPairingStore()

    private let defaults: UserDefaults
    private let peersKey = "openava.localControl.pairedPeers.v1"
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func allPeers() -> [LocalControlPairingPeer] {
        loadPeers()
    }

    public func peer(for instanceId: String) -> LocalControlPairingPeer? {
        loadPeers().first { $0.instanceId == instanceId }
    }

    @discardableResult
    public func savePeer(instanceId: String, displayName: String, token: String) -> LocalControlPairingPeer {
        var peers = loadPeers().filter { $0.instanceId != instanceId }
        let peer = LocalControlPairingPeer(
            instanceId: instanceId,
            displayName: displayName,
            token: token,
            pairedAtMs: Int64(Date().timeIntervalSince1970 * 1000)
        )
        peers.append(peer)
        persist(peers)
        return peer
    }

    public func removePeer(instanceId: String) {
        let peers = loadPeers().filter { $0.instanceId != instanceId }
        persist(peers)
    }

    public func isAuthorized(instanceId: String, token: String?) -> Bool {
        guard let token else { return false }
        return peer(for: instanceId)?.token == token
    }

    private func loadPeers() -> [LocalControlPairingPeer] {
        guard let data = defaults.data(forKey: peersKey),
              let peers = try? decoder.decode([LocalControlPairingPeer].self, from: data)
        else {
            return []
        }
        return peers
    }

    private func persist(_ peers: [LocalControlPairingPeer]) {
        guard !peers.isEmpty else {
            defaults.removeObject(forKey: peersKey)
            return
        }
        guard let data = try? encoder.encode(peers) else { return }
        defaults.set(data, forKey: peersKey)
    }
}
