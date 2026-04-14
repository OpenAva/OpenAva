import CoreLocation
import Foundation
import OpenClawKit

@MainActor
final class LocationService: NSObject, CLLocationManagerDelegate, LocationServiceCommon {
    enum Error: Swift.Error {
        case timeout
        case unavailable
    }

    private let manager = CLLocationManager()
    private var authContinuation: CheckedContinuation<CLAuthorizationStatus, Never>?
    private var locationContinuation: CheckedContinuation<CLLocation, Swift.Error>?
    private var updatesContinuation: AsyncStream<CLLocation>.Continuation?
    private var isStreaming = false
    private var significantLocationCallback: (@Sendable (CLLocation) -> Void)?
    private var isMonitoringSignificantChanges = false

    var locationManager: CLLocationManager {
        manager
    }

    var locationRequestContinuation: CheckedContinuation<CLLocation, Swift.Error>? {
        get { locationContinuation }
        set { locationContinuation = newValue }
    }

    override init() {
        super.init()
        configureLocationManager()
    }

    func ensureAuthorization(mode: OpenClawLocationMode) async -> CLAuthorizationStatus {
        guard CLLocationManager.locationServicesEnabled() else { return .denied }

        let status = manager.authorizationStatus
        if status == .notDetermined {
            manager.requestWhenInUseAuthorization()
            let updated = await awaitAuthorizationChange()
            if mode != .always { return updated }
        }

        if mode == .always {
            let current = manager.authorizationStatus
            if current == .authorizedWhenInUse {
                manager.requestAlwaysAuthorization()
                return await awaitAuthorizationChange()
            }
            return current
        }

        return manager.authorizationStatus
    }

    func currentLocation(
        params: OpenClawLocationGetParams,
        desiredAccuracy: OpenClawLocationAccuracy,
        maxAgeMs: Int?,
        timeoutMs: Int?
    ) async throws -> CLLocation {
        _ = params
        return try await LocationCurrentRequest.resolve(
            manager: manager,
            desiredAccuracy: desiredAccuracy,
            maxAgeMs: maxAgeMs,
            timeoutMs: timeoutMs,
            request: { try await self.requestLocationOnce() },
            withTimeout: { timeoutMs, operation in
                try await self.withTimeout(timeoutMs: timeoutMs, operation: operation)
            }
        )
    }

    private func awaitAuthorizationChange() async -> CLAuthorizationStatus {
        await withCheckedContinuation { cont in
            self.authContinuation = cont
        }
    }

    private func withTimeout<T: Sendable>(
        timeoutMs: Int,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        do {
            return try await AsyncTimeout.withTimeoutMs(timeoutMs: timeoutMs, onTimeout: { Error.timeout }, operation: operation)
        } catch {
            if let locationError = error as? Error, case .timeout = locationError {
                cancelPendingLocationRequest(throwing: Error.timeout)
            }
            throw error
        }
    }

    private func cancelPendingLocationRequest(throwing error: Swift.Error) {
        guard let cont = locationContinuation else { return }
        locationContinuation = nil
        manager.stopUpdatingLocation()
        manager.stopMonitoringSignificantLocationChanges()
        cont.resume(throwing: error)
    }

    func startLocationUpdates(
        desiredAccuracy: OpenClawLocationAccuracy,
        significantChangesOnly: Bool
    ) -> AsyncStream<CLLocation> {
        stopLocationUpdates()

        manager.desiredAccuracy = LocationCurrentRequest.accuracyValue(desiredAccuracy)
        manager.pausesLocationUpdatesAutomatically = true
        manager.allowsBackgroundLocationUpdates = true

        isStreaming = true
        if significantChangesOnly {
            manager.startMonitoringSignificantLocationChanges()
        } else {
            manager.startUpdatingLocation()
        }

        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            self.updatesContinuation = continuation
            continuation.onTermination = { @Sendable _ in
                Task { @MainActor in
                    self.stopLocationUpdates()
                }
            }
        }
    }

    func stopLocationUpdates() {
        guard isStreaming else { return }
        isStreaming = false
        manager.stopUpdatingLocation()
        manager.stopMonitoringSignificantLocationChanges()
        updatesContinuation?.finish()
        updatesContinuation = nil
    }

    func startMonitoringSignificantLocationChanges(onUpdate: @escaping @Sendable (CLLocation) -> Void) {
        significantLocationCallback = onUpdate
        guard !isMonitoringSignificantChanges else { return }
        isMonitoringSignificantChanges = true
        manager.startMonitoringSignificantLocationChanges()
    }

    func stopMonitoringSignificantLocationChanges() {
        guard isMonitoringSignificantChanges else { return }
        isMonitoringSignificantChanges = false
        significantLocationCallback = nil
        manager.stopMonitoringSignificantLocationChanges()
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            if let cont = self.authContinuation {
                self.authContinuation = nil
                cont.resume(returning: status)
            }
        }
    }

    nonisolated func locationManager(_: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let locs = locations
        Task { @MainActor in
            // Resolve the one-shot continuation first, then fan out the same value to stream callbacks.
            if let cont = self.locationContinuation {
                self.locationContinuation = nil
                if let latest = locs.last {
                    cont.resume(returning: latest)
                } else {
                    cont.resume(throwing: Error.unavailable)
                }
            }

            if let callback = self.significantLocationCallback, let latest = locs.last {
                callback(latest)
            }
            if let latest = locs.last, let updates = self.updatesContinuation {
                updates.yield(latest)
            }
        }
    }

    nonisolated func locationManager(_: CLLocationManager, didFailWithError error: Swift.Error) {
        let err = error
        Task { @MainActor in
            if let clError = err as? CLError, clError.code == .locationUnknown {
                return
            }
            guard let cont = self.locationContinuation else { return }
            self.locationContinuation = nil
            cont.resume(throwing: err)
        }
    }
}
