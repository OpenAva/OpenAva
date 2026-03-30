import Foundation

extension String {
    static func localized(
        _ value: String.LocalizationValue,
        table: String? = nil,
        bundle: Bundle = .module
    ) -> String {
        String(localized: value, table: table, bundle: bundle)
    }
}
