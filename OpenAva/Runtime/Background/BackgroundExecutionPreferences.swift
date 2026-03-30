import Foundation
import Observation

private let kBackgroundExecutionEnabled = "background.execution.enabled"

/// Stores the global preference for running agent tasks in background.
@Observable
final class BackgroundExecutionPreferences {
    static let shared = BackgroundExecutionPreferences()

    var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: kBackgroundExecutionEnabled)
        }
    }

    private init() {
        isEnabled = UserDefaults.standard.bool(forKey: kBackgroundExecutionEnabled)
    }
}
