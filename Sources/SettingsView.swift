import SwiftUI
import AppKit

enum SettingsTab: Hashable { case general, menubar, language, about }

final class SettingsState: ObservableObject {
    @Published var tab: SettingsTab = .general
}

/// Hosts the SwiftUI settings UI in a normal window and brings the app forward
/// (an accessory app has no Dock icon, so we activate to show the window).
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    static let shared = SettingsWindowController()
    private let state = SettingsState()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 480),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false)
        window.title = "Tidier"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
        rebuildContent()
        NotificationCenter.default.addObserver(
            forName: .tidierPrefsChanged, object: nil, queue: .main) { [weak self] _ in
                self?.rebuildContent()
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    private func rebuildContent() {
        let root = SettingsView()
            .environmentObject(state)
            .environmentObject(Preferences.shared)
            .environmentObject(LanguageManager.shared)
            .environmentObject(ScannerModel.shared)
            .environment(\.layoutDirection, LanguageManager.shared.isRTL ? .rightToLeft : .leftToRight)
        window?.contentView = NSHostingView(rootView: root)
    }

    func show(tab: SettingsTab = .general) {
        state.tab = tab
        // Give the window real front-most presence while open, then drop back to
        // an accessory (menu-bar-only) app once it closes.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

struct SettingsView: View {
    @EnvironmentObject var state: SettingsState
    @EnvironmentObject var prefs: Preferences
    @EnvironmentObject var lang: LanguageManager

    var body: some View {
        TabView(selection: $state.tab) {
            GeneralTab().tabItem { Label(L("tab.general"), systemImage: "gearshape") }.tag(SettingsTab.general)
            MenuBarTab().tabItem { Label(L("tab.menubar"), systemImage: "menubar.rectangle") }.tag(SettingsTab.menubar)
            LanguageTab().tabItem { Label(L("tab.language"), systemImage: "globe") }.tag(SettingsTab.language)
            AboutTab().tabItem { Label(L("tab.about"), systemImage: "info.circle") }.tag(SettingsTab.about)
        }
        .frame(width: 560, height: 480)
        .padding(.top, 4)
    }
}

private struct GeneralTab: View {
    @EnvironmentObject var prefs: Preferences
    @EnvironmentObject var lang: LanguageManager

    var body: some View {
        Form {
            Toggle(L("general.launchAtLogin"), isOn: Binding(
                get: { prefs.launchAtLogin }, set: { prefs.launchAtLogin = $0 }))

            Toggle(L("general.enableAlwaysHidden"), isOn: Binding(
                get: { prefs.enableAlwaysHidden }, set: { prefs.enableAlwaysHidden = $0 }))

            Divider()

            Toggle(L("general.autoRehide"), isOn: Binding(
                get: { prefs.autoRehide }, set: { prefs.autoRehide = $0 }))

            HStack {
                Text(L("general.rehideAfter"))
                Stepper(value: Binding(get: { prefs.rehideInterval },
                                       set: { prefs.rehideInterval = $0 }),
                        in: 1...120) {
                    Text(L("general.seconds", prefs.rehideInterval))
                }
            }
            .disabled(!prefs.autoRehide)

            Toggle(L("general.revealOnHover"), isOn: Binding(
                get: { prefs.revealOnHover }, set: { prefs.revealOnHover = $0 }))

            Divider()

            Toggle(L("general.showSystemTiles"), isOn: Binding(
                get: { prefs.showSystemTiles }, set: { prefs.showSystemTiles = $0 }))
        }
        .formStyle(.grouped)
    }
}

private struct MenuBarTab: View {
    @EnvironmentObject var prefs: Preferences
    @EnvironmentObject var lang: LanguageManager
    @EnvironmentObject var scanner: ScannerModel

    var body: some View {
        ScrollView {
            content.padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            scanner.refresh()
            if scanner.detected.isEmpty { StatusBarController.shared?.refreshDetected() }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(L("menubar.help"), systemImage: "hand.draw")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            // Arrange: reveal the bar + mark the separator so the user ⌘-drags which
            // icons stay visible. macOS 26 blocks programmatic reordering, so this is
            // the supported path.
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Icons anordnen").font(.headline)
                    Text("macOS erlaubt Programmen kein automatisches Umsortieren der Menüleiste. Tidier klappt sie auf und markiert den Trenner — ziehe dann mit **⌘** die Icons, die immer sichtbar bleiben sollen, rechts neben die Markierung. Alles links davon wandert in die Kachel.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        SettingsWindowController.shared.window?.close()
                        StatusBarController.shared?.enterArrangeMode()
                    } label: {
                        Label("Menüleiste anordnen…", systemImage: "arrow.left.and.right")
                    }
                    .controlSize(.large)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Platz schaffen").font(.headline)
                    Text("WLAN und Bluetooth belegen je ein eigenes Menüleisten-Icon, obwohl sie auch im Kontrollzentrum liegen. Blende sie in der Leiste aus, um Platz für wichtige Icons (z. B. WireGuard) zu gewinnen — erreichbar bleiben sie über das Kontrollzentrum.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension") {
                            NSWorkspace.shared.open(url)
                        }
                    } label: {
                        Label("Kontrollzentrum-Einstellungen öffnen…", systemImage: "switch.2")
                    }
                    .controlSize(.large)
                    Text("Dort bei WLAN und Bluetooth jeweils auf »Nicht in der Menüleiste anzeigen« stellen.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }

            HStack(spacing: 6) {
                Text(L("menubar.detected")).font(.headline)
                Spacer()
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Automatisch aktuell").font(.caption).foregroundStyle(.secondary)
            }

            if scanner.detected.isEmpty {
                Text("Noch keine Objekte erfasst — die Liste aktualisiert sich automatisch im Hintergrund, sobald Tidier die Leiste eingelesen hat.")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(scanner.detected.enumerated()), id: \.offset) { i, item in
                        HStack(spacing: 10) {
                            detectedIcon(item).frame(width: 22, height: 18)
                            Text(item.label.isEmpty ? item.info.owner : item.label)
                            Spacer()
                            Text(item.isApple ? "System" : "App")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 7)
                        if i < scanner.detected.count - 1 { Divider() }
                    }
                }
                .padding(.horizontal, 10)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    @ViewBuilder private func detectedIcon(_ item: BarItem) -> some View {
        if let img = item.image {
            Image(nsImage: img).resizable().scaledToFit()
        } else if let sym = item.symbolName {
            Image(systemName: sym).foregroundStyle(.secondary)
        } else {
            Image(systemName: item.isApple ? "gearshape.2" : "app.dashed").foregroundStyle(.secondary)
        }
    }
}

private struct LanguageTab: View {
    @EnvironmentObject var prefs: Preferences
    @EnvironmentObject var lang: LanguageManager

    var body: some View {
        Form {
            Picker(L("language.pick"), selection: Binding(
                get: { prefs.appLanguage },
                set: { newValue in LanguageManager.shared.apply(newValue) })) {
                Text(L("language.system")).tag("")
                Divider()
                ForEach(Languages.all) { l in
                    Text(l.autonym).tag(l.code)
                }
            }
            .pickerStyle(.menu)

            Text(L("language.note"))
                .font(.footnote)
                .foregroundStyle(.secondary)

            Button(L("language.restart")) { relaunch() }
        }
        .formStyle(.grouped)
    }

    private func relaunch() {
        guard let path = Bundle.main.bundlePath as String? else { return }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", path]
        try? task.run()
        NSApp.terminate(nil)
    }
}

private struct AboutTab: View {
    @EnvironmentObject var lang: LanguageManager

    private var version: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.1.0"
    }

    private var appIcon: NSImage {
        NSImage(contentsOf: Bundle.main.url(forResource: "AppIcon", withExtension: "icns") ?? URL(fileURLWithPath: "/"))
            ?? NSApp.applicationIconImage
    }

    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: appIcon)
                .resizable().frame(width: 84, height: 84)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            Text("Tidier").font(.largeTitle.bold())
            Text(L("app.tagline")).foregroundStyle(.secondary)
            Text(L("about.version", version)).font(.footnote).foregroundStyle(.secondary)

            Spacer().frame(height: 6)
            Text("Christian Schniering").font(.callout.weight(.medium))
            Link("csho.de", destination: URL(string: "https://csho.de")!)
                .font(.callout)
            Text("© 2026 Christian Schniering").font(.footnote).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
