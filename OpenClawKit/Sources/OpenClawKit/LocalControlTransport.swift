import Foundation
import Network
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

public final class LocalControlAdvertiser {
    private var listener: NWListener?
    private let queue: DispatchQueue

    public init(queueLabel: String = "ai.openava.local-control.listener") {
        queue = DispatchQueue(label: queueLabel)
    }

    public func start(
        config: LocalControlTransportConfig,
        newConnectionHandler: @escaping @Sendable (NWConnection) -> Void
    ) throws {
        guard listener == nil else { return }
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let listener = try NWListener(using: parameters, on: .any)
        listener.service = NWListener.Service(name: config.serviceName, type: config.serviceType)
        listener.newConnectionHandler = newConnectionHandler
        listener.stateUpdateHandler = { _ in }
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
    private var browser: NWBrowser?
    private var servicesByID: [String: LocalControlDiscoveredService] = [:]
    private var pendingResolvers: [String: ServiceResolver] = [:]
    private let queueLabelPrefix: String
    public var onServicesChanged: (([LocalControlDiscoveredService]) -> Void)?

    public init(queueLabelPrefix: String = "ai.openava.local-control.browser") {
        self.queueLabelPrefix = queueLabelPrefix
    }

    public func start() {
        guard browser == nil else { return }
        browser = GatewayDiscoveryBrowserSupport.makeBrowser(
            serviceType: OpenClawBonjour.localControlServiceType,
            domain: OpenClawBonjour.gatewayServiceDomain,
            queueLabelPrefix: queueLabelPrefix,
            onState: { _ in },
            onResults: { [weak self] results in
                self?.handle(results)
            }
        )
    }

    public func stop() {
        browser?.cancel()
        browser = nil
        pendingResolvers.values.forEach { $0.cancel() }
        pendingResolvers.removeAll()
        servicesByID.removeAll()
        onServicesChanged?([])
    }

    private func handle(_ results: Set<NWBrowser.Result>) {
        let ids = Set(results.compactMap(Self.identifier(for:)))
        let staleIDs = Set(servicesByID.keys).subtracting(ids)
        for staleID in staleIDs {
            servicesByID.removeValue(forKey: staleID)
            pendingResolvers[staleID]?.cancel()
            pendingResolvers.removeValue(forKey: staleID)
        }
        for result in results {
            guard case let .service(name: name, type: _, domain: domain, interface: _) = result.endpoint,
                  let id = Self.identifier(for: result),
                  pendingResolvers[id] == nil,
                  servicesByID[id] == nil
            else {
                continue
            }
            let resolver = ServiceResolver(id: id, name: name, domain: domain) { [weak self] resolved in
                guard let self, let resolved else { return }
                self.pendingResolvers[resolved.id] = nil
                self.servicesByID[resolved.id] = resolved
                self.publishServices()
            }
            pendingResolvers[id] = resolver
            resolver.start()
        }
        publishServices()
    }

    private func publishServices() {
        let services = servicesByID.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        onServicesChanged?(services)
    }

    private static func identifier(for result: NWBrowser.Result) -> String? {
        guard case let .service(name: name, type: type, domain: domain, interface: _) = result.endpoint else {
            return nil
        }
        return [name, type, domain].joined(separator: "|")
    }
}

@MainActor
private final class ServiceResolver: NSObject, NetServiceDelegate {
    let id: String
    private let service: NetService
    private let completion: (LocalControlDiscoveredService?) -> Void
    private var didFinish = false

    init(id: String, name: String, domain: String, completion: @escaping (LocalControlDiscoveredService?) -> Void) {
        self.id = id
        service = NetService(domain: domain, type: OpenClawBonjour.localControlServiceType, name: name)
        self.completion = completion
        super.init()
        service.delegate = self
    }

    func start() {
        BonjourServiceResolverSupport.start(service, timeout: 2.0)
    }

    func cancel() {
        finish(nil)
    }

    nonisolated func netServiceDidResolveAddress(_ sender: NetService) {
        let hostName = sender.hostName
        let port = sender.port
        let name = sender.name
        let domain = sender.domain
        Task { @MainActor in
            guard let host = BonjourServiceResolverSupport.normalizeHost(hostName), port > 0 else {
                finish(nil)
                return
            }
            finish(.init(id: id, name: name, host: host, port: port, domain: domain))
        }
    }

    nonisolated func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        _ = sender
        _ = errorDict
        Task { @MainActor in
            finish(nil)
        }
    }

    private func finish(_ serviceInfo: LocalControlDiscoveredService?) {
        guard !didFinish else { return }
        didFinish = true
        service.stop()
        service.remove(from: .main, forMode: .common)
        completion(serviceInfo)
    }
}
