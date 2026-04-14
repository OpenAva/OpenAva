import CoreLocation
import Foundation

public enum LocationCurrentRequest {
    private static let defaultTimeoutMs = 10_000
    private static let minimumTimeoutMs = 1_000

    public typealias TimeoutRunner = @Sendable (
        _ timeoutMs: Int,
        _ operation: @escaping @Sendable () async throws -> CLLocation
    ) async throws -> CLLocation

    @MainActor
    public static func resolve(
        manager: CLLocationManager,
        desiredAccuracy: OpenClawLocationAccuracy,
        maxAgeMs: Int?,
        timeoutMs: Int?,
        request: @escaping @Sendable () async throws -> CLLocation,
        withTimeout: TimeoutRunner
    ) async throws -> CLLocation {
        if let maxAgeMs,
           let cached = manager.location,
           isCachedLocationUsable(cached, maxAgeMs: maxAgeMs)
        {
            return cached
        }

        manager.desiredAccuracy = accuracyValue(desiredAccuracy)
        let timeout = normalizedTimeoutMs(timeoutMs)
        return try await withTimeout(timeout) {
            try await request()
        }
    }

    public static func normalizedTimeoutMs(_ timeoutMs: Int?) -> Int {
        guard let timeoutMs else { return defaultTimeoutMs }
        return max(minimumTimeoutMs, timeoutMs)
    }

    public static func isCachedLocationUsable(_ location: CLLocation, maxAgeMs: Int) -> Bool {
        guard maxAgeMs >= 0, location.horizontalAccuracy >= 0 else { return false }
        return Date().timeIntervalSince(location.timestamp) * 1000 <= Double(maxAgeMs)
    }

    public static func accuracyValue(_ accuracy: OpenClawLocationAccuracy) -> CLLocationAccuracy {
        switch accuracy {
        case .coarse:
            kCLLocationAccuracyKilometer
        case .balanced:
            kCLLocationAccuracyHundredMeters
        case .precise:
            kCLLocationAccuracyBest
        }
    }
}
