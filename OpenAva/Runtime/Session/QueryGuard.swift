import Combine
import Foundation

/// Synchronous execution guard for a session query lifecycle.
///
/// Three states:
/// - `idle`: no query, safe to submit
/// - `dispatching`: submission accepted, async execution has not started yet
/// - `running`: query task is executing
@MainActor
final class QueryGuard {
    private enum Status {
        case idle
        case dispatching
        case running
    }

    private var status: Status = .idle
    private var generation: Int = 0
    private let activitySubject = CurrentValueSubject<Bool, Never>(false)

    var activityDidChange: AnyPublisher<Bool, Never> {
        activitySubject.eraseToAnyPublisher()
    }

    var isActive: Bool {
        status != .idle
    }

    /// Reserves the guard for a submission that has been accepted but has not
    /// reached the async execution entrypoint yet.
    ///
    /// Returns the current generation snapshot so callers can later verify that
    /// the reservation was not invalidated by an interrupt.
    func reserve() -> Int? {
        guard status == .idle else { return nil }
        status = .dispatching
        publishActivity()
        return generation
    }

    func cancelReservation() {
        guard status == .dispatching else { return }
        status = .idle
        publishActivity()
    }

    func tryStart(expectedGeneration: Int? = nil) -> Int? {
        guard status != .running else { return nil }
        if let expectedGeneration {
            guard status == .dispatching, generation == expectedGeneration else { return nil }
        }
        status = .running
        generation += 1
        publishActivity()
        return generation
    }

    @discardableResult
    func end(_ generation: Int) -> Bool {
        guard self.generation == generation, status == .running else { return false }
        status = .idle
        publishActivity()
        return true
    }

    func forceEnd() {
        guard status != .idle else { return }
        status = .idle
        generation += 1
        publishActivity()
    }

    private func publishActivity() {
        activitySubject.send(isActive)
    }
}
