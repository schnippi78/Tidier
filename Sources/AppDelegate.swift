import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBar: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Preferences.registerDefaults()
        LanguageManager.shared.applyStored()
        statusBar = StatusBarController()

        // The tiles show the *real* menu-bar glyph (iStat text, weather °C, …),
        // which only Screen Recording can capture. Surface the system prompt and
        // register Tidier in the Screen Recording list on first launch so the user
        // can enable it with one toggle.
        if !PermissionManager.hasScreenRecording {
            PermissionManager.requestScreenRecording()
        }

        // Keep the login item in sync with the stored preference.
        if Preferences.shared.launchAtLogin, !LaunchAtLogin.isEnabled {
            LaunchAtLogin.setEnabled(true)
        }

        if CommandLine.arguments.contains("--settings") {
            SettingsWindowController.shared.show()
        }
    }

    // Reopen (e.g. clicking the app in Finder while already running) shows settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsWindowController.shared.show()
        return true
    }
}
