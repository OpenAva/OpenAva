import CoreLocation
import Foundation

@MainActor
public protocol LocationServiceCommon: AnyObject, CLLocationManagerDelegate {
    var locationManager: CLLocationManager { get }
    var locationRequestContinuation: CheckedContinuation<CLLocation, Error>? { get set }
}

public extension LocationServiceCommon {
    func configureLocationManager() {
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
    }

    func authorizationStatus() -> CLAuthorizationStatus {
        locationManager.authorizationStatus
    }

    func accuracyAuthorization() -> CLAccuracyAuthorization {
        LocationServiceSupport.accuracyAuthorization(manager: locationManager)
    }

    func requestLocationOnce() async throws -> CLLocation {
        try await LocationServiceSupport.requestLocation(manager: locationManager) { continuation in
            self.locationRequestContinuation = continuation
        }
    }
}

public enum LocationServiceSupport {
    public static func accuracyAuthorization(manager: CLLocationManager) -> CLAccuracyAuthorization {
        if #available(iOS 14.0, macOS 11.0, *) {
            return manager.accuracyAuthorization
        }
        return .fullAccuracy
    }

    @MainActor
    public static func requestLocation(
        manager: CLLocationManager,
        setContinuation: @escaping (CheckedContinuation<CLLocation, Error>) -> Void
    ) async throws -> CLLocation {
        let status = manager.authorizationStatus
        switch status {
        case .authorizedAlways, .authorizedWhenInUse:
            break
        case .notDetermined:
            // Request foreground location permission before asking for a fix.
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            throw CLError(.denied)
        @unknown default:
            throw CLError(.denied)
        }

        return try await withCheckedThrowingContinuation { continuation in
            setContinuation(continuation)
            manager.requestLocation()
        }
    }
}
