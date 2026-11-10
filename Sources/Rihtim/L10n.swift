import AppKit

/// UI language. English strings in the source are the keys; other languages
/// live in Resources/Localization/<code>.strings inside the app bundle.
///
/// We don't use the system .lproj lookup on purpose: the language can be picked
/// in Settings independently of the macOS language, and SwiftUI's automatic
/// `Text("…")` localization would otherwise follow the system instead.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system, en, tr, de
    var id: String { rawValue }

    /// Shown in its own language so it's recognizable whatever the current UI is.
    var nativeName: String {
        switch self {
        case .system: return L("System")
        case .en: return "English"
        case .tr: return "Türkçe"
        case .de: return "Deutsch"
        }
    }
}

enum L10n {
    static let prefKey = "app.language"
    static let supported = ["en", "tr", "de"]

    /// Language the UI was started with. Changing the preference takes effect after a relaunch.
    static let code: String = resolve(UserDefaults.standard.string(forKey: prefKey))

    /// The user's own locale when it matches the UI language (keeps their 12/24 h and
    /// date settings), otherwise a plain locale for that language.
    static let locale: Locale = {
        if Locale.current.language.languageCode?.identifier == code { return .current }
        switch code {
        case "tr": return Locale(identifier: "tr_TR")
        case "de": return Locale(identifier: "de_DE")
        default: return Locale(identifier: "en_US")
        }
    }()

    static func resolve(_ pref: String?) -> String {
        if let p = pref, p != AppLanguage.system.rawValue, supported.contains(p) { return p }
        for lang in Locale.preferredLanguages {
            let base = String(lang.prefix(2))
            if supported.contains(base) { return base }
        }
        return "en"
    }

    private static let table: [String: String] = {
        guard code != "en" else { return [:] }
        let candidates: [URL?] = [
            Bundle.main.url(forResource: code, withExtension: "strings", subdirectory: "Localization"),
            // `swift run` has no app bundle; read straight from the repo.
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Resources/Localization/\(code).strings"),
        ]
        for case let url? in candidates {
            if let dict = NSDictionary(contentsOf: url) as? [String: String] { return dict }
        }
        return [:]
    }()

    static func string(_ key: String) -> String { table[key] ?? key }
}

/// Translated UI string.
func L(_ key: String) -> String { L10n.string(key) }

/// Translated format string, e.g. `L("%d windows", n)`.
func L(_ key: String, _ args: CVarArg...) -> String {
    String(format: L10n.string(key), locale: L10n.locale, arguments: args)
}
