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
        // Rebuild the hosting view ONLY when the layout direction (RTL) actually flips —
        // that environment is baked in at build time. Everything else (toggles, detected
        // items, live language strings) updates reactively via the EnvironmentObjects, so a
        // blanket rebuild on every .tidierPrefsChanged was needless and reset the ScrollView.
        NotificationCenter.default.addObserver(
            forName: .tidierPrefsChanged, object: nil, queue: .main) { [weak self] _ in
                guard let self = self, LanguageManager.shared.isRTL != self.builtRTL else { return }
                self.rebuildContent()
        }
    }

    private var builtRTL = false

    required init?(coder: NSCoder) { fatalError() }

    private func rebuildContent() {
        builtRTL = LanguageManager.shared.isRTL
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

            Toggle(L("general.showWeather"), isOn: Binding(
                get: { prefs.showWeather }, set: { prefs.showWeather = $0 }))
        }
        .formStyle(.grouped)
    }
}

private struct MenuBarTab: View {
    @EnvironmentObject var prefs: Preferences
    @EnvironmentObject var lang: LanguageManager
    @EnvironmentObject var scanner: ScannerModel

    private struct SysRow { let key: String; let labelKey: String; let symbol: String }
    private static let systemRows: [SysRow] = [
        SysRow(key: "sys.cpu",  labelKey: "sysitem.cpu",     symbol: "cpu"),
        SysRow(key: "sys.ram",  labelKey: "sysitem.ram",     symbol: "memorychip"),
        SysRow(key: "sys.disk", labelKey: "sysitem.disk",    symbol: "internaldrive"),
        SysRow(key: "sys.net",  labelKey: "sysitem.network", symbol: "network"),
        SysRow(key: "sys.batt", labelKey: "sysitem.battery", symbol: "battery.100"),
    ]

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
                    Text(L("menubar.arrange.title")).font(.headline)
                    Text(.init(L("menubar.arrange.desc")))
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        SettingsWindowController.shared.window?.close()
                        StatusBarController.shared?.enterArrangeMode()
                    } label: {
                        Label(L("menubar.arrange.button"), systemImage: "arrow.left.and.right")
                    }
                    .controlSize(.large)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("menubar.space.title")).font(.headline)
                    Text(L("menubar.space.desc"))
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension") {
                            NSWorkspace.shared.open(url)
                        }
                    } label: {
                        Label(L("menubar.space.button"), systemImage: "switch.2")
                    }
                    .controlSize(.large)
                    Text(L("menubar.space.hint"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }

            Text(L("menubar.systemItems")).font(.headline)
            VStack(spacing: 0) {
                ForEach(Array(Self.systemRows.enumerated()), id: \.offset) { i, row in
                    HStack(spacing: 10) {
                        Image(systemName: row.symbol).frame(width: 22, height: 18)
                            .foregroundStyle(.secondary)
                        Text(L(row.labelKey))
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { !prefs.isItemHidden(row.key) },
                            set: { prefs.setItem(row.key, hidden: !$0) }))
                            .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                    }
                    .padding(.vertical, 7)
                    if i < Self.systemRows.count - 1 { Divider() }
                }
            }
            .padding(.horizontal, 10)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))

            HStack(spacing: 6) {
                Text(L("menubar.detected")).font(.headline)
                Spacer()
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.caption).foregroundStyle(.secondary)
                Text(L("menubar.autoupdated")).font(.caption).foregroundStyle(.secondary)
            }
            Text(L("menubar.selectHelp"))
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if scanner.detected.isEmpty {
                Text(L("menubar.empty"))
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(scanner.detected.enumerated()), id: \.offset) { i, item in
                        HStack(spacing: 10) {
                            detectedIcon(item).frame(width: 22, height: 18)
                            Text(item.label.isEmpty ? item.info.owner : item.label)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Picker("", selection: Binding(
                                get: { prefs.placement(item.key) },
                                set: { newValue in
                                    let old = prefs.placement(item.key)
                                    prefs.setPlacement(item.key, newValue)
                                    if (old == .bar) != (newValue == .bar) {
                                        StatusBarController.shared?.setItemPinned(item.key, pinned: newValue == .bar)
                                    }
                                })) {
                                Text(L("menubar.place.bar")).tag(ItemPlacement.bar)
                                Text(L("menubar.place.panel")).tag(ItemPlacement.panel)
                                Text(L("menubar.place.off")).tag(ItemPlacement.off)
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .fixedSize()
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
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0.0"
    }

    private var appIcon: NSImage {
        NSImage(contentsOf: Bundle.main.url(forResource: "AppIcon", withExtension: "icns") ?? URL(fileURLWithPath: "/"))
            ?? NSApp.applicationIconImage
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 18)
            Image(nsImage: appIcon)
                .resizable().frame(width: 96, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 21, style: .continuous))
                .shadow(color: .black.opacity(0.18), radius: 9, y: 4)
                .padding(.bottom, 12)

            Text("Tidier").font(.system(size: 30, weight: .bold))
            Text(L("app.tagline"))
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 2)
            Text(L("about.version", version))
                .font(.caption).foregroundStyle(.tertiary)
                .padding(.top, 3)

            Divider().frame(width: 160).padding(.vertical, 16)

            Text("Christian Schniering").font(.callout.weight(.medium))
            Link("csho.de", destination: URL(string: "https://csho.de")!)
                .font(.callout).padding(.top, 1)

            Spacer(minLength: 18)

            VStack(spacing: 3) {
                Text(L("about.opensource"))
                    .font(.caption2).foregroundStyle(.secondary)
                Text("© 2026 Christian Schniering")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal)
    }
}
