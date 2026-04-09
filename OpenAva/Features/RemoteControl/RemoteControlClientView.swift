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
    var isPairingInProgress = false
    var pairChallengeExpiryText: String?
    var pairErrorText: String?
    var connectionStatusText: String?
    var agents: [LocalControlAgentSummary] = []
    var messageText = ""
    var isConnected = false

    @ObservationIgnored private var browserState: NWBrowser.State?
    @ObservationIgnored private var browserDiagnostics = LocalControlBrowserDiagnostics()
    private let browser = LocalControlBrowser()
    private let client = LocalControlClient()

    private var reconnectTask: Task<Void, Never>?

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
            self.tryReconnectIfPaired()
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
        reconnectTask?.cancel()
        reconnectTask = nil
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
        reconnectTask?.cancel()
        reconnectTask = nil
        guard let service = selectedService else { return }
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
            pairChallengeExpiryText = formatDate(challenge.expiresAtMs)
            pairErrorText = nil
            pairCode = ""
            isPairingInProgress = true
            selectedServiceID = service.id
        } catch {
            resetConnectionState()
            applyErrorState(error)
        }
    }

    func approvePairing() async {
        do {
            let approved = try await client.approvePairing(code: pairCode)
            isConnected = true
            isPairingInProgress = false
            pairChallengeExpiryText = nil
            pairErrorText = nil
            connectionStatusText = L10n.tr("settings.remoteControl.pairedWith", approved.host.displayName)
            await refreshAgents()
        } catch {
            if isPairingTimeout(error) {
                isPairingInProgress = false
                pairChallengeExpiryText = nil
                connectionStatusText = L10n.tr("settings.remoteControl.pairing.timeout")
            } else {
                pairErrorText = error.localizedDescription
            }
        }
    }

    func cancelPairing() {
        isPairingInProgress = false
        pairChallengeExpiryText = nil
        pairErrorText = nil
        pairCode = ""
        resetConnectionState()
    }

    func disconnect() {
        Task { await client.disconnect(silently: true) }
        resetConnectionState()
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

    private func tryReconnectIfPaired() {
        guard !isConnected, reconnectTask == nil else { return }
        reconnectTask = Task { [weak self] in
            guard let self else { return }
            defer { self.reconnectTask = nil }
            let peers = await LocalControlPairingStore.shared.allPeers()
            guard let lastPeer = peers.max(by: { $0.pairedAtMs < $1.pairedAtMs }) else {
                return
            }
            let matchingService = services.first { $0.name == lastPeer.displayName }
            guard let service = matchingService ?? services.first else { return }
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
                await client.loadStoredPairing(instanceId: lastPeer.instanceId)
                isConnected = true
                selectedServiceID = service.id
                connectionStatusText = L10n.tr("settings.remoteControl.pairedWith", lastPeer.displayName)
                await refreshAgents()
            } catch {
                connectionStatusText = nil
            }
        }
    }

    private func applyErrorState(_ error: Error) {
        if isConnectionError(error) {
            handleDisconnect(reason: error.localizedDescription)
        } else if isPairingTimeout(error) {
            resetConnectionState()
            connectionStatusText = L10n.tr("settings.remoteControl.pairing.timeout")
        } else {
            connectionStatusText = error.localizedDescription
        }
    }

    private func handleDisconnect(reason: String) {
        resetConnectionState()
        connectionStatusText = reason == "Disconnected"
            ? L10n.tr("settings.remoteControl.connection.disconnected")
            : reason
    }

    private func resetConnectionState() {
        isConnected = false
        isPairingInProgress = false
        pairChallengeExpiryText = nil
        pairErrorText = nil
        connectionStatusText = nil
        agents = []
        reconnectTask?.cancel()
        reconnectTask = nil
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
                        HStack(spacing: 8) {
                            Picker("", selection: $viewModel.selectedServiceID) {
                                ForEach(viewModel.services, id: \.id) { service in
                                    Text(service.name).tag(Optional(service.id))
                                }
                            }
                            .pickerStyle(.menu)

                            if viewModel.isConnected {
                                statusPill(
                                    title: L10n.tr("settings.remoteControl.status.connected"),
                                    tint: .green
                                )
                            }
                        }
                    }

                    if let connectionStatusText = viewModel.connectionStatusText {
                        Text(connectionStatusText)
                            .font(.footnote)
                            .foregroundStyle(viewModel.isConnected
                                ? Color(uiColor: ChatUIDesign.Color.black60)
                                : .red)
                    }

                    if viewModel.isConnected {
                        Button(L10n.tr("settings.remoteControl.discovery.disconnect")) {
                            viewModel.disconnect()
                        }
                        .buttonStyle(RemoteSecondaryButtonStyle())
                    } else {
                        Button(L10n.tr("settings.remoteControl.discovery.connect")) {
                            Task { await viewModel.connectAndPair() }
                        }
                        .buttonStyle(RemotePrimaryButtonStyle())
                        .disabled(viewModel.selectedServiceID == nil || viewModel.isPairingInProgress)
                    }

                    if !viewModel.isConnected {
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
            }
            .padding(24)
            .frame(maxWidth: 640)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: ChatUIDesign.Color.warmCream))
        .navigationTitle(L10n.tr("settings.remoteControl.navigationTitle"))
        .sheet(isPresented: $viewModel.isPairingInProgress) {
            pairingSheet
        }
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

    private var pairingSheet: some View {
        NavigationStack {
            VStack(spacing: 24) {
                if let expiryText = viewModel.pairChallengeExpiryText {
                    Text(L10n.tr("settings.remoteControl.pairChallengeReceived", expiryText))
                        .font(.subheadline)
                        .foregroundStyle(Color(uiColor: ChatUIDesign.Color.black60))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                TextField(L10n.tr("settings.remoteControl.pairing.code"), text: $viewModel.pairCode)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.numberPad)
                    .remoteCardInputStyle()

                if let pairErrorText = viewModel.pairErrorText {
                    Text(pairErrorText)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Button(L10n.tr("settings.remoteControl.pairing.approve")) {
                    Task { await viewModel.approvePairing() }
                }
                .buttonStyle(RemotePrimaryButtonStyle())
                .disabled(viewModel.pairCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(24)
            .navigationTitle(L10n.tr("settings.remoteControl.pairing.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.tr("common.cancel")) {
                        viewModel.cancelPairing()
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func statusPill(title: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(tint)
                .frame(width: 6, height: 6)

            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color(uiColor: ChatUIDesign.Color.black80))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(tint.opacity(0.12))
        )
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
