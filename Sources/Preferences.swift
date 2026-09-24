import Foundation
import Combine

extension Notification.Name {
    static let tidierPrefsChanged = Notification.Name("de.csho.Tidier.prefsChanged")
}

/// Visual layout of the Tidier Bar tiles, user-selectable from the menu.
enum TileStyle: String, CaseIterable {
    case dashboard   // C — CPU/RAM/battery rings + toggle/value tiles
    case capsules    // A — Control-Center capsules (badge + title + subtitle)
    case grid        // B — clean uniform glyph grid
    case strip       // D — folded menu-bar strip

    var title: String {
        switch self {
        case .dashboard: return "Dashboard (Ringe)"
        case .capsules:  return "Kapseln"
        case .grid:      return "Raster"
        case .strip:     return "Leiste"
        }
    }
}

enum PrefKey {
    static let launchAtLogin      = "launchAtLogin"
    static let autoRehide         = "autoRehide"
    static let rehideInterval     = "rehideInterval"
    static let enableAlwaysHidden = "enableAlwaysHidden"
    static let revealOnHover      = "revealOnHover"
    static let appLanguage        = "appLanguage"   // "" = follow system
    static let tileStyle          = "tileStyle"
    static let showSystemTiles    = "showSystemTiles"
    static let showWeather        = "showWeather"
    static let hiddenItems        = "hiddenItems"   // stable keys the user hid from the panel
    static let barPinnedItems     = "barPinnedItems" // stable keys pinned to the real menu bar
}

/// Where a menu bar item lives, as chosen per item in Settings.
enum ItemPlacement { case bar, panel, off }

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
            PrefKey.tileStyle:          TileStyle.dashboard.rawValue,
            PrefKey.showSystemTiles:    true,
            PrefKey.showWeather:        true,
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
    var tileStyle: TileStyle {
        get { TileStyle(rawValue: d.string(forKey: PrefKey.tileStyle) ?? "") ?? .dashboard }
        set { d.set(newValue.rawValue, forKey: PrefKey.tileStyle); changed() }
    }
    var showSystemTiles: Bool {
        get { d.bool(forKey: PrefKey.showSystemTiles) }
        set { d.set(newValue, forKey: PrefKey.showSystemTiles); changed() }
    }
    var showWeather: Bool {
        get { d.bool(forKey: PrefKey.showWeather) }
        set { d.set(newValue, forKey: PrefKey.showWeather); changed() }
    }

    /// Stable item keys the user chose to hide from Tidier's panel (default: show all).
    var hiddenItemKeys: Set<String> {
        get { Set(d.stringArray(forKey: PrefKey.hiddenItems) ?? []) }
        set { d.set(Array(newValue), forKey: PrefKey.hiddenItems); changed() }
    }
    func isItemHidden(_ key: String) -> Bool { hiddenItemKeys.contains(key) }
    func setItem(_ key: String, hidden: Bool) {
        var s = hiddenItemKeys
        if hidden { s.insert(key) } else { s.remove(key) }
        hiddenItemKeys = s
    }

    /// Stable item keys the user pinned to stay visible in the real menu bar.
    var barPinnedKeys: Set<String> {
        get { Set(d.stringArray(forKey: PrefKey.barPinnedItems) ?? []) }
        set { d.set(Array(newValue), forKey: PrefKey.barPinnedItems); changed() }
    }
    func isPinned(_ key: String) -> Bool { barPinnedKeys.contains(key) }

    /// The three-way placement for an item, derived from the two stored sets.
    func placement(_ key: String) -> ItemPlacement {
        if isPinned(key) { return .bar }
        return isItemHidden(key) ? .off : .panel
    }

    /// Set placement WITHOUT triggering the move — the caller runs the actual pin/unpin.
    /// Writes both sets, then fires a single change notification.
    func setPlacement(_ key: String, _ p: ItemPlacement) {
        var hidden = hiddenItemKeys
        var pinned = barPinnedKeys
        switch p {
        case .bar:   pinned.insert(key); hidden.remove(key)
        case .panel: pinned.remove(key); hidden.remove(key)
        case .off:   pinned.remove(key); hidden.insert(key)
        }
        d.set(Array(pinned), forKey: PrefKey.barPinnedItems)
        d.set(Array(hidden), forKey: PrefKey.hiddenItems)
        changed()
    }
}
