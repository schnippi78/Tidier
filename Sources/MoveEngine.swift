import AppKit
import CoreGraphics

/// Repositions a menu-bar status item — including one belonging to another application or
/// one hidden under the notch — by synthesizing the exact gesture a person uses to
/// rearrange the menu bar: hold ⌘ and drag the item. The twist that makes it work while
/// the item is off-screen is that the events are *addressed at the item's own window*
/// instead of at wherever the real cursor happens to be, so the window server routes them
/// to the target regardless of what is (or isn't) drawn on screen.
///
/// This is an independent implementation built only on public CoreGraphics event APIs and
/// the documented behaviour of ⌘-dragging menu-bar items. The event fields used below are
/// the standard CGEvent fields the window server consults to pick the receiving window.
///
/// ⚠️ macOS 27 (2026-10): the window-number routing below is INERT. Status items are no
/// longer individual CGWindows (the whole bar is one composited "Menubar" window), so there
/// is no per-item window number to address. On macOS 27 the only working move primitive is a
/// synthetic ⌘-drag at REAL on-screen coordinates, and items can only be *reordered* (never
/// pushed off-screen). Hiding is therefore not possible on macOS 27. See docs/MACOS27.md.
enum MoveEngine {

    /// A point well outside every display. The button-down happens here so it can never
    /// accidentally engage an on-screen control before the event is routed to the window.
    private static let parkingSpot = CGPoint(x: -32_000, y: -32_000)

    /// CGEvent field 51 — the private slot the window server reads for the target window
    /// number on a synthetic mouse event. It has no public constant, but is required: the
    /// two public `mouseEventWindowUnderMousePointer…` fields alone do not route the drag
    /// to an off-screen menu-bar item (verified: without this field the item does not move).
    private static let windowNumberField = CGEventField(rawValue: 51)!

    /// One left-button mouse event routed to `window` (owned by `pid`) rather than to the
    /// window under the real cursor. `.eventTargetUnixProcessID` names the receiving
    /// process; the two `mouseEventWindowUnderMousePointer…` fields name the receiving
    /// window and assert it can handle the event.
    private static func routed(_ type: CGEventType, to point: CGPoint, holding flags: CGEventFlags,
                               window: UInt32, pid: pid_t, from source: CGEventSource) -> CGEvent? {
        guard let event = CGEvent(mouseEventSource: source, mouseType: type,
                                  mouseCursorPosition: point, mouseButton: .left) else { return nil }
        event.flags = flags
        let windowValue = Int64(window)
        event.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(pid))
        event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: windowValue)
        event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: windowValue)
        event.setIntegerValueField(windowNumberField, value: windowValue)
        return event
    }

    /// Grab the item's window with ⌘ held (off-screen), then let go at `toX` on the
    /// menu-bar row at `menuBarY`. Blocking (usleep) — call off the main thread.
    static func move(windowID: UInt32, pid: pid_t, toX: CGFloat, menuBarY: CGFloat) {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        let cursorBefore = CGEvent(source: nil)?.location   // put the real pointer back after

        routed(.leftMouseDown, to: parkingSpot, holding: .maskCommand,
               window: windowID, pid: pid, from: source)?.post(tap: .cgSessionEventTap)
        usleep(150_000)
        routed(.leftMouseUp, to: CGPoint(x: toX, y: menuBarY), holding: [],
               window: windowID, pid: pid, from: source)?.post(tap: .cgSessionEventTap)

        if let cursor = cursorBefore { CGWarpMouseCursorPosition(cursor) }
    }

    // MARK: - Verification self-test (moves the rightmost movable item and back)

    private struct Probe { let id: UInt32; let pid: pid_t; let x: CGFloat; let y: CGFloat; let name: String }

    private static func statusItems() -> [Probe] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        var out: [Probe] = []
        for w in list {
            guard let layer = w[kCGWindowLayer as String] as? Int, layer == 25,
                  let num = w[kCGWindowNumber as String] as? Int,
                  let pid = w[kCGWindowOwnerPID as String] as? pid_t,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = b["X"], let wd = b["Width"], let y = b["Y"], let h = b["Height"], h <= 40 else { continue }
            let owner = (w[kCGWindowOwnerName as String] as? String) ?? ""
            let name = (w[kCGWindowName as String] as? String) ?? ""
            if owner != "Tidier" && !name.hasPrefix("Tidier") {
                out.append(Probe(id: UInt32(num), pid: pid, x: x + wd / 2, y: y + h / 2, name: name))
            }
        }
        return out
    }

    static func runSelfTest() {
        var log = "MoveEngine self-test @ \(Date())\n  AXIsProcessTrusted=\(AXIsProcessTrusted())\n"
        // Movable third-party items report as "Item-0"; the fixed system modules do not move.
        let fixed = ["Clock", "BentoBox-0", "Battery", "Bluetooth", "WiFi", "NowPlaying", "Control Center"]
        let movable = statusItems().filter { $0.name == "Item-0" && !fixed.contains($0.name) }
        guard let target = movable.max(by: { $0.x < $1.x }) else {
            log += "  no movable Item-0 found\n"
            try? log.write(toFile: "/tmp/tidier_move.log", atomically: true, encoding: .utf8)
            return
        }
        let beforeX = target.x
        log += "  target id=\(target.id) pid=\(target.pid) before x=\(Int(beforeX)) y=\(Int(target.y))\n"
        move(windowID: target.id, pid: target.pid, toX: beforeX - 55, menuBarY: target.y)
        usleep(450_000)
        let afterX = statusItems().first { $0.id == target.id }?.x
        log += "  after x=\(afterX.map { String(Int($0)) } ?? "nil")  Δ=\(afterX.map { String(Int($0 - beforeX)) } ?? "?")\n"
        let moved = afterX.map { abs($0 - beforeX) > 8 } ?? false
        log += moved ? "  ✅ Item verschoben — Technik funktioniert auf diesem macOS!\n" : "  ❌ nicht bewegt\n"
        if moved {
            move(windowID: target.id, pid: target.pid, toX: beforeX, menuBarY: target.y)
            usleep(300_000)
            let restored = statusItems().first { $0.id == target.id }?.x
            log += "  zurückgeschoben → x=\(restored.map { String(Int($0)) } ?? "nil")\n"
        }
        try? log.write(toFile: "/tmp/tidier_move.log", atomically: true, encoding: .utf8)
    }
}
