import AppKit
import CoreGraphics

/// Captures ALL hidden menu bar items — including ones that overflow off-screen past
/// the notch — by temporarily moving each off-screen item onto a visible "stage"
/// (via MoveEngine, Ice's targeted-CGEvent technique), capturing + resolving it there,
/// then moving it back to restore the original order. Blocking (usleep) — run off the
/// main thread.
enum CaptureEngine {
    struct Raw {
        let id: UInt32; let pid: pid_t
        let x: CGFloat; let y: CGFloat; let w: CGFloat; let h: CGFloat
        let owner: String; let name: String
        var info: MenuBarItemInfo {
            MenuBarItemInfo(id: Int(id), x: x, y: y, width: w, height: h, owner: owner, name: name)
        }
    }

    /// All layer-25 status items (on- AND off-screen), excluding Tidier's own, sorted L→R.
    static func scanAll() -> [Raw] {
        guard let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        var out: [Raw] = []
        for w in list {
            guard let layer = w[kCGWindowLayer as String] as? Int, layer == 25,
                  let num = w[kCGWindowNumber as String] as? Int,
                  let pid = w[kCGWindowOwnerPID as String] as? pid_t,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = b["X"], let wd = b["Width"], let y = b["Y"], let h = b["Height"],
                  h > 0, h <= 40, wd > 0 else { continue }
            let owner = (w[kCGWindowOwnerName as String] as? String) ?? ""
            let name = (w[kCGWindowName as String] as? String) ?? ""
            if owner == "Tidier" || name.hasPrefix("Tidier") { continue }
            out.append(Raw(id: UInt32(num), pid: pid, x: x, y: y, w: wd, h: h, owner: owner, name: name))
        }
        return out.sorted { $0.x < $1.x }
    }

    private static func current(_ id: UInt32) -> Raw? { scanAll().first { $0.id == id } }

    /// Capture everything. On-screen items are captured in place; off-screen "Item-0"
    /// (third-party) items are staged in, captured, and moved back. `stageX` must be an
    /// on-screen x right of the notch; `thresholdX` is just left of Tidier's toggle.
    static func captureAll(stageX: CGFloat, menuBarY: CGFloat, thresholdX: CGFloat) -> [BarItem] {
        let order = scanAll()
        var built: [BarItem] = []
        var seenKeys = Set<String>()
        func add(_ item: BarItem?) {
            guard let item = item, seenKeys.insert(item.key).inserted else { return }
            built.append(item)
        }
        func canCapture(_ id: UInt32) -> Bool {
            ItemCapture.image(forWindow: Int(id)) != nil
        }
        // An item is "obscured" when its window can't be captured — either truly
        // off-screen (x<0) OR sitting under the notch (positive x but not drawn). Those
        // need staging. On the notch the leftmost items overflow, so process the order.
        for r in order {
            if r.name == "Clock" || r.name == "BentoBox-0" { continue }
            if canCapture(r.id) {
                add(TidierBar.makeItem(from: r.info))
                continue
            }
            // Not capturable in place.
            if r.name == "Item-0" {   // movable third-party → stage it, capture, move back
                let rightNeighbor = order.first { $0.x > r.x && $0.id != r.id }
                MoveEngine.move(windowID: r.id, pid: r.pid, toX: stageX, menuBarY: menuBarY)
                usleep(300_000)
                if let staged = current(r.id) { add(TidierBar.makeItem(from: staged.info)) }
                if let rn = rightNeighbor, let rnNow = current(rn.id) {
                    MoveEngine.move(windowID: r.id, pid: r.pid, toX: rnNow.x - r.w - 1, menuBarY: menuBarY)
                } else {
                    MoveEngine.move(windowID: r.id, pid: r.pid, toX: thresholdX - r.w - 1, menuBarY: menuBarY)
                }
                usleep(240_000)
            } else {
                // fixed system module (not movable) — still list it via symbol fallback
                add(TidierBar.makeItem(from: r.info))
            }
        }
        return built
    }

    // MARK: - Self-test (verifies capture count + that the order is restored)

    static func runSelfTest(stageX: CGFloat, menuBarY: CGFloat, thresholdX: CGFloat) {
        var log = "CaptureEngine self-test @ \(Date())\n"
        let before = scanAll()
        log += "  vorher: \(before.count) Items, Reihenfolge-IDs: \(before.map { $0.id })\n"
        let items = captureAll(stageX: stageX, menuBarY: menuBarY, thresholdX: thresholdX)
        usleep(300_000)
        let after = scanAll()
        log += "  → \(items.count) Items captured: \(items.map { $0.label.isEmpty ? $0.info.owner : $0.label })\n"
        log += "  nachher: \(after.count) Items, Reihenfolge-IDs: \(after.map { $0.id })\n"
        let orderOK = before.map { $0.id } == after.map { $0.id }
        log += orderOK ? "  ✅ Reihenfolge erhalten\n" : "  ⚠️ Reihenfolge verändert!\n"
        try? log.write(toFile: "/tmp/tidier_capture_all.log", atomically: true, encoding: .utf8)
    }
}
