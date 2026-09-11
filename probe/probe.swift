import Cocoa

// Probe: can Tidier enumerate individual menu bar status items (owner + geometry)?
// Menu bar status items live at window layer 25 (NSStatusWindowLevel).

let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else {
    print("no window list"); exit(1)
}

let statusLevel = 25
var rows: [(x: CGFloat, w: CGFloat, owner: String, pid: Int, name: String)] = []

for w in list {
    guard let layer = w[kCGWindowLayer as String] as? Int, layer == statusLevel else { continue }
    let owner = (w[kCGWindowOwnerName as String] as? String) ?? "?"
    let pid = (w[kCGWindowOwnerPID as String] as? Int) ?? -1
    let name = (w[kCGWindowName as String] as? String) ?? ""
    guard let b = w[kCGWindowBounds as String] as? [String: CGFloat],
          let x = b["X"], let width = b["Width"], let h = b["Height"] else { continue }
    if h > 40 { continue }               // menu bar strip only
    rows.append((x, width, owner, pid, name))
}

rows.sort { $0.x < $1.x }
print("Found \(rows.count) status-bar windows (layer \(statusLevel)):\n")
print(String(format: "%-6@ %-6@ %-8@ %@", "X" as NSString, "W" as NSString, "PID" as NSString, "OWNER  (name)"))
for r in rows {
    print(String(format: "%-6.0f %-6.0f %-8d %@%@",
                 r.x, r.w, r.pid, r.owner, r.name.isEmpty ? "" : "  (\(r.name))"))
}
