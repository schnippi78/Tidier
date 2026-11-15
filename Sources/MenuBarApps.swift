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

    // MARK: - Tidier-Leiste helpers (open a peeked item)

    /// First menu-bar extra of the app with `pid` (nil while MenuBarAgent hides it — hidden
    /// items vanish from AX with kAXErrorNoValue).
    private static func firstExtra(pid: pid_t) -> AXUIElement? {
        let appEl = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appEl, 0.5)
        var barV: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appEl, "AXExtrasMenuBar" as CFString, &barV) == .success,
              let barRef = barV, CFGetTypeID(barRef) == AXUIElementGetTypeID() else { return nil }
        var childrenV: CFTypeRef?
        guard AXUIElementCopyAttributeValue(barRef as! AXUIElement, kAXChildrenAttribute as CFString, &childrenV) == .success,
              let children = childrenV as? [AXUIElement] else { return nil }
        return children.first
    }

    /// Screen frame (top-left CG coords) of an AX element.
    private static func frame(of el: AXUIElement) -> CGRect? {
        var posV: CFTypeRef?, sizeV: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &posV) == .success,
              AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sizeV) == .success,
              let pv = posV, let sv = sizeV else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        AXValueGetValue(pv as! AXValue, .cgPoint, &p)
        AXValueGetValue(sv as! AXValue, .cgSize, &s)
        guard s.width > 0 else { return nil }
        return CGRect(origin: p, size: s)
    }

    /// Frame of the app's menu-bar item once it is shown in the bar.
    static func extraFrame(pid: pid_t) -> CGRect? {
        firstExtra(pid: pid).flatMap { frame(of: $0) }
    }

    /// Open the app's menu-bar item via Accessibility (AXPress / AXShowMenu). False if the
    /// item has no such action, so the caller can fall back to a synthetic click.
    static func pressExtra(pid: pid_t) -> Bool {
        guard let el = firstExtra(pid: pid) else { return false }
        var namesRef: CFArray?
        guard AXUIElementCopyActionNames(el, &namesRef) == .success,
              let names = namesRef as? [String] else { return false }
        for action in ["AXPress", "AXShowMenu"] where names.contains(action) {
            let err = AXUIElementPerformAction(el, action as CFString)
            if err == .success || err == .cannotComplete { return true }
        }
        return false
    }

    /// Frames of the system items (Wi-Fi, Bluetooth, …) that MenuBarAgent currently shows.
    /// They carry no identifier in AX, so a newly revealed one is found by diffing.
    static func systemItemFrames() -> [CGRect] {
        guard let pid = pid(of: "com.apple.MenuBarAgent") else { return [] }
        let appEl = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appEl, 0.5)
        var barV: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appEl, "AXExtrasMenuBar" as CFString, &barV) == .success,
              let barRef = barV, CFGetTypeID(barRef) == AXUIElementGetTypeID() else { return [] }
        var childrenV: CFTypeRef?
        guard AXUIElementCopyAttributeValue(barRef as! AXUIElement, kAXChildrenAttribute as CFString, &childrenV) == .success,
              let children = childrenV as? [AXUIElement] else { return [] }
        return children.compactMap { frame(of: $0) }
    }

    static func pid(of bundleID: String) -> pid_t? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.processIdentifier
    }
}
