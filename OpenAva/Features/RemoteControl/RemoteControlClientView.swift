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

    func connectAndPair(serviceID: String? = nil) async {
        reconnectTask?.cancel()
        reconnectTask = nil
        if let serviceID {
            selectedServiceID = serviceID
        }
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

    var selectedService: LocalControlDiscoveredService? {
        services.first(where: { $0.id == selectedServiceID })
    }

    var activeAgent: LocalControlAgentSummary? {
        agents.first(where: { $0.isActive })
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

// MARK: - View

struct RemoteControlClientView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var viewModel = RemoteControlClientViewModel()

    var body: some View {
        ZStack {
            Color(uiColor: ChatUIDesign.Color.warmCream)
                .ignoresSafeArea()

            Group {
                if viewModel.isConnected {
                    ConsoleScreen(viewModel: viewModel)
                } else {
                    DiscoveryScreen(viewModel: viewModel)
                }
            }
            .animation(.interactiveSpring(response: 0.38, dampingFraction: 0.85), value: viewModel.isConnected)
        }
        .navigationTitle(L10n.tr("settings.remoteControl.navigationTitle"))
        .sheet(isPresented: $viewModel.isPairingInProgress) {
            PairingSheet(viewModel: viewModel)
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
}

// MARK: - Discovery Screen (AirDrop / Find My style)

private struct DiscoveryScreen: View {
    @Bindable var viewModel: RemoteControlClientViewModel

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                DiscoveryHero(isEmpty: viewModel.services.isEmpty)
                    .padding(.top, 32)

                if viewModel.services.isEmpty {
                    DiscoveryEmptyBlock(
                        statusText: viewModel.discoveryStatusText,
                        diagnosticsText: viewModel.discoveryDiagnosticsText,
                        connectionErrorText: viewModel.connectionStatusText
                    )
                } else {
                    DeviceList(
                        services: viewModel.services,
                        selectedID: viewModel.selectedServiceID,
                        isBusy: viewModel.isPairingInProgress,
                        connectionErrorText: viewModel.connectionStatusText,
                        onTap: { service in
                            viewModel.selectedServiceID = service.id
                            Task { await viewModel.connectAndPair(serviceID: service.id) }
                        }
                    )
                }

                Button {
                    viewModel.startBrowsing(forceRefresh: true)
                } label: {
                    Label(L10n.tr("settings.remoteControl.refresh"), systemImage: "arrow.clockwise")
                        .font(.system(size: 15, weight: .medium))
                }
                .buttonStyle(RemoteGhostButtonStyle())
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 40)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
    }
}

private struct DiscoveryHero: View {
    let isEmpty: Bool
    @State private var pulse = false

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .strokeBorder(Color(uiColor: ChatUIDesign.Color.oatBorder), lineWidth: 1)
                    .frame(width: 140, height: 140)
                    .scaleEffect(pulse ? 1.15 : 1.0)
                    .opacity(pulse ? 0.0 : 0.9)

                Circle()
                    .strokeBorder(Color(uiColor: ChatUIDesign.Color.oatBorder), lineWidth: 1)
                    .frame(width: 100, height: 100)
                    .scaleEffect(pulse ? 1.1 : 1.0)
                    .opacity(pulse ? 0.2 : 0.9)

                Circle()
                    .fill(Color(uiColor: ChatUIDesign.Color.pureWhite))
                    .frame(width: 72, height: 72)
                    .overlay(
                        Circle()
                            .strokeBorder(Color(uiColor: ChatUIDesign.Color.oatBorder), lineWidth: 1)
                    )

                Image(systemName: "laptopcomputer")
                    .font(.system(size: 28, weight: .regular))
                    .foregroundStyle(Color(uiColor: ChatUIDesign.Color.offBlack))
            }
            .frame(height: 140)
            .onAppear {
                guard isEmpty else { return }
                withAnimation(.easeOut(duration: 1.8).repeatForever(autoreverses: false)) {
                    pulse = true
                }
            }

            VStack(spacing: 6) {
                Text(L10n.tr("settings.remoteControl.discovery.title"))
                    .font(.system(size: 24, weight: .regular))
                    .tracking(-0.48)
                    .foregroundStyle(Color(uiColor: ChatUIDesign.Color.offBlack))

                Text(isEmpty
                    ? L10n.tr("settings.remoteControl.discovery.empty.detail")
                    : L10n.tr("settings.remoteControl.discovery.tapToSelect"))
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(Color(uiColor: ChatUIDesign.Color.black60))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
            }
        }
    }
}

private struct DiscoveryEmptyBlock: View {
    let statusText: String?
    let diagnosticsText: String?
    let connectionErrorText: String?

    var body: some View {
        VStack(spacing: 10) {
            if let connectionErrorText {
                StatusLine(text: connectionErrorText, tone: .critical)
            }
            if let statusText {
                StatusLine(text: statusText, tone: .neutral)
            }
            if let diagnosticsText {
                StatusLine(text: diagnosticsText, tone: .muted)
            }
        }
    }
}

private struct DeviceList: View {
    let services: [LocalControlDiscoveredService]
    let selectedID: String?
    let isBusy: Bool
    let connectionErrorText: String?
    let onTap: (LocalControlDiscoveredService) -> Void

    var body: some View {
        VStack(spacing: 8) {
            if let connectionErrorText {
                StatusLine(text: connectionErrorText, tone: .critical)
                    .padding(.bottom, 4)
            }

            ForEach(services, id: \.id) { service in
                DeviceRow(
                    service: service,
                    isBusy: isBusy && selectedID == service.id,
                    action: { onTap(service) }
                )
            }
        }
    }
}

private struct DeviceRow: View {
    let service: LocalControlDiscoveredService
    let isBusy: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(uiColor: ChatUIDesign.Color.warmCream))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(Color(uiColor: ChatUIDesign.Color.oatBorder), lineWidth: 1)
                        )
                        .frame(width: 44, height: 44)

                    Image(systemName: "laptopcomputer")
                        .font(.system(size: 18, weight: .regular))
                        .foregroundStyle(Color(uiColor: ChatUIDesign.Color.offBlack))
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(service.name)
                        .font(.system(size: 16, weight: .regular))
                        .foregroundStyle(Color(uiColor: ChatUIDesign.Color.offBlack))
                    Text(service.host)
                        .font(.system(size: 12, weight: .regular, design: .monospaced))
                        .foregroundStyle(Color(uiColor: ChatUIDesign.Color.black50))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 8)

                if isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Color(uiColor: ChatUIDesign.Color.brandOrange))
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color(uiColor: ChatUIDesign.Color.black50))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .buttonStyle(RemoteRowButtonStyle())
        .disabled(isBusy)
    }
}

// MARK: - Console Screen (Apple TV Remote style)

private struct ConsoleScreen: View {
    @Bindable var viewModel: RemoteControlClientViewModel

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 20) {
                    ConnectedDeviceHeader(
                        deviceName: viewModel.selectedService?.name ?? "Mac",
                        statusText: viewModel.connectionStatusText,
                        onDisconnect: { viewModel.disconnect() }
                    )

                    AgentPicker(
                        agents: viewModel.agents,
                        onSelect: { agent in
                            Task { await viewModel.selectAgent(agent) }
                        },
                        onRefresh: {
                            Task { await viewModel.refreshAgents() }
                        }
                    )
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 16)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }

            Composer(
                text: $viewModel.messageText,
                activeAgent: viewModel.activeAgent,
                onSend: {
                    Task { await viewModel.sendMessage() }
                }
            )
        }
    }
}

private struct ConnectedDeviceHeader: View {
    let deviceName: String
    let statusText: String?
    let onDisconnect: () -> Void

    @State private var pulse = false

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                Circle()
                    .fill(Color(uiColor: ChatUIDesign.Color.offBlack))
                    .frame(width: 44, height: 44)

                Image(systemName: "laptopcomputer")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(Color(uiColor: ChatUIDesign.Color.pureWhite))

                Circle()
                    .fill(Color(red: 0x0B / 255, green: 0xDF / 255, blue: 0x50 / 255))
                    .frame(width: 10, height: 10)
                    .overlay(
                        Circle()
                            .strokeBorder(Color(uiColor: ChatUIDesign.Color.warmCream), lineWidth: 2)
                    )
                    .offset(x: 16, y: 16)
                    .scaleEffect(pulse ? 1.15 : 1.0)
            }
            .onAppear {
                withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(deviceName)
                    .font(.system(size: 18, weight: .regular))
                    .tracking(-0.2)
                    .foregroundStyle(Color(uiColor: ChatUIDesign.Color.offBlack))
                    .lineLimit(1)

                Text(statusText ?? L10n.tr("settings.remoteControl.status.connected"))
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(Color(uiColor: ChatUIDesign.Color.black60))
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button(action: onDisconnect) {
                Text(L10n.tr("settings.remoteControl.discovery.disconnect"))
                    .font(.system(size: 14, weight: .regular))
            }
            .buttonStyle(RemoteGhostButtonStyle())
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(uiColor: ChatUIDesign.Color.pureWhite))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color(uiColor: ChatUIDesign.Color.oatBorder), lineWidth: 1)
        )
    }
}

private struct AgentPicker: View {
    let agents: [LocalControlAgentSummary]
    let onSelect: (LocalControlAgentSummary) -> Void
    let onRefresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center) {
                Text(L10n.tr("settings.remoteControl.agents.title").uppercased())
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .tracking(0.8)
                    .foregroundStyle(Color(uiColor: ChatUIDesign.Color.black60))

                Spacer()

                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(RemoteIconButtonStyle())
            }

            if agents.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.tr("settings.remoteControl.agents.empty.title"))
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(Color(uiColor: ChatUIDesign.Color.offBlack))
                    Text(L10n.tr("settings.remoteControl.agents.empty.detail"))
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(Color(uiColor: ChatUIDesign.Color.black60))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(uiColor: ChatUIDesign.Color.pureWhite))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color(uiColor: ChatUIDesign.Color.oatBorder), lineWidth: 1)
                )
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(agents.enumerated()), id: \.element.id) { index, agent in
                        AgentRow(agent: agent, action: { onSelect(agent) })
                        if index < agents.count - 1 {
                            Divider()
                                .background(Color(uiColor: ChatUIDesign.Color.oatBorder))
                                .padding(.leading, 48)
                        }
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(uiColor: ChatUIDesign.Color.pureWhite))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color(uiColor: ChatUIDesign.Color.oatBorder), lineWidth: 1)
                )
            }
        }
    }
}

private struct AgentRow: View {
    let agent: LocalControlAgentSummary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text(agent.emoji.isEmpty ? "🤖" : agent.emoji)
                    .font(.system(size: 22))
                    .frame(width: 32, height: 32)

                Text(agent.name)
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(Color(uiColor: ChatUIDesign.Color.offBlack))
                    .lineLimit(1)

                Spacer(minLength: 8)

                if agent.isActive {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color(uiColor: ChatUIDesign.Color.brandOrange))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(RemoteRowButtonStyle())
    }
}

private struct Composer: View {
    @Binding var text: String
    let activeAgent: LocalControlAgentSummary?
    let onSend: () -> Void

    @FocusState private var isFocused: Bool

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Color(uiColor: ChatUIDesign.Color.oatBorder))
                .frame(height: 1)

            HStack(alignment: .bottom, spacing: 10) {
                TextField(
                    placeholder,
                    text: $text,
                    axis: .vertical
                )
                .focused($isFocused)
                .font(.system(size: 16, weight: .regular))
                .lineLimit(1 ... 5)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(uiColor: ChatUIDesign.Color.pureWhite))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(
                            isFocused
                                ? Color(uiColor: ChatUIDesign.Color.offBlack)
                                : Color(uiColor: ChatUIDesign.Color.oatBorder),
                            lineWidth: 1
                        )
                )
                .animation(.easeOut(duration: 0.15), value: isFocused)

                Button(action: onSend) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color(uiColor: ChatUIDesign.Color.pureWhite))
                        .frame(width: 40, height: 40)
                        .background(
                            Circle()
                                .fill(canSend
                                    ? Color(uiColor: ChatUIDesign.Color.brandOrange)
                                    : Color(uiColor: ChatUIDesign.Color.oatBorder))
                        )
                }
                .buttonStyle(RemoteScaleButtonStyle())
                .disabled(!canSend)
                .animation(.easeOut(duration: 0.15), value: canSend)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 12)
            .background(Color(uiColor: ChatUIDesign.Color.warmCream))
        }
    }

    private var placeholder: String {
        if let activeAgent {
            return L10n.tr("settings.remoteControl.message.placeholder") + " · " + activeAgent.name
        }
        return L10n.tr("settings.remoteControl.message.placeholder")
    }
}

// MARK: - Pairing Sheet

private struct PairingSheet: View {
    @Bindable var viewModel: RemoteControlClientViewModel

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                VStack(spacing: 8) {
                    Image(systemName: "key.horizontal.fill")
                        .font(.system(size: 36, weight: .regular))
                        .foregroundStyle(Color(uiColor: ChatUIDesign.Color.brandOrange))

                    Text(L10n.tr("settings.remoteControl.step.pair.title"))
                        .font(.system(size: 24, weight: .regular))
                        .tracking(-0.48)
                        .foregroundStyle(Color(uiColor: ChatUIDesign.Color.offBlack))

                    Text(L10n.tr("settings.remoteControl.step.pair.detail"))
                        .font(.system(size: 14))
                        .foregroundStyle(Color(uiColor: ChatUIDesign.Color.black60))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 12)

                if let expiryText = viewModel.pairChallengeExpiryText {
                    Text(L10n.tr("settings.remoteControl.pairChallengeReceived", expiryText))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Color(uiColor: ChatUIDesign.Color.black60))
                }

                TextField(L10n.tr("settings.remoteControl.pairing.code"), text: $viewModel.pairCode)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.center)
                    .font(.system(size: 28, weight: .medium, design: .monospaced))
                    .tracking(8)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color(uiColor: ChatUIDesign.Color.pureWhite))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color(uiColor: ChatUIDesign.Color.offBlack), lineWidth: 1)
                    )

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

                Spacer(minLength: 0)
            }
            .padding(24)
            .frame(maxWidth: .infinity)
            .background(Color(uiColor: ChatUIDesign.Color.warmCream))
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
}

// MARK: - Shared Small Views

private enum RemoteStatusTone {
    case neutral
    case critical
    case muted
}

private struct StatusLine: View {
    let text: String
    let tone: RemoteStatusTone

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .regular))
            .foregroundStyle(color)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
    }

    private var color: Color {
        switch tone {
        case .critical: return .red
        case .neutral: return Color(uiColor: ChatUIDesign.Color.black60)
        case .muted: return Color(uiColor: ChatUIDesign.Color.black50)
        }
    }
}

// MARK: - Button Styles

struct RemotePrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .regular))
            .foregroundStyle(Color(uiColor: ChatUIDesign.Color.pureWhite))
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background(configuration.isPressed
                ? Color(red: 0x2C / 255, green: 0x64 / 255, blue: 0x15 / 255)
                : Color(uiColor: ChatUIDesign.Color.offBlack))
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.85 : 1.0)
            .animation(.interactiveSpring(), value: configuration.isPressed)
    }
}

private struct RemoteGhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color(uiColor: ChatUIDesign.Color.offBlack))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(Color(uiColor: ChatUIDesign.Color.oatBorder), lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.9 : 1.0)
            .animation(.interactiveSpring(), value: configuration.isPressed)
    }
}

private struct RemoteIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color(uiColor: ChatUIDesign.Color.black60))
            .frame(width: 28, height: 28)
            .background(Color.clear)
            .scaleEffect(configuration.isPressed ? 0.85 : 1.0)
            .animation(.interactiveSpring(), value: configuration.isPressed)
    }
}

private struct RemoteRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                configuration.isPressed
                    ? Color(uiColor: ChatUIDesign.Color.warmCream)
                    : Color.clear
            )
            .contentShape(Rectangle())
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct RemoteScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.85 : 1.0)
            .animation(.interactiveSpring(), value: configuration.isPressed)
    }
}
