import Foundation

struct AppLanguage: Identifiable, Hashable {
    let code: String
    let displayName: String
    var id: String { code }

    static let all: [AppLanguage] = [
        AppLanguage(code: "", displayName: ""),
        AppLanguage(code: "de", displayName: "Deutsch"),
        AppLanguage(code: "en", displayName: "English (US)"),
        AppLanguage(code: "en-GB", displayName: "English (UK)"),
        AppLanguage(code: "es", displayName: "Español"),
        AppLanguage(code: "fr", displayName: "Français"),
        AppLanguage(code: "it", displayName: "Italiano"),
        AppLanguage(code: "nl", displayName: "Nederlands"),
        AppLanguage(code: "pl", displayName: "Polski"),
        AppLanguage(code: "pt-PT", displayName: "Português (Portugal)"),
        AppLanguage(code: "pt-BR", displayName: "Português (Brasil)"),
        AppLanguage(code: "ja", displayName: "日本語"),
    ]
}

enum L10n {
    static let supportedCodes = [
        "de", "en", "en-GB", "es", "fr", "it", "nl", "pl", "pt-PT", "pt-BR", "ja",
    ]

    /// When non-nil and valid, overrides the system language live inside the app.
    static var languageOverride: String? = nil

    /// Resolves the resource root whether running from an `.app` bundle or SwiftPM (`swift test`).
    static var rootBundle: Bundle {
        if Bundle.main.url(forResource: "en", withExtension: "lproj") != nil {
            return Bundle.main
        }
        if let res = Bundle.main.resourceURL?.appendingPathComponent("VideoCrunch_VideoCrunch.bundle"),
           let bundle = Bundle(url: res) {
            return bundle
        }
        #if SWIFT_PACKAGE
        return Bundle.module
        #else
        return Bundle.main
        #endif
    }

    static func resolvedLanguageCode(
        override: String? = languageOverride,
        preferred: [String] = Locale.preferredLanguages
    ) -> String {
        if let override, supportedCodes.contains(override) {
            return override
        }
        if let match = Bundle.preferredLocalizations(from: supportedCodes, forPreferences: preferred).first {
            return match
        }
        for pref in preferred {
            let base = pref.split(separator: "-").first.map(String.init) ?? pref
            if supportedCodes.contains(base) {
                return base
            }
        }
        return "en"
    }

    static func bundle(forLanguage code: String? = nil, in root: Bundle = rootBundle) -> Bundle {
        let target = resolvedLanguageCode(override: code ?? languageOverride)
        for candidate in [target, target.lowercased(), "en"] {
            if let path = root.path(forResource: candidate, ofType: "lproj"),
               let b = Bundle(path: path) {
                return b
            }
        }
        return root
    }

    private static let missingMarker = "__VC_MISSING_KEY__"

    static func string(_ key: String, language: String? = nil) -> String {
        let root = rootBundle
        let localized = bundle(forLanguage: language, in: root)
            .localizedString(forKey: key, value: missingMarker, table: "Localizable")
        if localized != missingMarker {
            return localized
        }
        let fallback = bundle(forLanguage: "en", in: root)
            .localizedString(forKey: key, value: missingMarker, table: "Localizable")
        return fallback != missingMarker ? fallback : key
    }
}

func L(_ key: String) -> String {
    L10n.string(key)
}

func L(_ key: String, _ args: CVarArg...) -> String {
    String(format: L10n.string(key), arguments: args)
}
