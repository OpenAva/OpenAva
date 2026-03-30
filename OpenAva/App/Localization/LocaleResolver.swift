import Foundation

enum AppLanguagePreference {
    static let userDefaultsKey = "app.preferredLanguageCode"

    static func userPreferredLanguageCode(defaults: UserDefaults = .standard) -> String? {
        let value = defaults.string(forKey: userDefaultsKey)
        return LocaleResolver.normalize(code: value)
    }

    static func setUserPreferredLanguageCode(_ code: String?, defaults: UserDefaults = .standard) {
        let normalized = LocaleResolver.normalize(code: code)
        if let normalized {
            defaults.set(normalized, forKey: userDefaultsKey)
        } else {
            defaults.removeObject(forKey: userDefaultsKey)
        }
    }

    /// Remove a stale "en" override — English is the implicit fallback and
    /// should not be stored as an explicit preference.
    static func clearStaleEnglishOverride(defaults: UserDefaults = .standard) {
        let stored = defaults.string(forKey: userDefaultsKey)
        if stored == "en" {
            defaults.removeObject(forKey: userDefaultsKey)
        }
    }
}

enum LocaleResolver {
    static let supportedLanguageCodes: Set<String> = ["en", "zh-Hans", "zh-Hant"]

    static func resolvedLanguageCode(userPreferredCode: String?, systemPreferredCodes: [String]) -> String {
        if let normalizedUserCode = normalize(code: userPreferredCode),
           supportedLanguageCodes.contains(normalizedUserCode)
        {
            return normalizedUserCode
        }

        for code in systemPreferredCodes {
            if let normalizedSystemCode = normalize(code: code),
               supportedLanguageCodes.contains(normalizedSystemCode)
            {
                return normalizedSystemCode
            }
        }

        return "en"
    }

    static func currentLanguageCode(defaults: UserDefaults = .standard) -> String {
        resolvedLanguageCode(
            userPreferredCode: AppLanguagePreference.userPreferredLanguageCode(defaults: defaults),
            systemPreferredCodes: Locale.preferredLanguages
        )
    }

    static func bundle(for languageCode: String, in baseBundle: Bundle = .main) -> Bundle {
        if let path = baseBundle.path(forResource: languageCode, ofType: "lproj"),
           let bundle = Bundle(path: path)
        {
            return bundle
        }

        // Fallback to Simplified Chinese when Traditional resources are missing.
        if languageCode == "zh-Hant",
           let path = baseBundle.path(forResource: "zh-Hans", ofType: "lproj"),
           let bundle = Bundle(path: path)
        {
            return bundle
        }

        if let path = baseBundle.path(forResource: "en", ofType: "lproj"),
           let bundle = Bundle(path: path)
        {
            return bundle
        }

        return baseBundle
    }

    static func normalize(code: String?) -> String? {
        guard let rawCode = code?.trimmingCharacters(in: .whitespacesAndNewlines), !rawCode.isEmpty else {
            return nil
        }

        let locale = Locale(identifier: rawCode)
        let scriptCode = locale.scriptCode?.lowercased()
        let languageCode = locale.language.languageCode?.identifier.lowercased() ?? locale.languageCode?.lowercased() ?? ""
        let regionCode = locale.region?.identifier.uppercased() ?? locale.regionCode?.uppercased()

        guard languageCode == "zh" || languageCode == "en" else {
            return languageCode
        }

        if languageCode == "en" {
            return "en"
        }

        if scriptCode == "hant" || regionCode == "HK" || regionCode == "MO" || regionCode == "TW" {
            return "zh-Hant"
        }
        return "zh-Hans"
    }
}
