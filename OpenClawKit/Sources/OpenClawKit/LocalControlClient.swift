import Foundation
import Network

public actor LocalControlClient {
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var connectionBox: ClientConnectionBox?
    private var pendingResponses: [String: CheckedContinuation<BridgeInvokeResponse, Error>] = [:]
    private var pendingPairChallenge: CheckedContinuation<LocalControlPairChallengePayload, Error>?
    private var localHello: LocalControlHello?
    private var remoteHello: LocalControlHello?
    private var peerInstanceId: String?
    private var pairedToken: String?

    public init() {}

    public func connect(to service: LocalControlDiscoveredService, localHello: LocalControlHello) async throws {
        let host = NWEndpoint.Host(service.host)
        guard let port = NWEndpoint.Port(rawValue: UInt16(service.port))
        else {
            throw NSError(domain: "LocalControl", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid service endpoint"])
        }
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let connection = NWConnection(host: host, port: port, using: parameters)
        let box = ClientConnectionBox(owner: self, connection: connection)
        connectionBox = box
        self.localHello = localHello
        box.start()
    }

    public func disconnect() {
        connectionBox?.connection.cancel()
        connectionBox = nil
        remoteHello = nil
        peerInstanceId = nil
        pairedToken = nil
        let pending = pendingResponses
        pendingResponses.removeAll()
        pendingPairChallenge?.resume(throwing: NSError(domain: "LocalControl", code: 2, userInfo: [NSLocalizedDescriptionKey: "Disconnected"]))
        pendingPairChallenge = nil
        for continuation in pending.values {
            continuation.resume(throwing: NSError(domain: "LocalControl", code: 2, userInfo: [NSLocalizedDescriptionKey: "Disconnected"]))
        }
    }

    public func beginPairing() async throws -> LocalControlPairChallengePayload {
        guard let localHello, let connectionBox else {
            throw NSError(domain: "LocalControl", code: 3, userInfo: [NSLocalizedDescriptionKey: "Not connected"])
        }
        let request = LocalControlPairRequest(controller: localHello)
        let text = try encodeText(request)
        connectionBox.connection.sendText(text)
        return try await withCheckedThrowingContinuation { continuation in
            pendingPairChallenge = continuation
        }
    }

    public func approvePairing(code: String) async throws -> LocalControlPairApprovedPayload {
        let params = LocalControlPairApproveParams(code: code)
        let request = try BridgeInvokeRequest(
            id: UUID().uuidString,
            command: LocalControlEvent.pairApproved.rawValue,
            paramsJSON: encodeJSONString(params)
        )
        let response = try await invoke(request)
        guard response.ok,
              let payload = response.payload,
              let data = payload.data(using: .utf8)
        else {
            throw NSError(domain: "LocalControl", code: 4, userInfo: [NSLocalizedDescriptionKey: response.error?.message ?? "Pairing failed"])
        }
        let approved = try decoder.decode(LocalControlPairApprovedPayload.self, from: data)
        remoteHello = approved.host
        peerInstanceId = approved.host.instanceId
        pairedToken = approved.token
        _ = await LocalControlPairingStore.shared.savePeer(
            instanceId: approved.host.instanceId,
            displayName: approved.host.displayName,
            token: approved.token
        )
        return approved
    }

    public func loadStoredPairing(instanceId: String) async {
        let peer = await LocalControlPairingStore.shared.peer(for: instanceId)
        pairedToken = peer?.token
        peerInstanceId = peer?.instanceId
    }

    public func invoke(_ request: BridgeInvokeRequest) async throws -> BridgeInvokeResponse {
        guard let connectionBox else {
            throw NSError(domain: "LocalControl", code: 5, userInfo: [NSLocalizedDescriptionKey: "Not connected"])
        }
        var enrichedRequest = request
        if let params = try decodeParams(from: request.paramsJSON) {
            var merged = params
            if let token = pairedToken {
                merged["token"] = token
            }
            if let controller = localHello?.instanceId {
                merged["controllerInstanceId"] = controller
            }
            enrichedRequest = try BridgeInvokeRequest(
                id: request.id,
                command: request.command,
                paramsJSON: encodeDictionaryJSON(merged)
            )
        } else if let token = pairedToken {
            enrichedRequest = try BridgeInvokeRequest(
                id: request.id,
                command: request.command,
                paramsJSON: encodeDictionaryJSON([
                    "token": token,
                    "controllerInstanceId": localHello?.instanceId ?? "",
                ])
            )
        }

        let text = try encodeText(enrichedRequest)
        connectionBox.connection.sendText(text)
        return try await withCheckedThrowingContinuation { continuation in
            pendingResponses[enrichedRequest.id] = continuation
        }
    }

    fileprivate func handle(text: String) async {
        guard let data = text.data(using: .utf8),
              let base = try? decoder.decode(BridgeBaseFrame.self, from: data)
        else {
            return
        }
        switch base.type {
        case "event":
            guard let frame = try? decoder.decode(BridgeEventFrame.self, from: data),
                  frame.event == LocalControlEvent.pairChallenge.rawValue,
                  let payloadJSON = frame.payloadJSON,
                  let payloadData = payloadJSON.data(using: .utf8),
                  let payload = try? decoder.decode(LocalControlPairChallengePayload.self, from: payloadData)
            else {
                return
            }
            pendingPairChallenge?.resume(returning: payload)
            pendingPairChallenge = nil
        case "invoke-res":
            guard let response = try? decoder.decode(BridgeInvokeResponse.self, from: data),
                  let continuation = pendingResponses.removeValue(forKey: response.id)
            else {
                return
            }
            continuation.resume(returning: response)
        default:
            break
        }
    }

    fileprivate func handleDisconnect() {
        disconnect()
    }

    private func decodeParams(from json: String?) throws -> [String: String]? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try JSONDecoder().decode([String: String].self, from: data)
    }

    private func encodeDictionaryJSON(_ value: [String: String]) throws -> String {
        let data = try encoder.encode(value)
        guard let text = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "LocalControl", code: 6, userInfo: [NSLocalizedDescriptionKey: "Encoding failed"])
        }
        return text
    }

    private func encodeJSONString<T: Encodable>(_ value: T) throws -> String {
        let data = try encoder.encode(value)
        guard let text = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "LocalControl", code: 6, userInfo: [NSLocalizedDescriptionKey: "Encoding failed"])
        }
        return text
    }

    private func encodeText<T: Encodable>(_ value: T) throws -> String {
        let data = try encoder.encode(value)
        guard let text = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "LocalControl", code: 6, userInfo: [NSLocalizedDescriptionKey: "Encoding failed"])
        }
        return text
    }
}

private final class ClientConnectionBox: NSObject, LocalControlConnectionDelegate, @unchecked Sendable {
    weak var owner: LocalControlClient?
    let connection: LocalControlConnection

    init(owner: LocalControlClient, connection: NWConnection) {
        self.owner = owner
        self.connection = LocalControlConnection(
            connection: connection,
            queueLabel: "ai.openava.local-control.client.connection.\(UUID().uuidString)"
        )
        super.init()
        self.connection.delegate = self
    }

    func start() {
        connection.start()
    }

    func localControlConnection(_: LocalControlConnection, didReceiveText text: String) {
        guard let owner else { return }
        Task { await owner.handle(text: text) }
    }

    func localControlConnectionDidClose(_: LocalControlConnection) {
        guard let owner else { return }
        Task { await owner.handleDisconnect() }
    }
}
