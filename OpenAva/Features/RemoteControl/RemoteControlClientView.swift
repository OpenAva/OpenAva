import ChatUI
import Network
import Observation
import OpenClawKit
import SwiftUI

@MainActor
@Observable
final class RemoteControlClientViewModel {
    var services: [LocalControlDiscoveredService] = []
    var selectedServiceID: String?
    var discoveryStatusText: String?
    var discoveryDiagnosticsText: String?
    var pairCode = ""
    var statusText: String?
    var agents: [LocalControlAgentSummary] = []
    var messageText = ""
    var isConnected = false

    @ObservationIgnored private var browserState: NWBrowser.State?
    @ObservationIgnored private var browserDiagnostics = LocalControlBrowserDiagnostics()
    private let browser = LocalControlBrowser()
    private let client = LocalControlClient()

    init() {
        browser.onServicesChanged = { [weak self] services in
            guard let self else { return }
            self.services = services
            if let selectedServiceID = self.selectedServiceID,
               services.contains(where: { $0.id == selectedServiceID })
            {
                self.selectedServiceID = selectedServiceID
            } else {
                self.selectedServiceID = services.first?.id
            }
            self.refreshDiscoveryStatus()
        }
        browser.onStateChanged = { [weak self] state in
            self?.browserState = state
            self?.refreshDiscoveryStatus()
        }
        browser.onDiagnosticsChanged = { [weak self] diagnostics in
            self?.browserDiagnostics = diagnostics
            self?.refreshDiscoveryStatus()
        }
        Task { [weak self] in
            await self?.client.setDisconnectHandler { reason in
                await MainActor.run {
                    self?.handleDisconnect(reason: reason)
                }
            }
        }
        Task { [weak self] in
            await self?.restoreLastPairedStatusIfNeeded()
        }
    }

    func startBrowsing(forceRefresh: Bool = false) {
        if forceRefresh {
            browser.restart()
        } else {
            browser.start()
        }
        refreshDiscoveryStatus()
    }

    func stopBrowsing(disconnect: Bool = false) {
        browser.stop()
        browserState = nil
        browserDiagnostics = .init()
        discoveryStatusText = nil
        discoveryDiagnosticsText = nil
        if disconnect {
            Task { await client.disconnect(silently: true) }
            resetConnectionState()
        }
    }

    func handleScenePhaseChange(_ scenePhase: ScenePhase) {
        switch scenePhase {
        case .active:
            startBrowsing(forceRefresh: true)
        case .background:
            stopBrowsing()
        case .inactive:
            break
        @unknown default:
            break
        }
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
            refreshDiscoveryStatus()
            selectedServiceID = service.id
        } catch {
            resetConnectionState()
            applyErrorState(error)
        }
    }

    func approvePairing() async {
        do {
            let approved = try await client.approvePairing(code: pairCode)
            statusText = L10n.tr("settings.remoteControl.pairedWith", approved.host.displayName)
            await refreshAgents()
        } catch {
            applyErrorState(error)
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
            applyErrorState(error)
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
        } catch {
            applyErrorState(error)
        }
    }

    func sendMessage() async {
        let trimmed = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isConnected, !trimmed.isEmpty else { return }
        do {
            let params = LocalControlSendMessageParams(message: trimmed)
            let request = try BridgeInvokeRequest(
                id: UUID().uuidString,
                command: LocalControlCommand.sendMessage.rawValue,
                paramsJSON: encodeJSON(params)
            )
            _ = try await client.invoke(request)
            messageText = ""
            statusText = L10n.tr("settings.remoteControl.messageSent")
        } catch {
            applyErrorState(error)
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

    private func restoreLastPairedStatusIfNeeded() async {
        guard !isConnected, statusText == nil else { return }
        let peers = await LocalControlPairingStore.shared.allPeers()
        guard let peer = peers.max(by: { $0.pairedAtMs < $1.pairedAtMs }) else { return }
        statusText = L10n.tr("settings.remoteControl.pairedWith", peer.displayName)
    }

    private func applyErrorState(_ error: Error) {
        if isConnectionError(error) {
            handleDisconnect(reason: error.localizedDescription)
        } else if isPairingTimeout(error) {
            resetConnectionState()
            statusText = L10n.tr("settings.remoteControl.pairing.timeout")
        } else {
            statusText = error.localizedDescription
        }
    }

    private func handleDisconnect(reason: String) {
        resetConnectionState()
        statusText = reason == "Disconnected"
            ? L10n.tr("settings.remoteControl.connection.disconnected")
            : reason
    }

    private func resetConnectionState() {
        isConnected = false
        agents = []
        refreshDiscoveryStatus()
    }

    private func refreshDiscoveryStatus() {
        guard !isConnected else {
            discoveryStatusText = nil
            discoveryDiagnosticsText = nil
            return
        }
        switch browserState {
        case let .failed(error):
            discoveryStatusText = L10n.tr("settings.remoteControl.discovery.failed", error.localizedDescription)
            discoveryDiagnosticsText = nil
        case let .waiting(error):
            discoveryStatusText = L10n.tr("settings.remoteControl.discovery.waiting", error.localizedDescription)
            discoveryDiagnosticsText = nil
        case .ready, .setup, nil:
            if services.isEmpty {
                discoveryStatusText = makeSearchingStatusText()
                discoveryDiagnosticsText = makeDiagnosticsText()
            } else {
                discoveryStatusText = nil
                discoveryDiagnosticsText = nil
            }
        case .cancelled:
            discoveryStatusText = nil
            discoveryDiagnosticsText = nil
        @unknown default:
            if services.isEmpty {
                discoveryStatusText = makeSearchingStatusText()
                discoveryDiagnosticsText = makeDiagnosticsText()
            } else {
                discoveryStatusText = nil
                discoveryDiagnosticsText = nil
            }
        }
    }

    private func makeSearchingStatusText() -> String {
        let diagnostics = browserDiagnostics
        if diagnostics.rawResultCount > 0, diagnostics.resolvedServiceCount == 0 {
            return L10n.tr(
                "settings.remoteControl.discovery.resolving",
                String(diagnostics.rawResultCount)
            )
        }
        return L10n.tr("settings.remoteControl.discovery.searching")
    }

    private func makeDiagnosticsText() -> String? {
        let diagnostics = browserDiagnostics
        if let lastFailure = diagnostics.lastResolutionFailure,
           diagnostics.resolutionFailureCount > 0
        {
            return L10n.tr(
                "settings.remoteControl.discovery.diagnostics.resolveFailure",
                String(diagnostics.rawResultCount),
                String(diagnostics.resolutionFailureCount),
                lastFailure
            )
        }
        if diagnostics.rawResultCount > 0, diagnostics.resolvedServiceCount == 0 {
            return L10n.tr(
                "settings.remoteControl.discovery.diagnostics.resolving",
                String(diagnostics.rawResultCount),
                String(diagnostics.pendingResolutionCount)
            )
        }
        return nil
    }

    private func isConnectionError(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == "LocalControl" && [2, 3, 5].contains(nsError.code)
    }

    private func isPairingTimeout(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == "LocalControl" && nsError.code == 8
    }
}

struct RemoteControlClientView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var viewModel = RemoteControlClientViewModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                settingsCard(
                    title: L10n.tr("settings.remoteControl.discovery.title"),
                    tint: .blue
                ) {
                    cardField(L10n.tr("settings.remoteControl.discovery.device")) {
                        Picker("", selection: $viewModel.selectedServiceID) {
                            ForEach(viewModel.services, id: \.id) { service in
                                Text(service.name).tag(Optional(service.id))
                            }
                        }
                        .pickerStyle(.menu)
                    }

                    Button(L10n.tr("settings.remoteControl.discovery.connect")) {
                        Task { await viewModel.connectAndPair() }
                    }
                    .buttonStyle(RemotePrimaryButtonStyle())
                    .disabled(viewModel.selectedServiceID == nil)

                    if let discoveryStatusText = viewModel.discoveryStatusText {
                        Text(discoveryStatusText)
                            .font(.footnote)
                            .foregroundStyle(Color(uiColor: ChatUIDesign.Color.black60))
                    }

                    if let discoveryDiagnosticsText = viewModel.discoveryDiagnosticsText {
                        Text(discoveryDiagnosticsText)
                            .font(.caption)
                            .foregroundStyle(Color(uiColor: ChatUIDesign.Color.black60))
                    }
                }

                settingsCard(
                    title: L10n.tr("settings.remoteControl.pairing.title"),
                    tint: .indigo
                ) {
                    cardField(L10n.tr("settings.remoteControl.pairing.code")) {
                        TextField(L10n.tr("settings.remoteControl.pairing.code"), text: $viewModel.pairCode)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .remoteCardInputStyle()
                    }

                    Button(L10n.tr("settings.remoteControl.pairing.approve")) {
                        Task { await viewModel.approvePairing() }
                    }
                    .buttonStyle(RemotePrimaryButtonStyle())
                    .disabled(viewModel.pairCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                settingsCard(
                    title: L10n.tr("settings.remoteControl.agents.title"),
                    tint: .green
                ) {
                    if viewModel.agents.isEmpty {
                        Text(L10n.tr("settings.remoteControl.refresh"))
                            .font(.footnote)
                            .foregroundStyle(Color(uiColor: ChatUIDesign.Color.black60))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        ForEach(viewModel.agents, id: \.id) { agent in
                            agentButton(agent)
                        }
                    }

                    Button(L10n.tr("settings.remoteControl.refresh")) {
                        Task {
                            await viewModel.refreshAgents()
                        }
                    }
                    .buttonStyle(RemoteSecondaryButtonStyle())
                    .disabled(!viewModel.isConnected)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                settingsCard(
                    title: L10n.tr("settings.remoteControl.message.title"),
                    tint: .purple
                ) {
                    cardField(L10n.tr("settings.remoteControl.message.placeholder")) {
                        TextField(L10n.tr("settings.remoteControl.message.placeholder"), text: $viewModel.messageText, axis: .vertical)
                            .lineLimit(3 ... 6)
                            .remoteCardInputStyle()
                    }

                    Button(L10n.tr("settings.remoteControl.message.send")) {
                        Task { await viewModel.sendMessage() }
                    }
                    .buttonStyle(RemotePrimaryButtonStyle())
                    .disabled(!viewModel.isConnected || viewModel.messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                if let statusText = viewModel.statusText {
                    settingsCard(
                        title: L10n.tr("settings.remoteControl.status.title"),
                        tint: .red
                    ) {
                        Text(statusText)
                            .font(.subheadline)
                            .foregroundStyle(Color(uiColor: ChatUIDesign.Color.offBlack))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 640)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: ChatUIDesign.Color.warmCream))
        .navigationTitle(L10n.tr("settings.remoteControl.navigationTitle"))
        .task {
            viewModel.startBrowsing(forceRefresh: true)
        }
        .onChange(of: scenePhase) { _, newPhase in
            viewModel.handleScenePhaseChange(newPhase)
        }
        .onDisappear {
            viewModel.stopBrowsing(disconnect: true)
        }
    }

    private func settingsCard<Content: View>(
        title: String,
        tint: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(tint.opacity(0.16))
                        .frame(width: 18, height: 18)

                    Circle()
                        .fill(tint)
                        .frame(width: 8, height: 8)
                }

                Text(title)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Color(uiColor: ChatUIDesign.Color.offBlack))
            }

            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: ChatUIDesign.Radius.card, style: .continuous)
                .fill(Color(uiColor: ChatUIDesign.Color.warmCream))
        )
        .overlay(
            RoundedRectangle(cornerRadius: ChatUIDesign.Radius.card, style: .continuous)
                .strokeBorder(Color(uiColor: ChatUIDesign.Color.oatBorder), lineWidth: 1)
        )
    }

    private func cardField<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(Color(uiColor: ChatUIDesign.Color.offBlack))

            content()
        }
    }

    private func agentButton(_ agent: LocalControlAgentSummary) -> some View {
        let backgroundColor = agent.isActive
            ? Color(uiColor: ChatUIDesign.Color.brandOrange).opacity(0.12)
            : Color(uiColor: ChatUIDesign.Color.warmCream)

        return Button {
            Task { await viewModel.selectAgent(agent) }
        } label: {
            HStack(spacing: 12) {
                Text(verbatim: agent.emoji + " " + agent.name)
                    .font(.subheadline.weight(.regular))
                    .foregroundStyle(Color(uiColor: ChatUIDesign.Color.offBlack))

                Spacer()

                if agent.isActive {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color(uiColor: ChatUIDesign.Color.brandOrange))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: ChatUIDesign.Radius.card, style: .continuous)
                    .fill(backgroundColor)
            )
        }
        .buttonStyle(.plain)
    }
}

struct RemotePrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .regular))
            .foregroundStyle(Color(uiColor: ChatUIDesign.Color.pureWhite))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(Color(uiColor: ChatUIDesign.Color.offBlack))
            .clipShape(RoundedRectangle(cornerRadius: ChatUIDesign.Radius.button, style: .continuous))
            .opacity(configuration.isPressed ? 0.85 : 1.0)
    }
}

struct RemoteSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .regular))
            .foregroundStyle(Color(uiColor: ChatUIDesign.Color.offBlack))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: ChatUIDesign.Radius.button, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: ChatUIDesign.Radius.button, style: .continuous)
                    .stroke(Color(uiColor: ChatUIDesign.Color.offBlack), lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.85 : 1.0)
    }
}

private extension View {
    func remoteCardInputStyle() -> some View {
        padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: ChatUIDesign.Radius.card, style: .continuous)
                    .fill(Color(uiColor: ChatUIDesign.Color.pureWhite))
            )
            .overlay(
                RoundedRectangle(cornerRadius: ChatUIDesign.Radius.card, style: .continuous)
                    .strokeBorder(Color(uiColor: ChatUIDesign.Color.oatBorder), lineWidth: 1)
            )
    }
}
