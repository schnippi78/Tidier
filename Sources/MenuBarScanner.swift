import AppKit
import Combine

/// Observable holder for the scanned items (avoids the @State macro, which the
/// command-line Swift toolchain can't expand without Xcode's macro plugins).
final class ScannerModel: ObservableObject {
    static let shared = ScannerModel()
    @Published var items: [MenuBarItemInfo] = []
    func refresh() { items = MenuBarScanner.scan() }
}

/// One detected menu bar status item (from CGWindowList, layer 25).
struct MenuBarItemInfo: Identifiable, Hashable {
    let id: Int          // CGWindowNumber (stable per item while it lives)
    let x: CGFloat
    let y: CGFloat
    let width: CGFloat
    let height: CGFloat
    let owner: String
    let name: String

    var centerX: CGFloat { x + width / 2 }
    var centerY: CGFloat { y + height / 2 }

    /// A friendlier label. On macOS 26 most items are hosted by "Control Center",
    /// so the useful identity is the window name (e.g. bundle-ish id, "WiFi", "Clock").
    var displayName: String {
        if name.hasPrefix("com.bjango.istatmenus.") {
            return "iStat · " + name.replacingOccurrences(of: "com.bjango.istatmenus.", with: "")
        }
        if name.isEmpty || name == "Item-0" { return owner }
        return name
    }

    var isSystem: Bool {
        ["Battery", "Bluetooth", "WiFi", "Clock", "BentoBox-0", "Control Center"].contains(name)
            || name.hasPrefix("com.apple.")
    }
}

/// Enumerates the menu bar's status items. This is the capability the length-hack
/// approach lacks and that a real per-item manager is built on.
enum MenuBarScanner {
    /// Reading window *names* may require Screen Recording permission on recent macOS;
    /// geometry/owner are available without it.
    static func scan() -> [MenuBarItemInfo] {
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        var items: [MenuBarItemInfo] = []
        for w in list {
            guard let layer = w[kCGWindowLayer as String] as? Int, layer == 25 else { continue }
            let owner = (w[kCGWindowOwnerName as String] as? String) ?? "?"
            let name  = (w[kCGWindowName as String] as? String) ?? ""
            let num   = (w[kCGWindowNumber as String] as? Int) ?? 0
            guard let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = b["X"], let y = b["Y"], let width = b["Width"], let h = b["Height"], h <= 40 else { continue }
            items.append(.init(id: num, x: x, y: y, width: width, height: h, owner: owner, name: name))
        }
        return items.sorted { $0.x < $1.x }
    }
}
