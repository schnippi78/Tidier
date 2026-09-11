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

    private static func string(_ el: AXUIElement, _ attr: String) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success,
              let s = v as? String, !s.isEmpty else { return nil }
        return s
    }
}
