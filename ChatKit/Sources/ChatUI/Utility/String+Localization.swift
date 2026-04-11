import Foundation

public extension String {
    static func localized(
        _ value: String.LocalizationValue,
        table: String? = nil,
        bundle: Bundle? = nil
    ) -> String {
        String(localized: value, table: table, bundle: bundle ?? .module)
    }
}
