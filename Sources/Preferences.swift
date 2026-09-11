import Foundation
import Combine

extension Notification.Name {
    static let tidierPrefsChanged = Notification.Name("de.csho.Tidier.prefsChanged")
}

enum PrefKey {
    static let launchAtLogin      = "launchAtLogin"
    static let autoRehide         = "autoRehide"
    static let rehideInterval     = "rehideInterval"
    static let enableAlwaysHidden = "enableAlwaysHidden"
    static let revealOnHover      = "revealOnHover"
    static let appLanguage        = "appLanguage"   // "" = follow system
}

/// Thin observable wrapper over UserDefaults so SwiftUI can bind directly and
/// the rest of the app can react through `.tidierPrefsChanged`.
final class Preferences: ObservableObject {
    static let shared = Preferences()
    private let d = UserDefaults.standard

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            PrefKey.launchAtLogin:      false,
            PrefKey.autoRehide:         true,
            PrefKey.rehideInterval:     15,
            PrefKey.enableAlwaysHidden: false,
            PrefKey.revealOnHover:      false,
            PrefKey.appLanguage:        "",
        ])
    }

    private func changed() {
        objectWillChange.send()
        NotificationCenter.default.post(name: .tidierPrefsChanged, object: nil)
    }

    var launchAtLogin: Bool {
        get { d.bool(forKey: PrefKey.launchAtLogin) }
        set { d.set(newValue, forKey: PrefKey.launchAtLogin); LaunchAtLogin.setEnabled(newValue); changed() }
    }
    var autoRehide: Bool {
        get { d.bool(forKey: PrefKey.autoRehide) }
        set { d.set(newValue, forKey: PrefKey.autoRehide); changed() }
    }
    var rehideInterval: Int {
        get { max(1, d.integer(forKey: PrefKey.rehideInterval)) }
        set { d.set(newValue, forKey: PrefKey.rehideInterval); changed() }
    }
    var enableAlwaysHidden: Bool {
        get { d.bool(forKey: PrefKey.enableAlwaysHidden) }
        set { d.set(newValue, forKey: PrefKey.enableAlwaysHidden); changed() }
    }
    var revealOnHover: Bool {
        get { d.bool(forKey: PrefKey.revealOnHover) }
        set { d.set(newValue, forKey: PrefKey.revealOnHover); changed() }
    }
    var appLanguage: String {
        get { d.string(forKey: PrefKey.appLanguage) ?? "" }
        set { d.set(newValue, forKey: PrefKey.appLanguage); changed() }
    }
}
