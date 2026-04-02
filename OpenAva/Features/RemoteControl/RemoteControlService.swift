import Foundation
import OpenClawKit

@MainActor
final class RemoteControlService {
    static let shared = RemoteControlService()

    private let host = LocalControlHost()
    private var started = false

    private init() {}

    func startIfNeeded() {
        #if targetEnvironment(macCatalyst)
            guard !started else { return }
            started = true
            let hello = LocalControlHello(
                role: .host,
                instanceId: InstanceIdentity.instanceId,
                displayName: InstanceIdentity.displayName,
                platform: InstanceIdentity.platformString,
                deviceFamily: InstanceIdentity.deviceFamily,
                modelIdentifier: InstanceIdentity.modelIdentifier,
                appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
                appBuild: (Bundle.main.infoDictionary?["CFBundleVersion"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            Task {
                do {
                    try await host.start(
                        hostInfo: .init(hello: hello),
                        requestHandler: { request, _ in
                            await RemoteControlService.handle(request: request)
                        },
                        pairChallengeHandler: { challenge in
                            await MainActor.run {
                                RemoteControlCoordinator.shared.pairCodeDidUpdate(challenge.code, peerName: challenge.peer.displayName)
                            }
                        },
                        onReadyToAdvertise: { port in
                            await MainActor.run {
                                RemoteControlStatusStore.shared.updateAdvertisedPort(port)
                            }
                        }
                    )
                } catch {
                    started = false
                    RemoteControlStatusStore.shared.updateAdvertisedPort(nil)
                }
            }
        #endif
    }

    func stop() {
        Task {
            await host.stop()
            await MainActor.run {
                self.started = false
                RemoteControlStatusStore.shared.updateAdvertisedPort(nil)
                RemoteControlStatusStore.shared.clearPairingCode()
            }
        }
    }

    private static func handle(request: BridgeInvokeRequest) async -> BridgeInvokeResponse {
        do {
            switch request.command {
            case LocalControlCommand.listAgents.rawValue:
                let payload = RemoteControlCoordinator.shared.listAgents()
                return .init(id: request.id, ok: true, payload: encode(payload))
            case LocalControlCommand.selectAgent.rawValue:
                let params = try decode(LocalControlSelectAgentParams.self, from: request.paramsJSON)
                guard let payload = RemoteControlCoordinator.shared.selectAgent(id: params.agentID) else {
                    return .init(id: request.id, ok: false, error: .init(code: .invalidRequest, message: "INVALID_REQUEST: unknown agent"))
                }
                return .init(id: request.id, ok: true, payload: encode(payload))
            case LocalControlCommand.listSessions.rawValue:
                let params = try decodeOptional(LocalControlListSessionsParams.self, from: request.paramsJSON)
                let payload = RemoteControlCoordinator.shared.listSessions(agentID: params?.agentID)
                return .init(id: request.id, ok: true, payload: encode(payload))
            case LocalControlCommand.createSession.rawValue:
                let params = try decodeOptional(LocalControlCreateSessionParams.self, from: request.paramsJSON)
                let payload = RemoteControlCoordinator.shared.createSession(preferredKey: params?.preferredKey)
                return .init(id: request.id, ok: true, payload: encode(payload))
            case LocalControlCommand.selectSession.rawValue:
                let params = try decode(LocalControlSelectSessionParams.self, from: request.paramsJSON)
                let payload = RemoteControlCoordinator.shared.selectSession(key: params.sessionKey)
                return .init(id: request.id, ok: true, payload: encode(payload))
            case LocalControlCommand.sendMessage.rawValue:
                let params = try decode(LocalControlSendMessageParams.self, from: request.paramsJSON)
                let payload = await RemoteControlCoordinator.shared.sendMessage(params.message, sessionKey: params.sessionKey)
                return .init(id: request.id, ok: true, payload: encode(payload))
            default:
                return .init(id: request.id, ok: false, error: .init(code: .invalidRequest, message: "INVALID_REQUEST: unsupported local control command"))
            }
        } catch {
            return .init(id: request.id, ok: false, error: .init(code: .invalidRequest, message: error.localizedDescription))
        }
    }

    private static func decode<T: Decodable>(_ type: T.Type, from paramsJSON: String?) throws -> T {
        guard let paramsJSON,
              let data = paramsJSON.data(using: .utf8)
        else {
            throw NSError(domain: "RemoteControl", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing parameters"])
        }
        return try JSONDecoder().decode(type, from: data)
    }

    private static func decodeOptional<T: Decodable>(_ type: T.Type, from paramsJSON: String?) throws -> T? {
        guard let paramsJSON,
              let data = paramsJSON.data(using: .utf8)
        else {
            return nil
        }
        return try JSONDecoder().decode(type, from: data)
    }

    private static func encode<T: Encodable>(_ value: T) -> String? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
