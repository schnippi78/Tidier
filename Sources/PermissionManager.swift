import CoreGraphics
import AppKit

/// Screen Recording gates reading menu bar item *names* and capturing their icon
/// images. Accessibility (future) gates synthetic ⌘-drag repositioning.
enum PermissionManager {
    static var hasScreenRecording: Bool { CGPreflightScreenCaptureAccess() }

    /// Triggers the system prompt on first call; afterwards the user must toggle it
    /// in System Settings › Privacy & Security › Screen Recording (and relaunch).
    @discardableResult
    static func requestScreenRecording() -> Bool { CGRequestScreenCaptureAccess() }

    static func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Accessibility (real item identity via AX, later: repositioning)

    static var hasAccessibility: Bool { AXIsProcessTrusted() }

    @discardableResult
    static func requestAccessibility() -> Bool {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Captures the rendered image of a single menu bar item (its CGWindow).
enum ItemCapture {
    static func image(forWindow id: Int) -> NSImage? {
        guard PermissionManager.hasScreenRecording, id > 0 else { return nil }
        let wid = CGWindowID(id)
        guard let cg = CGWindowListCreateImage(.null, .optionIncludingWindow, wid,
                                               [.boundsIgnoreFraming, .nominalResolution]),
              cg.width > 1, cg.height > 1 else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}
