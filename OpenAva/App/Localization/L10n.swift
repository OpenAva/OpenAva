import Foundation

protocol LocalizationServing {
    func text(_ key: String, _ args: CVarArg...) -> String
}

struct LocalizationService: LocalizationServing {
    private let tableName: String
    private let bundleProvider: () -> Bundle

    init(tableName: String = "Localizable", bundle: Bundle = .main) {
        self.tableName = tableName
        bundleProvider = { bundle }
    }

    init(tableName: String = "Localizable", bundleProvider: @escaping () -> Bundle) {
        self.tableName = tableName
        self.bundleProvider = bundleProvider
    }

    func text(_ key: String, _ args: CVarArg...) -> String {
        text(key, arguments: args)
    }

    func text(_ key: String, arguments: [CVarArg]) -> String {
        let bundle = bundleProvider()
        let format = bundle.localizedString(forKey: key, value: key, table: tableName)
        guard !arguments.isEmpty else {
            return format
        }
        // Format localized strings in a single place to avoid scattered logic.
        return String(format: format, locale: .current, arguments: arguments)
    }
}

enum L10n {
    static let shared = LocalizationService(bundleProvider: {
        // When the user has explicitly chosen a language in-app, load that specific bundle.
        // Otherwise fall back to Bundle.main, which uses iOS's native language negotiation
        // (respecting Locale.preferredLanguages automatically).
        if let userCode = AppLanguagePreference.userPreferredLanguageCode() {
            return LocaleResolver.bundle(for: userCode)
        }
        return .main
    })

    static func tr(_ key: String, _ args: CVarArg...) -> String {
        shared.text(key, arguments: args)
    }
}
