import AppKit
import CoreGraphics

// Reposition technique adapted from Ice (jordanbaird/Ice, GPL-3.0): move a menu bar
// item by posting *targeted* CGEvents — a ⌘-mouseDown addressed at the item's window
// (via PID + windowID event fields) at a far fake location, then a mouseUp at the
// destination x on the menu bar. This bypasses cursor hit-testing, which is why the
// naive cursor-based ⌘-drag failed on macOS 26.
enum MoveEngine {
    /// Undocumented CGEventField carrying the target window id (Ice: 0x33).
    private static let windowIDField = CGEventField(rawValue: 0x33)!

    private static func event(_ type: CGEventType, flags: CGEventFlags, at location: CGPoint,
                              windowID: UInt32, pid: pid_t, source: CGEventSource) -> CGEvent? {
        guard let e = CGEvent(mouseEventSource: source, mouseType: type,
                              mouseCursorPosition: location, mouseButton: .left) else { return nil }
        e.flags = flags
        e.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(pid))
        e.setIntegerValueField(.eventSourceUserData,
                               value: Int64(truncatingIfNeeded: Int(bitPattern: ObjectIdentifier(e))))
        e.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(windowID))
        e.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(windowID))
        e.setIntegerValueField(windowIDField, value: Int64(windowID))
        return e
    }

    /// Move the item to screen-x `toX` on the menu bar (`menuBarY`).
    static func move(windowID: UInt32, pid: pid_t, toX: CGFloat, menuBarY: CGFloat) {
        guard let src = CGEventSource(stateID: .combinedSessionState) else { return }
        if let down = event(.leftMouseDown, flags: .maskCommand, at: CGPoint(x: 20_000, y: 20_000),
                            windowID: windowID, pid: pid, source: src) {
            down.post(tap: .cgSessionEventTap)
        }
        usleep(150_000)
        if let up = event(.leftMouseUp, flags: [], at: CGPoint(x: toX, y: menuBarY),
                          windowID: windowID, pid: pid, source: src) {
            up.post(tap: .cgSessionEventTap)
        }
    }

    // MARK: - Verification self-test

    private struct Item { let id: UInt32; let pid: pid_t; let x: CGFloat; let y: CGFloat; let name: String }

    private static func scan() -> [Item] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        var out: [Item] = []
        for w in list {
            guard let layer = w[kCGWindowLayer as String] as? Int, layer == 25,
                  let num = w[kCGWindowNumber as String] as? Int,
                  let pid = w[kCGWindowOwnerPID as String] as? pid_t,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = b["X"], let wd = b["Width"], let y = b["Y"], let h = b["Height"], h <= 40 else { continue }
            let owner = (w[kCGWindowOwnerName as String] as? String) ?? ""
            let name = (w[kCGWindowName as String] as? String) ?? ""
            if owner != "Tidier" && !name.hasPrefix("Tidier") {
                out.append(Item(id: UInt32(num), pid: pid, x: x + wd / 2, y: y + h / 2, name: name))
            }
        }
        return out
    }

    static func runSelfTest() {
        var log = "MoveEngine self-test @ \(Date())\n  AXIsProcessTrusted=\(AXIsProcessTrusted())\n"
        // A movable third-party item is reported as "Item-0"; pick the rightmost so it
        // is clearly on-screen. Skip system modules (Battery/WiFi/… are not movable).
        let system = ["Clock", "BentoBox-0", "Battery", "Bluetooth", "WiFi", "NowPlaying", "Control Center"]
        let movable = scan().filter { $0.name == "Item-0" && !system.contains($0.name) }
        guard let target = movable.max(by: { $0.x < $1.x }) else {
            log += "  no movable Item-0 found\n"
            try? log.write(toFile: "/tmp/tidier_move.log", atomically: true, encoding: .utf8)
            return
        }
        let beforeX = target.x
        log += "  target id=\(target.id) pid=\(target.pid) before x=\(Int(beforeX)) y=\(Int(target.y))\n"
        move(windowID: target.id, pid: target.pid, toX: beforeX - 55, menuBarY: target.y)
        usleep(450_000)
        let afterX = scan().first { $0.id == target.id }?.x
        log += "  after x=\(afterX.map { String(Int($0)) } ?? "nil")  Δ=\(afterX.map { String(Int($0 - beforeX)) } ?? "?")\n"
        let moved = afterX.map { abs($0 - beforeX) > 8 } ?? false
        log += moved ? "  ✅ ITEM MOVED — Ice-Technik funktioniert auf diesem macOS!\n" : "  ❌ nicht bewegt\n"
        // Put it back where it was.
        if moved {
            move(windowID: target.id, pid: target.pid, toX: beforeX, menuBarY: target.y)
            usleep(300_000)
            let restored = scan().first { $0.id == target.id }?.x
            log += "  zurückgeschoben → x=\(restored.map { String(Int($0)) } ?? "nil")\n"
        }
        try? log.write(toFile: "/tmp/tidier_move.log", atomically: true, encoding: .utf8)
    }
}
