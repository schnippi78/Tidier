import AppKit

// Tidier is a menu bar agent (LSUIElement); we drive the AppKit lifecycle
// directly for reliable command-line builds without a full Xcode project.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
