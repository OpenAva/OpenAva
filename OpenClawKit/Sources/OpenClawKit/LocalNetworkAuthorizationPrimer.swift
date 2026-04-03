import Foundation
import Network

public enum LocalNetworkAuthorizationPrimer {
    public enum Result: Sendable, Equatable {
        case ready
        case waiting(String)
        case failed(String)
        case timedOut
    }

    public static func primeBonjourAuthorization(
        serviceType: String,
        domain: String,
        timeout: TimeInterval = 2.0,
        queueLabel: String = "ai.openava.local-network.primer"
    ) async -> Result {
        let params = NWParameters.tcp
        params.includePeerToPeer = true
        let browser = NWBrowser(
            for: .bonjour(type: serviceType, domain: domain),
            using: params
        )

        return await withCheckedContinuation { continuation in
            let box = PrimerContinuationBox(continuation: continuation, browser: browser)

            browser.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    box.finish(.ready)
                case let .waiting(error):
                    box.finish(.waiting(error.localizedDescription))
                case let .failed(error):
                    box.finish(.failed(error.localizedDescription))
                case .cancelled:
                    box.finish(.failed("Cancelled"))
                case .setup:
                    break
                @unknown default:
                    box.finish(.failed("Unknown local network authorization state"))
                }
            }

            browser.start(queue: DispatchQueue(label: "\(queueLabel).\(domain)"))

            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                box.finish(.timedOut)
            }
        }
    }
}

private final class PrimerContinuationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<LocalNetworkAuthorizationPrimer.Result, Never>?
    private var browser: NWBrowser?

    init(continuation: CheckedContinuation<LocalNetworkAuthorizationPrimer.Result, Never>, browser: NWBrowser) {
        self.continuation = continuation
        self.browser = browser
    }

    func finish(_ result: LocalNetworkAuthorizationPrimer.Result) {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return
        }
        self.continuation = nil
        let browser = self.browser
        self.browser = nil
        lock.unlock()

        browser?.cancel()
        continuation.resume(returning: result)
    }
}
