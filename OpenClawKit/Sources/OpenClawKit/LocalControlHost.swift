import Foundation
import Network
import OpenClawProtocol

public struct LocalControlHostInfo: Sendable {
    public var hello: LocalControlHello

    public init(hello: LocalControlHello) {
        self.hello = hello
    }
}

public struct LocalControlHostRequestContext: Sendable {
    public var peerInstanceId: String

    public init(peerInstanceId: String) {
        self.peerInstanceId = peerInstanceId
    }
}

public struct LocalControlHostPairChallenge: Sendable {
    public var peer: LocalControlHello
    public var code: String
    public var expiresAtMs: Int64

    public init(peer: LocalControlHello, code: String, expiresAtMs: Int64) {
        self.peer = peer
        self.code = code
        self.expiresAtMs = expiresAtMs
    }
}

public actor LocalControlHost {
    public typealias RequestHandler = @Sendable (BridgeInvokeRequest, LocalControlHostRequestContext) async -> BridgeInvokeResponse
    public typealias PairChallengeHandler = @Sendable (LocalControlHostPairChallenge) async -> Void

    private struct PairingState {
        var peer: LocalControlHello
        var code: String
        var expiresAtMs: Int64
    }

    private let advertiser = LocalControlAdvertiser()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var connections: [ObjectIdentifier: HostConnectionBox] = [:]
    private var requestHandler: RequestHandler?
    private var pairChallengeHandler: PairChallengeHandler?
    private var hostInfo: LocalControlHostInfo?
    private var pairingStates: [String: PairingState] = [:]
    private var onReadyToAdvertise: (@Sendable (UInt16) async -> Void)?

    public init() {}

    public func start(
        hostInfo: LocalControlHostInfo,
        requestHandler: @escaping RequestHandler,
        pairChallengeHandler: PairChallengeHandler? = nil,
        onReadyToAdvertise: (@Sendable (UInt16) async -> Void)? = nil
    ) throws {
        guard self.hostInfo == nil else { return }
        self.hostInfo = hostInfo
        self.requestHandler = requestHandler
        self.pairChallengeHandler = pairChallengeHandler
        self.onReadyToAdvertise = onReadyToAdvertise
        let config = LocalControlTransportConfig(serviceName: hostInfo.hello.displayName)
        try advertiser.start(config: config) { [weak self] connection in
            guard let self else { return }
            Task { await self.accept(connection: connection) }
        }
        if let port = advertiser.port {
            Task { await onReadyToAdvertise?(port) }
        }
    }

    public func stop() {
        advertiser.stop()
        for box in connections.values {
            box.connection.cancel()
        }
        connections.removeAll()
        pairingStates.removeAll()
        hostInfo = nil
        requestHandler = nil
        pairChallengeHandler = nil
        onReadyToAdvertise = nil
    }

    private func accept(connection: NWConnection) {
        let box = HostConnectionBox(owner: self, connection: connection)
        let id = ObjectIdentifier(box)
        connections[id] = box
        box.start()
    }

    fileprivate func removeConnection(_ box: HostConnectionBox) {
        connections.removeValue(forKey: ObjectIdentifier(box))
    }

    fileprivate func handle(text: String, from box: HostConnectionBox) async {
        guard let data = text.data(using: .utf8),
              let base = try? decoder.decode(BridgeBaseFrame.self, from: data)
        else {
            await box.send(response: .init(id: UUID().uuidString, ok: false, error: .init(code: .invalidRequest, message: "INVALID_REQUEST: invalid frame")))
            return
        }

        switch base.type {
        case "pair-request":
            await handlePairRequest(data: data, from: box)
        case "invoke":
            await handleInvoke(data: data, from: box)
        default:
            await box.send(response: .init(id: UUID().uuidString, ok: false, error: .init(code: .invalidRequest, message: "INVALID_REQUEST: unsupported frame type")))
        }
    }

    private func handlePairRequest(data: Data, from box: HostConnectionBox) async {
        guard let request = try? decoder.decode(LocalControlPairRequest.self, from: data) else {
            await box.send(response: .init(id: UUID().uuidString, ok: false, error: .init(code: .invalidRequest, message: "INVALID_REQUEST: invalid pair request")))
            return
        }
        let code = Self.generatePairCode()
        let expiresAtMs = Int64(Date().timeIntervalSince1970 * 1000) + 120_000
        pairingStates[request.controller.instanceId] = PairingState(peer: request.controller, code: code, expiresAtMs: expiresAtMs)
        box.peer = request.controller
        let payload = LocalControlPairChallengePayload(expiresAtMs: expiresAtMs)
        await box.send(event: .pairChallenge, payload: payload)
        await pairChallengeHandler?(.init(peer: request.controller, code: code, expiresAtMs: expiresAtMs))
    }

    private func handleInvoke(data: Data, from box: HostConnectionBox) async {
        guard let request = try? decoder.decode(BridgeInvokeRequest.self, from: data) else {
            await box.send(response: .init(id: UUID().uuidString, ok: false, error: .init(code: .invalidRequest, message: "INVALID_REQUEST: invalid invoke request")))
            return
        }
        switch request.command {
        case LocalControlEvent.pairApproved.rawValue:
            await handlePairApprove(request: request, from: box)
        default:
            let envelope = decodeEnvelope(from: request.paramsJSON)
            let peerInstanceId = box.peer?.instanceId ?? envelope.controllerInstanceId
            guard let peerInstanceId else {
                await box.send(response: .init(id: request.id, ok: false, error: .init(code: .notPaired, message: "NOT_PAIRED: pairing required")))
                return
            }
            let token = box.token?.trimmingCharacters(in: .whitespacesAndNewlines) ?? envelope.token
            guard await LocalControlPairingStore.shared.isAuthorized(instanceId: peerInstanceId, token: token) else {
                await box.send(response: .init(id: request.id, ok: false, error: .init(code: .unauthorized, message: "UNAUTHORIZED: invalid local control token")))
                return
            }
            box.token = token
            guard let requestHandler else {
                await box.send(response: .init(id: request.id, ok: false, error: .init(code: .unavailable, message: "UNAVAILABLE: local control handler unavailable")))
                return
            }
            let sanitizedRequest = BridgeInvokeRequest(
                id: request.id,
                command: request.command,
                paramsJSON: envelope.cleanedParamsJSON
            )
            let response = await requestHandler(sanitizedRequest, .init(peerInstanceId: peerInstanceId))
            await box.send(response: response)
        }
    }

    private func handlePairApprove(request: BridgeInvokeRequest, from box: HostConnectionBox) async {
        guard let peer = box.peer else {
            await box.send(response: .init(id: request.id, ok: false, error: .init(code: .notPaired, message: "NOT_PAIRED: missing pair request")))
            return
        }
        guard let paramsJSON = request.paramsJSON,
              let data = paramsJSON.data(using: .utf8),
              let params = try? decoder.decode(LocalControlPairApproveParams.self, from: data),
              let state = pairingStates[peer.instanceId]
        else {
            await box.send(response: .init(id: request.id, ok: false, error: .init(code: .invalidRequest, message: "INVALID_REQUEST: invalid pair approval")))
            return
        }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        guard now <= state.expiresAtMs, params.code == state.code else {
            await box.send(response: .init(id: request.id, ok: false, error: .init(code: .unauthorized, message: "UNAUTHORIZED: invalid pairing code")))
            return
        }

        let token = UUID().uuidString.lowercased()
        _ = await LocalControlPairingStore.shared.savePeer(
            instanceId: peer.instanceId,
            displayName: peer.displayName,
            token: token
        )
        pairingStates.removeValue(forKey: peer.instanceId)
        box.token = token
        guard let hostHello = hostInfo?.hello else {
            await box.send(response: .init(id: request.id, ok: false, error: .init(code: .unavailable, message: "UNAVAILABLE: host info missing")))
            return
        }
        let payload = LocalControlPairApprovedPayload(token: token, host: hostHello)
        await box.send(response: .init(id: request.id, ok: true, payload: Self.encodeJSON(payload), error: nil))
    }

    private static func generatePairCode() -> String {
        let value = Int.random(in: 0 ... 999_999)
        return String(format: "%06d", value)
    }

    private func decodeEnvelope(from paramsJSON: String?) -> RequestEnvelope {
        guard let paramsJSON,
              let data = paramsJSON.data(using: .utf8),
              var params = try? decoder.decode([String: String].self, from: data)
        else {
            return .init(token: nil, controllerInstanceId: nil, cleanedParamsJSON: paramsJSON)
        }
        let token = params.removeValue(forKey: "token")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let controllerInstanceId = params.removeValue(forKey: "controllerInstanceId")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedParamsJSON: String?
        if params.isEmpty {
            cleanedParamsJSON = nil
        } else {
            cleanedParamsJSON = Self.encodeJSON(params)
        }
        return .init(token: token, controllerInstanceId: controllerInstanceId, cleanedParamsJSON: cleanedParamsJSON)
    }

    private static func encodeJSON<T: Encodable>(_ value: T) -> String? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

private struct RequestEnvelope {
    var token: String?
    var controllerInstanceId: String?
    var cleanedParamsJSON: String?
}

private final class HostConnectionBox: NSObject, LocalControlConnectionDelegate, @unchecked Sendable {
    weak var owner: LocalControlHost?
    let connection: LocalControlConnection
    var peer: LocalControlHello?
    var token: String?

    init(owner: LocalControlHost, connection: NWConnection) {
        self.owner = owner
        self.connection = LocalControlConnection(
            connection: connection,
            queueLabel: "ai.openava.local-control.host.connection.\(UUID().uuidString)"
        )
        super.init()
        self.connection.delegate = self
    }

    func start() {
        connection.start()
    }

    func send(response: BridgeInvokeResponse) async {
        guard let text = Self.encodeJSON(response) else { return }
        connection.sendText(text)
    }

    func send<T: Encodable>(event: LocalControlEvent, payload: T) async {
        let payloadJSON = Self.encodeJSON(payload)
        let frame = BridgeEventFrame(event: event.rawValue, payloadJSON: payloadJSON)
        guard let text = Self.encodeJSON(frame) else { return }
        connection.sendText(text)
    }

    func localControlConnection(_: LocalControlConnection, didReceiveText text: String) {
        guard let owner else { return }
        Task { await owner.handle(text: text, from: self) }
    }

    func localControlConnectionDidClose(_: LocalControlConnection) {
        guard let owner else { return }
        Task { await owner.removeConnection(self) }
    }

    private static func encodeJSON<T: Encodable>(_ value: T) -> String? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
