import Foundation
import Network
import OSLog
import OpenClawProtocol

public struct LocalControlTransportConfig: Sendable {
    public var serviceName: String
    public var serviceType: String
    public var queueLabel: String

    public init(
        serviceName: String,
        serviceType: String = OpenClawBonjour.localControlServiceType,
        queueLabel: String = "ai.openava.local-control"
    ) {
        self.serviceName = serviceName
        self.serviceType = serviceType
        self.queueLabel = queueLabel
    }
}

public enum LocalControlAdvertiserStatus: Sendable {
    case setup
    case ready(port: UInt16?)
    case waiting(String)
    case failed(String)
    case serviceRegistered(String)
    case serviceRemoved(String)
    case cancelled
}

public struct LocalControlBrowserDiagnostics: Sendable, Equatable {
    public var rawResultCount: Int
    public var resolvedServiceCount: Int
    public var pendingResolutionCount: Int
    public var resolutionFailureCount: Int
    public var lastResolutionFailure: String?

    public init(
        rawResultCount: Int = 0,
        resolvedServiceCount: Int = 0,
        pendingResolutionCount: Int = 0,
        resolutionFailureCount: Int = 0,
        lastResolutionFailure: String? = nil
    ) {
        self.rawResultCount = rawResultCount
        self.resolvedServiceCount = resolvedServiceCount
        self.pendingResolutionCount = pendingResolutionCount
        self.resolutionFailureCount = resolutionFailureCount
        self.lastResolutionFailure = lastResolutionFailure
    }
}

public final class LocalControlAdvertiser {
    private var listener: NWListener?
    private let queue: DispatchQueue
    private let logger = Logger(subsystem: "ai.openava", category: "local-control.advertiser")

    public init(queueLabel: String = "ai.openava.local-control.listener") {
        queue = DispatchQueue(label: queueLabel)
    }

    public func start(
        config: LocalControlTransportConfig,
        onStateChanged: (@Sendable (LocalControlAdvertiserStatus) -> Void)? = nil,
        newConnectionHandler: @escaping @Sendable (NWConnection) -> Void
    ) throws {
        guard listener == nil else { return }
        let logger = self.logger
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let listener = try NWListener(using: parameters, on: .any)
        listener.service = NWListener.Service(name: config.serviceName, type: config.serviceType)
        listener.newConnectionHandler = newConnectionHandler
        listener.stateUpdateHandler = { [weak listener] state in
            let port = listener?.port?.rawValue
            let status: LocalControlAdvertiserStatus
            switch state {
            case .setup:
                status = .setup
            case .ready:
                status = .ready(port: port)
            case let .waiting(error):
                status = .waiting(error.localizedDescription)
            case let .failed(error):
                status = .failed(error.localizedDescription)
            case .cancelled:
                status = .cancelled
            @unknown default:
                status = .failed("Unknown advertiser state")
            }
            logger.debug("Local control advertiser state changed: \(String(describing: status), privacy: .public)")
            onStateChanged?(status)
        }
        listener.serviceRegistrationUpdateHandler = { change in
            let status: LocalControlAdvertiserStatus
            switch change {
            case let .add(endpoint):
                status = .serviceRegistered(String(describing: endpoint))
            case let .remove(endpoint):
                status = .serviceRemoved(String(describing: endpoint))
            @unknown default:
                status = .failed("Unknown service registration change")
            }
            logger.info("Local control service registration update: \(String(describing: status), privacy: .public)")
            onStateChanged?(status)
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    public var port: UInt16? {
        guard let value = listener?.port?.rawValue else { return nil }
        return value
    }
}

public protocol LocalControlConnectionDelegate: AnyObject {
    func localControlConnection(_ connection: LocalControlConnection, didReceiveText text: String)
    func localControlConnectionDidClose(_ connection: LocalControlConnection)
}

public final class LocalControlConnection: @unchecked Sendable {
    public let connection: NWConnection
    private let queue: DispatchQueue
    private var isClosed = false
    private var receiveBuffer = Data()
    public weak var delegate: LocalControlConnectionDelegate?

    public init(connection: NWConnection, queueLabel: String) {
        self.connection = connection
        queue = DispatchQueue(label: queueLabel)
    }

    public func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.receiveNext()
            case .failed, .cancelled:
                self.closeIfNeeded()
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    public func sendText(_ text: String) {
        let payload = (text + "\n").data(using: .utf8) ?? Data()
        connection.send(content: payload, completion: .contentProcessed { [weak self] error in
            if error != nil {
                self?.closeIfNeeded()
            }
        })
    }

    public func cancel() {
        closeIfNeeded()
    }

    private func receiveNext() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.receiveBuffer.append(data)
                self.flushFramesIfNeeded()
            }
            if isComplete || error != nil {
                self.closeIfNeeded()
            } else {
                self.receiveNext()
            }
        }
    }

    private func flushFramesIfNeeded() {
        let delimiter = Data([0x0A])
        while let range = receiveBuffer.range(of: delimiter) {
            let frame = receiveBuffer.subdata(in: receiveBuffer.startIndex ..< range.lowerBound)
            receiveBuffer.removeSubrange(receiveBuffer.startIndex ... range.lowerBound)
            guard !frame.isEmpty, let text = String(data: frame, encoding: .utf8) else { continue }
            delegate?.localControlConnection(self, didReceiveText: text)
        }
    }

    private func closeIfNeeded() {
        guard !isClosed else { return }
        isClosed = true
        connection.cancel()
        delegate?.localControlConnectionDidClose(self)
    }
}

@MainActor
public final class LocalControlBrowser: NSObject {
    private let logger = Logger(subsystem: "ai.openava", category: "local-control.browser")
    private var browser: NWBrowser?
    private var servicesByID: [String: LocalControlDiscoveredService] = [:]
    private var pendingResolvers: [String: ServiceResolver] = [:]
    private var restartTask: Task<Void, Never>?
    private var isRunning = false
    private let queueLabelPrefix: String
    private var diagnostics = LocalControlBrowserDiagnostics()
    public var onServicesChanged: (([LocalControlDiscoveredService]) -> Void)?
    public var onStateChanged: ((NWBrowser.State) -> Void)?
    public var onDiagnosticsChanged: ((LocalControlBrowserDiagnostics) -> Void)?

    public init(queueLabelPrefix: String = "ai.openava.local-control.browser") {
        self.queueLabelPrefix = queueLabelPrefix
    }

    public func start() {
        isRunning = true
        resetDiagnostics()
        guard browser == nil else { return }
        startBrowser()
    }

    public func restart() {
        stop()
        start()
    }

    private func startBrowser() {
        browser = GatewayDiscoveryBrowserSupport.makeBrowser(
            serviceType: OpenClawBonjour.localControlServiceType,
            domain: OpenClawBonjour.gatewayServiceDomain,
            queueLabelPrefix: queueLabelPrefix,
            onState: { [weak self] state in
                self?.handle(state: state)
            },
            onResults: { [weak self] results in
                self?.handle(results)
            }
        )
    }

    public func stop() {
        isRunning = false
        restartTask?.cancel()
        restartTask = nil
        let activeBrowser = browser
        browser = nil
        activeBrowser?.cancel()
        clearResolvedServices()
        resetDiagnostics()
    }

    private func handle(_ results: Set<NWBrowser.Result>) {
        let ids = Set(results.compactMap(Self.identifier(for:)))
        diagnostics.rawResultCount = ids.count
        let knownIDs = Set(servicesByID.keys).union(pendingResolvers.keys)
        let staleIDs = knownIDs.subtracting(ids)
        for staleID in staleIDs {
            servicesByID.removeValue(forKey: staleID)
            pendingResolvers[staleID]?.cancel()
            pendingResolvers.removeValue(forKey: staleID)
        }
        logger.debug(
            "Local control browse results changed. raw=\(ids.count, privacy: .public) resolved=\(self.servicesByID.count, privacy: .public) pending=\(self.pendingResolvers.count, privacy: .public)"
        )
        for result in results {
            guard case let .service(name: name, type: _, domain: domain, interface: _) = result.endpoint,
                  let id = Self.identifier(for: result),
                  pendingResolvers[id] == nil,
                  servicesByID[id] == nil
            else {
                continue
            }
            logger.debug(
                "Resolving local control service '\(name, privacy: .public)' in domain '\(domain, privacy: .public)'"
            )
            let resolver = ServiceResolver(id: id, name: name, domain: domain) { [weak self] outcome in
                guard let self else { return }
                self.pendingResolvers[id] = nil
                switch outcome {
                case let .resolved(resolved):
                    self.servicesByID[resolved.id] = resolved
                    self.logger.info(
                        "Resolved local control service '\(resolved.name, privacy: .public)' at \(resolved.host, privacy: .public):\(resolved.port, privacy: .public)"
                    )
                case let .failed(message):
                    self.diagnostics.resolutionFailureCount += 1
                    self.diagnostics.lastResolutionFailure = message
                    self.logger.error(
                        "Failed to resolve local control service '\(name, privacy: .public)' in domain '\(domain, privacy: .public)': \(message, privacy: .public)"
                    )
                case .cancelled:
                    self.logger.debug(
                        "Cancelled local control service resolution for '\(name, privacy: .public)' in domain '\(domain, privacy: .public)'"
                    )
                }
                self.publishDiagnostics()
                self.publishServices()
            }
            pendingResolvers[id] = resolver
            publishDiagnostics()
            resolver.start()
        }
        publishDiagnostics()
        publishServices()
    }

    private func publishServices() {
        let services = servicesByID.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        onServicesChanged?(services)
    }

    private func publishDiagnostics() {
        diagnostics.resolvedServiceCount = servicesByID.count
        diagnostics.pendingResolutionCount = pendingResolvers.count
        onDiagnosticsChanged?(diagnostics)
    }

    private func resetDiagnostics() {
        diagnostics = .init()
        publishDiagnostics()
    }

    private func clearResolvedServices() {
        pendingResolvers.values.forEach { $0.cancel() }
        pendingResolvers.removeAll()
        servicesByID.removeAll()
        publishServices()
    }

    private func handle(state: NWBrowser.State) {
        onStateChanged?(state)
        guard isRunning else { return }
        switch state {
        case .failed:
            let activeBrowser = browser
            browser = nil
            activeBrowser?.cancel()
            clearResolvedServices()
            scheduleRestart()
        default:
            break
        }
    }

    private func scheduleRestart() {
        restartTask?.cancel()
        restartTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.isRunning, self.browser == nil else { return }
                self.startBrowser()
            }
        }
    }

    private static func identifier(for result: NWBrowser.Result) -> String? {
        guard case let .service(name: name, type: type, domain: domain, interface: _) = result.endpoint else {
            return nil
        }
        return [name, type, domain].joined(separator: "|")
    }
}

private enum ServiceResolutionOutcome {
    case resolved(LocalControlDiscoveredService)
    case failed(String)
    case cancelled
}

@MainActor
private final class ServiceResolver: NSObject, NetServiceDelegate {
    private static let resolveTimeout: TimeInterval = 5.0
    private static let maxAttempts = 3
    private static let retryDelayNs: UInt64 = 750_000_000

    let id: String
    private let name: String
    private let domain: String
    private let completion: (ServiceResolutionOutcome) -> Void
    private var service: NetService?
    private var didFinish = false
    private var attempts = 0
    private var retryTask: Task<Void, Never>?
    private var lastFailureMessage: String?

    init(id: String, name: String, domain: String, completion: @escaping (ServiceResolutionOutcome) -> Void) {
        self.id = id
        self.name = name
        self.domain = domain
        self.completion = completion
        super.init()
    }

    func start() {
        beginResolve()
    }

    func cancel() {
        finish(.cancelled)
    }

    private func beginResolve() {
        guard !didFinish else { return }
        attempts += 1
        teardownService()
        let service = NetService(domain: domain, type: OpenClawBonjour.localControlServiceType, name: name)
        service.delegate = self
        self.service = service
        BonjourServiceResolverSupport.start(service, timeout: Self.resolveTimeout)
    }

    nonisolated func netServiceDidResolveAddress(_ sender: NetService) {
        let hostName = sender.hostName
        let port = sender.port
        let name = sender.name
        let domain = sender.domain
        Task { @MainActor in
            guard let host = BonjourServiceResolverSupport.normalizeHost(hostName), port > 0 else {
                let hostDescription = hostName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "nil"
                finish(.failed("Bonjour resolve returned host=\(hostDescription), port=\(port)"))
                return
            }
            finish(.resolved(.init(id: id, name: name, host: host, port: port, domain: domain)))
        }
    }

    nonisolated func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        _ = sender
        let details = errorDict
            .map { "\($0.key)=\($0.value)" }
            .sorted()
            .joined(separator: ", ")
        Task { @MainActor in
            lastFailureMessage = details.isEmpty
                ? "NetService did not resolve the Bonjour service"
                : "NetService did not resolve the Bonjour service (\(details))"
            handleResolveFailure()
        }
    }

    private func handleResolveFailure() {
        guard !didFinish else { return }
        teardownService()
        guard attempts < Self.maxAttempts else {
            finish(.failed(lastFailureMessage ?? "NetService did not resolve the Bonjour service"))
            return
        }
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.retryDelayNs)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.beginResolve()
            }
        }
    }

    private func finish(_ outcome: ServiceResolutionOutcome) {
        guard !didFinish else { return }
        didFinish = true
        retryTask?.cancel()
        retryTask = nil
        teardownService()
        completion(outcome)
    }

    private func teardownService() {
        service?.stop()
        service?.remove(from: .main, forMode: .common)
        service?.delegate = nil
        service = nil
    }
}
