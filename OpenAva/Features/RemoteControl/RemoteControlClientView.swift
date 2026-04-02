import Observation
import OpenClawKit
import SwiftUI

@MainActor
@Observable
final class RemoteControlClientViewModel {
    var services: [LocalControlDiscoveredService] = []
    var selectedServiceID: String?
    var pairCode = ""
    var statusText: String?
    var agents: [LocalControlAgentSummary] = []
    var sessions: [LocalControlSessionSummary] = []
    var messageText = ""
    var isConnected = false

    private let browser = LocalControlBrowser()
    private let client = LocalControlClient()

    init() {
        browser.onServicesChanged = { [weak self] services in
            self?.services = services
            if self?.selectedServiceID == nil {
                self?.selectedServiceID = services.first?.id
            }
        }
    }

    func startBrowsing() {
        browser.start()
    }

    func stopBrowsing() {
        browser.stop()
    }

    func connectAndPair() async {
        guard let service = selectedService else {
            statusText = L10n.tr("settings.remoteControl.noServiceSelected")
            return
        }
        do {
            let localHello = LocalControlHello(
                role: .controller,
                instanceId: InstanceIdentity.instanceId,
                displayName: InstanceIdentity.displayName,
                platform: InstanceIdentity.platformString,
                deviceFamily: InstanceIdentity.deviceFamily,
                modelIdentifier: InstanceIdentity.modelIdentifier,
                appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
                appBuild: (Bundle.main.infoDictionary?["CFBundleVersion"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            try await client.connect(to: service, localHello: localHello)
            let challenge = try await client.beginPairing()
            statusText = L10n.tr("settings.remoteControl.pairChallengeReceived", formatDate(challenge.expiresAtMs))
            isConnected = true
            selectedServiceID = service.id
        } catch {
            statusText = error.localizedDescription
        }
    }

    func approvePairing() async {
        do {
            _ = try await client.approvePairing(code: pairCode)
            statusText = L10n.tr("settings.remoteControl.paired")
            await refreshAgents()
            await refreshSessions()
        } catch {
            statusText = error.localizedDescription
        }
    }

    func refreshAgents() async {
        guard isConnected else { return }
        do {
            let request = BridgeInvokeRequest(id: UUID().uuidString, command: LocalControlCommand.listAgents.rawValue, paramsJSON: nil)
            let response = try await client.invoke(request)
            let payload: LocalControlListAgentsPayload = try decodePayload(from: response)
            agents = payload.agents
        } catch {
            statusText = error.localizedDescription
        }
    }

    func selectAgent(_ agent: LocalControlAgentSummary) async {
        do {
            let params = LocalControlSelectAgentParams(agentID: agent.id)
            let request = try BridgeInvokeRequest(
                id: UUID().uuidString,
                command: LocalControlCommand.selectAgent.rawValue,
                paramsJSON: encodeJSON(params)
            )
            _ = try await client.invoke(request)
            await refreshAgents()
            await refreshSessions()
        } catch {
            statusText = error.localizedDescription
        }
    }

    func refreshSessions() async {
        guard isConnected else { return }
        do {
            let request = BridgeInvokeRequest(id: UUID().uuidString, command: LocalControlCommand.listSessions.rawValue, paramsJSON: nil)
            let response = try await client.invoke(request)
            let payload: LocalControlListSessionsPayload = try decodePayload(from: response)
            sessions = payload.sessions
        } catch {
            statusText = error.localizedDescription
        }
    }

    func createSession() async {
        guard isConnected else { return }
        do {
            let request = BridgeInvokeRequest(id: UUID().uuidString, command: LocalControlCommand.createSession.rawValue, paramsJSON: nil)
            _ = try await client.invoke(request)
            await refreshSessions()
        } catch {
            statusText = error.localizedDescription
        }
    }

    func selectSession(_ session: LocalControlSessionSummary) async {
        guard isConnected else { return }
        do {
            let params = LocalControlSelectSessionParams(sessionKey: session.key)
            let request = try BridgeInvokeRequest(
                id: UUID().uuidString,
                command: LocalControlCommand.selectSession.rawValue,
                paramsJSON: encodeJSON(params)
            )
            _ = try await client.invoke(request)
            await refreshSessions()
        } catch {
            statusText = error.localizedDescription
        }
    }

    func sendMessage() async {
        let trimmed = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isConnected, !trimmed.isEmpty else { return }
        do {
            let activeSession = sessions.first(where: { $0.isActive })?.key
            let params = LocalControlSendMessageParams(message: trimmed, sessionKey: activeSession)
            let request = try BridgeInvokeRequest(
                id: UUID().uuidString,
                command: LocalControlCommand.sendMessage.rawValue,
                paramsJSON: encodeJSON(params)
            )
            _ = try await client.invoke(request)
            messageText = ""
            statusText = L10n.tr("settings.remoteControl.messageSent")
        } catch {
            statusText = error.localizedDescription
        }
    }

    private var selectedService: LocalControlDiscoveredService? {
        services.first(where: { $0.id == selectedServiceID })
    }

    private func decodePayload<T: Decodable>(from response: BridgeInvokeResponse) throws -> T {
        guard response.ok,
              let payload = response.payload,
              let data = payload.data(using: .utf8)
        else {
            throw NSError(domain: "RemoteControl", code: 1, userInfo: [NSLocalizedDescriptionKey: response.error?.message ?? "Request failed"])
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func encodeJSON<T: Encodable>(_ value: T) throws -> String {
        let data = try JSONEncoder().encode(value)
        guard let text = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "RemoteControl", code: 2, userInfo: [NSLocalizedDescriptionKey: "Encoding failed"])
        }
        return text
    }

    private func formatDate(_ timestampMs: Int64) -> String {
        let date = Date(timeIntervalSince1970: Double(timestampMs) / 1000)
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter.string(from: date)
    }
}

struct RemoteControlClientView: View {
    @State private var viewModel = RemoteControlClientViewModel()

    var body: some View {
        Form {
            Section(L10n.tr("settings.remoteControl.discovery.title")) {
                Picker(L10n.tr("settings.remoteControl.discovery.device"), selection: $viewModel.selectedServiceID) {
                    ForEach(viewModel.services, id: \.id) { service in
                        Text(service.name).tag(Optional(service.id))
                    }
                }
                Button(L10n.tr("settings.remoteControl.discovery.connect")) {
                    Task { await viewModel.connectAndPair() }
                }
                .disabled(viewModel.selectedServiceID == nil)
            }

            Section(L10n.tr("settings.remoteControl.pairing.title")) {
                TextField(L10n.tr("settings.remoteControl.pairing.code"), text: $viewModel.pairCode)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button(L10n.tr("settings.remoteControl.pairing.approve")) {
                    Task { await viewModel.approvePairing() }
                }
                .disabled(viewModel.pairCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            Section(L10n.tr("settings.remoteControl.agents.title")) {
                ForEach(viewModel.agents, id: \.id) { agent in
                    Button {
                        Task { await viewModel.selectAgent(agent) }
                    } label: {
                        HStack {
                            Text("\(agent.emoji) \(agent.name)")
                            Spacer()
                            if agent.isActive {
                                Image(systemName: "checkmark.circle.fill")
                            }
                        }
                    }
                }
                Button(L10n.tr("settings.remoteControl.refresh")) {
                    Task {
                        await viewModel.refreshAgents()
                        await viewModel.refreshSessions()
                    }
                }
                .disabled(!viewModel.isConnected)
            }

            Section(L10n.tr("settings.remoteControl.sessions.title")) {
                Button(L10n.tr("settings.remoteControl.sessions.new")) {
                    Task { await viewModel.createSession() }
                }
                .disabled(!viewModel.isConnected)
                ForEach(viewModel.sessions, id: \.key) { session in
                    Button {
                        Task { await viewModel.selectSession(session) }
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(session.displayName)
                                Text(session.key)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if session.isActive {
                                Image(systemName: "checkmark.circle.fill")
                            }
                        }
                    }
                }
            }

            Section(L10n.tr("settings.remoteControl.message.title")) {
                TextField(L10n.tr("settings.remoteControl.message.placeholder"), text: $viewModel.messageText, axis: .vertical)
                Button(L10n.tr("settings.remoteControl.message.send")) {
                    Task { await viewModel.sendMessage() }
                }
                .disabled(!viewModel.isConnected || viewModel.messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if let statusText = viewModel.statusText {
                Section(L10n.tr("settings.remoteControl.status.title")) {
                    Text(statusText)
                }
            }
        }
        .navigationTitle(L10n.tr("settings.remoteControl.navigationTitle"))
        .task {
            viewModel.startBrowsing()
        }
        .onDisappear {
            viewModel.stopBrowsing()
        }
    }
}
