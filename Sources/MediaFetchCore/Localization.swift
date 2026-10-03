import Foundation

/// Runtime lookups for keys that cannot be string literals at the call site,
/// such as Chinese enum raw values that are persisted in history and must not
/// change. Literal UI text uses SwiftUI's automatic lookup or
/// `String(localized:)`; both read the same tables in the app bundle.
public enum L10n {
    public static func string(_ key: String) -> String {
        Bundle.main.localizedString(forKey: key, value: key, table: nil)
    }

    /// Languages offered in Settings, in display order. `nil` follows the system.
    public static let supportedLanguages: [(code: String, name: String)] = [
        ("en", "English"), ("fr", "Français"), ("de", "Deutsch"),
        ("ja", "日本語"), ("ko", "한국어"), ("zh-Hans", "中文（简体）")
    ]

    static let overrideKey = "AppleLanguages"

    /// The language chosen in Settings, or nil when following the system.
    public static func chosenLanguage(in defaults: UserDefaults = .standard) -> String? {
        guard defaults.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?[overrideKey] != nil,
              let first = (defaults.array(forKey: overrideKey) as? [String])?.first else { return nil }
        return supportedLanguages.first { first.hasPrefix($0.code) }?.code
    }

    /// Takes effect on next launch (AppKit reads the language list at startup).
    public static func choose(_ code: String?, in defaults: UserDefaults = .standard) {
        if let code { defaults.set([code], forKey: overrideKey) } else { defaults.removeObject(forKey: overrideKey) }
    }
}
