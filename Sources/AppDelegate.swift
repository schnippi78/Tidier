import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBar: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Preferences.registerDefaults()
        LanguageManager.shared.applyStored()
        statusBar = StatusBarController()

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
