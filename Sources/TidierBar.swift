import AppKit
import SwiftUI

struct BarItem: Identifiable {
    let info: MenuBarItemInfo
    let image: NSImage?      // captured menu-bar icon or app icon
    let symbolName: String?  // SF Symbol fallback (Apple/system items)
    let label: String        // "" → icon-only tile (Control-Center style)
    let isApple: Bool
    var id: Int { info.id }
}

struct BarGroup: Identifiable {
    let title: String
    let items: [BarItem]
    var id: String { title }
}

/// The "Tidier Bar": an elegant Control-Center-style panel that shows the hidden
/// menu bar items, grouped into Apple/System and third-party. Opened when the user
/// collapses the menu bar.
final class TidierBar {
    static let shared = TidierBar()
    private var panel: NSPanel?
    private var outsideClickMonitor: Any?
    private var localClickMonitor: Any?

    /// Called when the tile closes itself (outside click / app switch) so the
    /// controller can reset its open/closed state.
    var onClose: (() -> Void)?

    var isVisible: Bool { panel?.isVisible ?? false }

    func show(groups: [BarGroup], near rect: NSRect) {
        let root = TidierBarView(groups: groups,
                                 hasScreenRecording: PermissionManager.hasScreenRecording,
                                 hasAccessibility: PermissionManager.hasAccessibility)
            .environment(\.layoutDirection, LanguageManager.shared.isRTL ? .rightToLeft : .leftToRight)
        let hosting = NSHostingView(rootView: root)
        hosting.layout()
        let size = hosting.fittingSize
        let width: CGFloat = max(320, min(420, size.width))
        let height: CGFloat = max(120, size.height)

        let p = panel ?? makePanel()
        panel = p
        p.contentView = hosting
        p.setContentSize(NSSize(width: width, height: height))

        // Anchor below the toggle, clamped to the screen.
        if let screen = NSScreen.screens.first(where: { $0.frame.intersects(rect) }) ?? NSScreen.main {
            let x = min(max(screen.frame.minX + 8, rect.maxX - width), screen.frame.maxX - width - 8)
            let y = rect.minY - height - 6
            p.setFrameOrigin(NSPoint(x: x, y: y))
        }
        p.orderFrontRegardless()
        startDismissMonitors()
    }

    func hide() {
        stopDismissMonitors()
        panel?.orderOut(nil)
    }

    /// Close the tile as soon as the user clicks anywhere outside it (in any app)
    /// so it never lingers in the foreground.
    private func startDismissMonitors() {
        stopDismissMonitors()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                self?.dismissFromMonitor()
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                guard let self = self, let panel = self.panel else { return event }
                if event.window != panel { self.dismissFromMonitor() }
                return event
        }
    }

    private func stopDismissMonitors() {
        if let m = outsideClickMonitor { NSEvent.removeMonitor(m); outsideClickMonitor = nil }
        if let m = localClickMonitor { NSEvent.removeMonitor(m); localClickMonitor = nil }
    }

    private func dismissFromMonitor() {
        guard isVisible else { return }
        hide()
        onClose?()
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 160),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .statusBar
        p.hidesOnDeactivate = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        return p
    }

    /// Split into Apple/System vs third-party using real AX identity when available,
    /// falling back to the CGWindow name heuristic. Tidier's own control items drop out.
    static func makeGroups(from items: [MenuBarItemInfo]) -> [BarGroup] {
        var apple: [BarItem] = []
        var third: [BarItem] = []
        for info in items {
            if info.owner == "Tidier" || info.name.hasPrefix("Tidier.") { continue }
            let resolved = AXResolver.resolve(at: info.centerX, y: info.centerY)
            if resolved?.bundleId == "de.csho.Tidier" { continue }

            let isApple: Bool = {
                if let b = resolved?.bundleId { return b == "com.apple.controlcenter" || b.hasPrefix("com.apple.") }
                return info.isSystem
            }()
            let label = label(for: info, resolved: resolved, isApple: isApple)
            let item = BarItem(info: info,
                               image: icon(for: info, resolved: resolved, isApple: isApple),
                               symbolName: isApple ? symbol(for: label, resolved: resolved) : nil,
                               label: label,
                               isApple: isApple)
            if isApple { apple.append(item) } else { third.append(item) }
        }
        var groups: [BarGroup] = []
        if !third.isEmpty { groups.append(BarGroup(title: L("bar.thirdParty"), items: third)) }
        if !apple.isEmpty { groups.append(BarGroup(title: L("bar.apple"), items: apple)) }
        return groups
    }

    private static func label(for info: MenuBarItemInfo, resolved: ResolvedItem?, isApple: Bool) -> String {
        let n = info.name
        if n.hasPrefix("com.bjango.istatmenus.") {
            return "iStat · " + n.replacingOccurrences(of: "com.bjango.istatmenus.", with: "")
        }
        if isApple, let t = resolved?.title, !t.isEmpty { return t }          // e.g. "WLAN", "Spotlight"
        if !isApple, let a = resolved?.appName,                                // e.g. "iStat Menus"
           a != "Kontrollzentrum", a != "Control Center", !a.isEmpty { return a }
        if let t = resolved?.title, !t.isEmpty { return t }
        if !n.isEmpty && n != "Item-0" { return n }
        return ""                                                             // icon-only
    }

    /// Icon priority: exact menu-bar capture (needs Screen Recording) → the owning
    /// app's icon (third-party, no permission) → nil (SF Symbol fallback for Apple).
    private static func icon(for info: MenuBarItemInfo, resolved: ResolvedItem?, isApple: Bool) -> NSImage? {
        if PermissionManager.hasScreenRecording, let cap = ItemCapture.image(forWindow: info.id) {
            return cap
        }
        if !isApple, let pid = resolved?.pid, pid > 0,
           let app = NSRunningApplication(processIdentifier: pid), let icon = app.icon {
            return icon
        }
        return nil
    }

    /// SF Symbol for a system item, matched from its title (localized-tolerant).
    private static func symbol(for label: String, resolved: ResolvedItem?) -> String {
        let s = (label + " " + (resolved?.title ?? "")).lowercased()
        func has(_ needles: [String]) -> Bool { needles.contains { s.contains($0) } }
        if has(["wlan", "wi-fi", "wifi", "airport"]) { return "wifi" }
        if has(["bluetooth"]) { return "dot.radiowaves.right" }
        if has(["batterie", "battery", "akku"]) { return "battery.100" }
        if has(["spotlight", "suche", "search"]) { return "magnifyingglass" }
        if has(["wetter", "weather"]) { return "cloud.sun" }
        if has(["läuft", "playing", "musik", "music", "audio"]) { return "play.circle" }
        if has(["ton", "sound", "lautstärke", "volume"]) { return "speaker.wave.2" }
        if has(["fokus", "focus", "nicht stören", "do not disturb"]) { return "moon" }
        if has(["uhr", "clock", "zeit", "datum", "time", "date"]) { return "clock" }
        if has(["tastatur", "keyboard", "eingabe", "input"]) { return "keyboard" }
        if has(["kontrollzentrum", "control center", "steuerung"]) { return "switch.2" }
        if has(["display", "bildschirm", "helligkeit"]) { return "sun.max" }
        if has(["vpn", "netzwerk", "network"]) { return "network" }
        return "circle.grid.2x2"
    }
}

// MARK: - SwiftUI

private struct VisualEffectView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

struct TidierBarView: View {
    let groups: [BarGroup]
    let hasScreenRecording: Bool
    let hasAccessibility: Bool

    private let columns = [GridItem(.adaptive(minimum: 66), spacing: 10)]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if groups.isEmpty {
                Text(L("bar.empty"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            }
            ForEach(groups) { group in
                VStack(alignment: .leading, spacing: 8) {
                    Text(group.title.uppercased())
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                        ForEach(group.items) { item in
                            TileView(item: item)
                        }
                    }
                }
            }
            if !hasScreenRecording {
                Button {
                    PermissionManager.requestScreenRecording()
                    PermissionManager.openScreenRecordingSettings()
                } label: {
                    Label(L("bar.grant"), systemImage: "lock.shield").font(.caption)
                }
                .buttonStyle(.borderless)
                .padding(.top, 2)
            }
            if !hasAccessibility {
                Button {
                    PermissionManager.requestAccessibility()
                    PermissionManager.openAccessibilitySettings()
                } label: {
                    Label(L("bar.grantAX"), systemImage: "accessibility").font(.caption)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(16)
        .frame(width: 360, alignment: .leading)
        .background(VisualEffectView().clipShape(RoundedRectangle(cornerRadius: 18)))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.08)))
    }
}

private struct TileView: View {
    let item: BarItem

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(.white.opacity(0.10))
                    .frame(width: 58, height: 44)
                if let img = item.image {
                    Image(nsImage: img)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 30, maxHeight: 26)
                } else {
                    Image(systemName: item.symbolName ?? "app.fill")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.primary)
                }
            }
            if !item.label.isEmpty {
                Text(item.label)
                    .font(.system(size: 9))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 62)
            }
        }
    }
}
