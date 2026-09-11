import Foundation
import SwiftUI

/// One supported UI language. `autonym` is the language's own name so the picker
/// reads naturally to a speaker of that language.
struct AppLanguage: Identifiable, Hashable {
    let code: String        // .lproj folder / AppleLanguages code
    let autonym: String     // endonym shown in the picker
    var id: String { code }
}

enum Languages {
    /// Kept in sync with the generated .lproj folders and Info.plist.
    static let all: [AppLanguage] = [
        .init(code: "en",       autonym: "English"),
        .init(code: "de",       autonym: "Deutsch"),
        .init(code: "fr",       autonym: "Français"),
        .init(code: "es",       autonym: "Español"),
        .init(code: "it",       autonym: "Italiano"),
        .init(code: "pt-BR",    autonym: "Português (Brasil)"),
        .init(code: "nl",       autonym: "Nederlands"),
        .init(code: "sv",       autonym: "Svenska"),
        .init(code: "da",       autonym: "Dansk"),
        .init(code: "nb",       autonym: "Norsk bokmål"),
        .init(code: "fi",       autonym: "Suomi"),
        .init(code: "pl",       autonym: "Polski"),
        .init(code: "cs",       autonym: "Čeština"),
        .init(code: "ru",       autonym: "Русский"),
        .init(code: "uk",       autonym: "Українська"),
        .init(code: "tr",       autonym: "Türkçe"),
        .init(code: "el",       autonym: "Ελληνικά"),
        .init(code: "ro",       autonym: "Română"),
        .init(code: "hu",       autonym: "Magyar"),
        .init(code: "id",       autonym: "Bahasa Indonesia"),
        .init(code: "ja",       autonym: "日本語"),
        .init(code: "ko",       autonym: "한국어"),
        .init(code: "zh-Hans",  autonym: "简体中文"),
        .init(code: "zh-Hant",  autonym: "繁體中文"),
        .init(code: "ar",       autonym: "العربية"),
        .init(code: "he",       autonym: "עברית"),
    ]
}

/// Resolves the active bundle for string lookups. Supports an in-app language
/// override that takes effect live (for our own strings) and, via AppleLanguages,
/// for system-provided text after the next launch.
final class LanguageManager: ObservableObject {
    static let shared = LanguageManager()

    @Published private(set) var activeCode: String = ""
    private(set) var bundle: Bundle = .main

    func applyStored() { apply(Preferences.shared.appLanguage, persist: false) }

    func apply(_ code: String, persist: Bool = true) {
        if code.isEmpty {
            bundle = .main
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else if let path = Bundle.main.path(forResource: code, ofType: "lproj"),
                  let b = Bundle(path: path) {
            bundle = b
            UserDefaults.standard.set([code], forKey: "AppleLanguages")
        } else {
            bundle = .main
        }
        activeCode = code
        if persist { Preferences.shared.appLanguage = code }
        objectWillChange.send()
    }

    var isRTL: Bool { activeCode == "ar" || activeCode == "he" }
}

/// Localized string lookup honoring the in-app override.
func L(_ key: String) -> String {
    LanguageManager.shared.bundle.localizedString(forKey: key, value: key, table: "Localizable")
}

/// Localized + formatted.
func L(_ key: String, _ args: CVarArg...) -> String {
    let fmt = LanguageManager.shared.bundle.localizedString(forKey: key, value: key, table: "Localizable")
    return String(format: fmt, arguments: args)
}
