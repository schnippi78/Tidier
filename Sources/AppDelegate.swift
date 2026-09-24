import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBar: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Single instance: if another Tidier is already running, hand off to it (show its
        // settings) and quit this one — so the menu bar never gets duplicate toggles.
        let me = NSRunningApplication.current
        let others = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == me.bundleIdentifier && $0.processIdentifier != me.processIdentifier
        }
        if !others.isEmpty {
            others.first?.activate(options: [])
            NSApp.terminate(nil)
            return
        }

        Preferences.registerDefaults()
        LanguageManager.shared.applyStored()
        statusBar = StatusBarController()

        // Pre-warm the async content so the FIRST panel open is already the right size and
        // doesn't visibly grow ("pelzig"): weather loads in the background, and a throwaway
        // stats sample primes the values. Later opens reuse the cached values.
        if Preferences.shared.showWeather { WeatherService.shared.refreshIfStale() }
        SystemStats.shared.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { SystemStats.shared.stop() }

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
