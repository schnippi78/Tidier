import AppKit
import ApplicationServices

/// macOS 27 menu-bar app enumeration. On macOS 27 the per-item CGWindows are gone
/// (`MenuBarScanner`/CGWindowList return nothing for items), so identity comes from the
/// Accessibility API instead: probe along the menu-bar row and read each element's owning
/// process → bundle id + name. Used to populate the Settings list and the hide allow-list.
enum MenuBarApps {
    /// One third-party menu-bar item's app.
    struct Entry: Identifiable, Hashable {
        let bundleID: String
        let name: String
        var id: String { bundleID }
    }

    /// Apple agents that are never offered for hiding (they host the system items and must
    /// stay — same set the hide engine always allows).
    private static let systemBundleIDs = Set(MenuBarHideEngine.alwaysAllowedBundleIDs)

    /// Distinct third-party apps that currently have a menu-bar item. Instead of fragile
    /// position hit-testing, this asks each running app for its own `AXExtrasMenuBar` element
    /// (the app's status-bar extras) and checks whether it has any children — reliable on
    /// macOS 27 and independent of whether the item is on-screen. Excludes the always-allowed
    /// Apple agents and Tidier itself; Apple's optional extras (e.g. Weather) are included so
    /// the user can choose to hide them. (Technique from MenuBarHider, MIT.)
    static func scanThirdParty() -> [Entry] {
        guard PermissionManager.hasAccessibility else { return [] }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var out: [Entry] = []
        for app in NSWorkspace.shared.runningApplications {
            guard app.activationPolicy != .prohibited, app.processIdentifier != ownPID,
                  let bid = app.bundleIdentifier, !systemBundleIDs.contains(bid) else { continue }
            if appHasMenuBarExtra(pid: app.processIdentifier) {
                out.append(Entry(bundleID: bid, name: app.localizedName ?? bid))
            }
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// True if the app with `pid` exposes at least one menu-bar extra (status item).
    private static func appHasMenuBarExtra(pid: pid_t) -> Bool {
        let appEl = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appEl, 0.25)   // don't stall on an unresponsive app
        var barV: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appEl, "AXExtrasMenuBar" as CFString, &barV) == .success,
              let barRef = barV, CFGetTypeID(barRef) == AXUIElementGetTypeID() else { return false }
        var childrenV: CFTypeRef?
        guard AXUIElementCopyAttributeValue(barRef as! AXUIElement, kAXChildrenAttribute as CFString, &childrenV) == .success,
              let children = childrenV as? [AXUIElement] else { return false }
        return !children.isEmpty
    }

    /// Bundle ids of the third-party menu-bar apps (for the hide allow-list).
    static func scanBundleIDs() -> [String] { scanThirdParty().map(\.bundleID) }
}
