import AppKit
import ApplicationServices

/// Resolves the *real* identity of a menu bar item by hit-testing the system-wide
/// accessibility tree at the item's screen position. On macOS 26 CGWindowList
/// reports every item as owned by "Control Center"; AX returns the true owning
/// process (Apple modules → com.apple.controlcenter, third-party → their own PID)
/// plus a human title. Requires Accessibility permission.
struct ResolvedItem {
    let title: String?
    let bundleId: String?
    let appName: String?
    let pid: pid_t
}

enum AXResolver {
    static func resolve(at x: CGFloat, y: CGFloat) -> ResolvedItem? {
        guard PermissionManager.hasAccessibility else { return nil }
        let sys = AXUIElementCreateSystemWide()
        var el: AXUIElement?
        guard AXUIElementCopyElementAtPosition(sys, Float(x), Float(y), &el) == .success,
              let element = el else { return nil }

        let title = string(element, kAXTitleAttribute)
            ?? string(element, kAXDescriptionAttribute)
            ?? string(element, kAXHelpAttribute)

        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        var bundleId: String?
        var appName: String?
        if pid > 0, let app = NSRunningApplication(processIdentifier: pid) {
            bundleId = app.bundleIdentifier
            appName = app.localizedName
        }
        return ResolvedItem(title: title, bundleId: bundleId, appName: appName, pid: pid)
    }

    /// Activate the menu bar item at a screen point via the accessibility AXPress action —
    /// far more reliable than a synthetic mouse click for Control Center modules
    /// (WLAN/Bluetooth/…), which ignore a posted click that isn't a real HID event.
    /// Walks up a few parents in case the deepest element isn't the pressable one.
    @discardableResult
    static func press(at x: CGFloat, y: CGFloat) -> Bool {
        guard PermissionManager.hasAccessibility else { return false }
        let sys = AXUIElementCreateSystemWide()
        var el: AXUIElement?
        guard AXUIElementCopyElementAtPosition(sys, Float(x), Float(y), &el) == .success,
              var current = el else { return false }
        // Different status items expose different activation actions: Control Center
        // modules use AXPress, many third-party menu items use AXShowMenu, some AXOpen.
        // Try each element's own action list (best signal) walking up a few parents.
        let preferred = ["AXPress", "AXShowMenu", "AXOpen", "AXPick"]
        for _ in 0..<6 {
            var namesRef: CFArray?
            if AXUIElementCopyActionNames(current, &namesRef) == .success,
               let names = namesRef as? [String] {
                for action in preferred where names.contains(action) {
                    if AXUIElementPerformAction(current, action as CFString) == .success { return true }
                }
            }
            var parentRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parentRef) == .success,
                  let p = parentRef, CFGetTypeID(p) == AXUIElementGetTypeID() else { return false }
            current = (p as! AXUIElement)
        }
        return false
    }

    private static func string(_ el: AXUIElement, _ attr: String) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success,
              let s = v as? String, !s.isEmpty else { return nil }
        return s
    }
}
