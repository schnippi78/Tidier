import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct BarItem: Identifiable {
    let info: MenuBarItemInfo
    let image: NSImage?      // captured menu-bar icon (exactly what sits in the bar)
    let symbolName: String?  // SF Symbol fallback (Apple/system items)
    let label: String        // "" → icon-only tile (Control-Center style)
    let isApple: Bool
    let key: String          // stable identity for persisted ordering
    var id: Int { info.id }
}

struct BarGroup: Identifiable {
    let title: String
    let items: [BarItem]
    var id: String { title }
}

/// Persistent, drag-to-reorder ordering of the tiles ("selbst anordnen").
/// Holds one flat list of stable item keys; each group is displayed sorted by it.
final class TileModel: ObservableObject {
    static let shared = TileModel()
    private static let defaultsKey = "tidier.tileOrder"

    @Published private(set) var rev = 0
    private var order: [String]

    init() { order = UserDefaults.standard.stringArray(forKey: Self.defaultsKey) ?? [] }

    /// Items sorted by the saved order; unknown (new) items keep their scan order at the end.
    func ordered(_ items: [BarItem]) -> [BarItem] {
        guard !order.isEmpty else { return items }
        var rank = [String: Int]()
        for (i, k) in order.enumerated() { rank[k] = i }
        return items.enumerated().sorted { a, b in
            let ra = rank[a.element.key] ?? (1_000_000 + a.offset)
            let rb = rank[b.element.key] ?? (1_000_000 + b.offset)
            return ra < rb
        }.map { $0.element }
    }

    /// Move `dragged` in front of `target` within the currently displayed group order.
    func move(dragged: String, before target: String, within keys: [String]) {
        guard dragged != target, keys.contains(dragged) else { return }
        var seq = keys
        seq.removeAll { $0 == dragged }
        if let i = seq.firstIndex(of: target) { seq.insert(dragged, at: i) }
        else { seq.append(dragged) }
        var merged = order.filter { !keys.contains($0) }   // other groups' entries stay put
        merged.append(contentsOf: seq)
        order = merged
        UserDefaults.standard.set(order, forKey: Self.defaultsKey)
        rev += 1
    }
}

/// The "Tidier Bar": an elegant Control-Center-style panel that shows the hidden
/// menu bar items, grouped into Apple/System and third-party. Opened when the user
/// collapses the menu bar. Tiles are clickable (forward the click to the real item)
/// and can be reordered by dragging.
final class TidierBar {
    static let shared = TidierBar()
    private var panel: NSPanel?
    private var outsideClickMonitor: Any?
    private var localClickMonitor: Any?
    private var toggleRect: NSRect = .zero

    /// Called when the tile closes itself (outside click / app switch) so the
    /// controller can reset its open/closed state.
    var onClose: (() -> Void)?

    var isVisible: Bool { panel?.isVisible ?? false }

    func show(groups: [BarGroup], near rect: NSRect, onActivate: @escaping (BarItem) -> Void) {
        toggleRect = rect
        let root = TidierBarView(groups: groups,
                                 hasScreenRecording: PermissionManager.hasScreenRecording,
                                 hasAccessibility: PermissionManager.hasAccessibility,
                                 onActivate: onActivate)
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
        // Key (so buttons & drag-reorder receive events) but non-activating, so it
        // behaves like Control Center and still dismisses on outside clicks.
        p.makeKeyAndOrderFront(nil)
        startDismissMonitors()
    }

    func hide() {
        stopDismissMonitors()
        panel?.orderOut(nil)
    }

    /// Close the tile as soon as the user clicks anywhere outside it (in any app)
    /// so it never lingers in the foreground — but never swallow a click on the
    /// toggle itself, so clicking `<` cleanly closes the tile via the controller.
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
        // Let the toggle button handle its own click (open ⇄ close) rather than
        // racing it here — otherwise `<` would close then instantly reopen.
        if toggleRect.insetBy(dx: -4, dy: -4).contains(NSEvent.mouseLocation) { return }
        hide()
        onClose?()
    }

    private func makePanel() -> NSPanel {
        let p = TilePanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 160),
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
                               isApple: isApple,
                               key: stableKey(info: info, resolved: resolved, label: label))
            if isApple { apple.append(item) } else { third.append(item) }
        }
        var groups: [BarGroup] = []
        if !third.isEmpty { groups.append(BarGroup(title: L("bar.thirdParty"), items: third)) }
        if !apple.isEmpty { groups.append(BarGroup(title: L("bar.apple"), items: apple)) }
        return groups
    }

    /// Stable across relaunches (window ids are not): bundle id + title, else the
    /// CGWindow name, else owner + label.
    private static func stableKey(info: MenuBarItemInfo, resolved: ResolvedItem?, label: String) -> String {
        if let b = resolved?.bundleId, !b.isEmpty { return "b:" + b + "#" + (resolved?.title ?? label) }
        if !info.name.isEmpty && info.name != "Item-0" { return "n:" + info.name }
        return "o:" + info.owner + "#" + label
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

    /// The tile shows exactly what sits in the menu bar: the captured item glyph
    /// (needs Screen Recording). We deliberately do NOT fall back to the owning
    /// app's Dock icon — that's the wrong picture. Without a capture we let the
    /// tile render an SF Symbol (Apple items) or a monogram.
    private static func icon(for info: MenuBarItemInfo, resolved: ResolvedItem?, isApple: Bool) -> NSImage? {
        if PermissionManager.hasScreenRecording, let cap = ItemCapture.image(forWindow: info.id) {
            return cap
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

/// Borderless panel that can still become key, so SwiftUI buttons and drag-to-
/// reorder inside it receive events (the default is `false` for borderless).
private final class TilePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
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
    let onActivate: (BarItem) -> Void

    @ObservedObject private var model = TileModel.shared

    private let columns = [GridItem(.adaptive(minimum: 72), spacing: 10)]

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
                let ordered = model.ordered(group.items)
                VStack(alignment: .leading, spacing: 8) {
                    Text(group.title.uppercased())
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                        ForEach(ordered) { item in
                            TileView(item: item, onActivate: { onActivate(item) })
                                .onDrag { NSItemProvider(object: item.key as NSString) }
                                .onDrop(of: [.plainText], isTargeted: nil) { providers in
                                    guard let p = providers.first else { return false }
                                    let keys = ordered.map { $0.key }
                                    p.loadObject(ofClass: NSString.self) { obj, _ in
                                        guard let s = obj as? String else { return }
                                        DispatchQueue.main.async {
                                            model.move(dragged: s, before: item.key, within: keys)
                                        }
                                    }
                                    return true
                                }
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

/// Per-tile hover state (the CLI Swift toolchain can't expand the `@State` macro,
/// so hover is kept in a tiny ObservableObject).
private final class TileHover: ObservableObject { @Published var on = false }

/// A single Control-Center-style tile: rounded translucent square, the real menu
/// bar glyph centered, an optional caption below. Clicking activates the real item.
private struct TileView: View {
    let item: BarItem
    let onActivate: () -> Void

    @ObservedObject private var hover = TileHover()

    private let side: CGFloat = 60

    var body: some View {
        Button(action: onActivate) {
            VStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .fill(Color.primary.opacity(hover.on ? 0.20 : 0.12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 15, style: .continuous)
                                .strokeBorder(.white.opacity(hover.on ? 0.18 : 0.08))
                        )
                        .frame(width: side, height: side)
                    glyph
                }
                .scaleEffect(hover.on ? 1.06 : 1.0)
                if !item.label.isEmpty {
                    Text(item.label)
                        .font(.system(size: 10))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: side + 12)
                }
            }
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.12), value: hover.on)
        .onHover { inside in
            hover.on = inside
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }

    @ViewBuilder private var glyph: some View {
        if let img = item.image {
            Image(nsImage: img)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 26, maxHeight: 24)
        } else if let sym = item.symbolName {
            Image(systemName: sym)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.primary)
        } else {
            Text(monogram)
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
        }
    }

    private var monogram: String {
        String(item.label.first ?? item.info.owner.first ?? "•").uppercased()
    }
}
