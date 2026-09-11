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
final class TidierBar: NSObject, NSWindowDelegate {
    static let shared = TidierBar()
    private var panel: NSPanel?

    /// Called when the tile closes itself (outside click / app switch) so the
    /// controller can reset its open/closed state.
    var onClose: (() -> Void)?

    var isVisible: Bool { panel?.isVisible ?? false }

    private override init() { super.init() }

    func show(groups: [BarGroup], near rect: NSRect,
              onActivate: @escaping (BarItem) -> Void,
              onStat: @escaping (Stat) -> Void) {
        SystemStats.shared.start()   // live CPU/RAM/battery for the dashboard rings
        let root = TidierBarView(groups: groups,
                                 hasScreenRecording: PermissionManager.hasScreenRecording,
                                 hasAccessibility: PermissionManager.hasAccessibility,
                                 style: Preferences.shared.tileStyle,
                                 onActivate: onActivate,
                                 onStat: onStat)
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
        // behaves like Control Center: losing key focus (a click anywhere else,
        // including the toggle) dismisses it via windowDidResignKey.
        p.makeKeyAndOrderFront(nil)
    }

    func hide() {
        SystemStats.shared.stop()
        panel?.orderOut(nil)
    }

    /// Control-Center-style dismissal: as soon as the panel is no longer the key
    /// window (the user clicked the toggle, another app, or the desktop) close it.
    /// Clicks on the tiles themselves keep the panel key, so they don't trigger this.
    func windowDidResignKey(_ notification: Notification) {
        guard isVisible else { return }
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
        p.delegate = self
        return p
    }

    /// Split into Apple/System vs third-party using real AX identity when available,
    /// falling back to the CGWindow name heuristic. Tidier's own control items drop out.
    static func makeGroups(from items: [MenuBarItemInfo]) -> [BarGroup] {
        var apple: [BarItem] = []
        var third: [BarItem] = []
        for info in items {
            if info.owner == "Tidier" || info.name.hasPrefix("Tidier.") { continue }
            // iStat's CPU/RAM/battery are shown natively as dashboard rings, so drop
            // its (unreliably captured) menu bar items from the mirrored list.
            if info.name.hasPrefix("com.bjango.istatmenus.") { continue }
            let resolved = AXResolver.resolve(at: info.centerX, y: info.centerY)
            if resolved?.bundleId == "de.csho.Tidier" { continue }

            let isApple: Bool = {
                if let b = resolved?.bundleId { return b == "com.apple.controlcenter" || b.hasPrefix("com.apple.") }
                return info.isSystem
            }()
            let label = label(for: info, resolved: resolved, isApple: isApple)
            // Battery is shown natively as a dashboard ring — drop the mirrored
            // system battery item so it doesn't appear twice.
            let low = label.lowercased()
            if isApple && (low.contains("batterie") || low.contains("battery") || low.contains("akku")) { continue }
            let item = BarItem(info: info,
                               image: icon(for: info, resolved: resolved, isApple: isApple),
                               symbolName: isApple ? symbol(for: label, resolved: resolved) : nil,
                               label: label,
                               isApple: isApple,
                               key: stableKey(info: info, resolved: resolved, label: label))
            if isApple { apple.append(item) } else { third.append(item) }
        }
        var groups: [BarGroup] = []
        if !third.isEmpty { groups.append(BarGroup(title: "Apps", items: third)) }
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

/// Left-to-right wrapping layout so each tile keeps its glyph's natural width
/// (wide iStat pills stay wide, simple icons stay square) — a Control-Center row
/// rather than a rigid square grid.
struct TileFlow: Layout {
    var spacing: CGFloat = 10
    var lineSpacing: CGFloat = 12

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? 320
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > maxW, x > 0 { x = 0; y += rowH + lineSpacing; rowH = 0 }
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
        }
        return CGSize(width: maxW, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxW = bounds.width
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > maxW, x > 0 { x = 0; y += rowH + lineSpacing; rowH = 0 }
            s.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + y), proposal: ProposedViewSize(sz))
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
        }
    }
}

struct TidierBarView: View {
    let groups: [BarGroup]
    let hasScreenRecording: Bool
    let hasAccessibility: Bool
    let style: TileStyle
    let onActivate: (BarItem) -> Void
    let onStat: (Stat) -> Void

    @ObservedObject private var model = TileModel.shared
    @ObservedObject private var stats = SystemStats.shared

    private var statItems: [Stat] {
        var s: [Stat] = [
            Stat(key: "sys.cpu", label: "CPU", value: stats.cpu, accent: .orange),
            Stat(key: "sys.ram", label: "RAM", value: stats.ram, accent: Color(red: 0.25, green: 0.78, blue: 0.87)),
        ]
        if let b = stats.battery { s.append(Stat(key: "sys.batt", label: "Batterie", value: b, accent: .green)) }
        return s
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            section(title: "System") {
                TileFlow(spacing: 8, lineSpacing: 8) {
                    ForEach(statItems) { stat in
                        PanelTileView(content: .stat(stat), style: style, onActivate: { onStat(stat) })
                    }
                }
            }
            ForEach(groups) { group in
                let ordered = model.ordered(group.items)
                section(title: group.title) {
                    TileFlow(spacing: 8, lineSpacing: 8) {
                        ForEach(ordered) { item in
                            PanelTileView(content: .item(item), style: style, onActivate: { onActivate(item) })
                                .onDrag { NSItemProvider(object: item.key as NSString) }
                                .onDrop(of: [.plainText], isTargeted: nil) { providers in
                                    guard let p = providers.first else { return false }
                                    let keys = ordered.map { $0.key }
                                    p.loadObject(ofClass: NSString.self) { obj, _ in
                                        guard let s = obj as? String else { return }
                                        DispatchQueue.main.async { model.move(dragged: s, before: item.key, within: keys) }
                                    }
                                    return true
                                }
                        }
                    }
                }
            }
            if !hasScreenRecording {
                Button {
                    PermissionManager.requestScreenRecording(); PermissionManager.openScreenRecordingSettings()
                } label: { Label(L("bar.grant"), systemImage: "lock.shield").font(.caption) }
                .buttonStyle(.borderless).padding(.top, 2)
            }
            if !hasAccessibility {
                Button {
                    PermissionManager.requestAccessibility(); PermissionManager.openAccessibilitySettings()
                } label: { Label(L("bar.grantAX"), systemImage: "accessibility").font(.caption) }
                .buttonStyle(.borderless)
            }
        }
        .padding(16)
        .frame(width: 380, alignment: .leading)
        .background(VisualEffectView().clipShape(RoundedRectangle(cornerRadius: 22)))
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(.white.opacity(0.08)))
    }

    @ViewBuilder private func section<C: View>(title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            content()
                .padding(style == .strip ? 7 : (style == .grid ? 8 : 10))
                .background(Color.primary.opacity(0.05),
                            in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }
}

/// Accent colour per item, matched from its name — the Control-Center palette.
func tileAccent(for label: String) -> Color {
    let s = label.lowercased()
    func has(_ n: [String]) -> Bool { n.contains { s.contains($0) } }
    if has(["wlan", "wi-fi", "wifi", "airport", "airdrop"]) { return .blue }
    if has(["bluetooth"]) { return .blue }
    if has(["batterie", "battery", "akku"]) { return .green }
    if has(["wetter", "weather"]) { return Color(red: 0.39, green: 0.82, blue: 0.94) }
    if has(["fokus", "focus", "nicht stören"]) { return .indigo }
    if has(["ton", "sound", "lautstärke", "volume", "audio", "musik", "music", "läuft"]) { return .pink }
    if has(["spotlight", "suche", "search"]) { return .gray }
    return .blue
}

struct Stat: Identifiable {
    let key: String
    let label: String
    let value: Double
    let accent: Color
    var id: String { key }
}

private enum TileContent { case stat(Stat); case item(BarItem) }

/// Per-tile hover state (the CLI Swift toolchain can't expand the `@State` macro,
/// so hover is kept in a tiny ObservableObject).
private final class TileHover: ObservableObject { @Published var on = false }

/// One tile, rendered in the user-chosen style. Handles both native stats (rings)
/// and captured menu bar items.
private struct PanelTileView: View {
    let content: TileContent
    let style: TileStyle
    let onActivate: () -> Void

    @ObservedObject private var hover = TileHover()

    var body: some View {
        Button(action: onActivate) {
            tile.scaleEffect(hover.on ? 1.03 : 1.0)
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.12), value: hover.on)
        .onHover { inside in
            hover.on = inside
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }

    // MARK: unified content accessors

    private var accent: Color {
        switch content { case .stat(let s): return s.accent; case .item(let i): return tileAccent(for: i.label) }
    }
    private var statValue: Double? { if case .stat(let s) = content { return s.value }; return nil }
    private var itemImage: NSImage? { if case .item(let i) = content { return i.image }; return nil }
    private var symbol: String? {
        switch content {
        case .stat(let s):
            if s.key == "sys.cpu" { return "cpu" }
            if s.key == "sys.ram" { return "memorychip" }
            return "battery.100"
        case .item(let i): return i.symbolName
        }
    }
    private var titleText: String {
        switch content {
        case .stat(let s): return s.label
        case .item(let i):
            return String(i.label.split(separator: ",", maxSplits: 1).first.map(String.init)?
                .trimmingCharacters(in: .whitespaces) ?? i.label)
        }
    }
    private var subtitleText: String? {
        switch content {
        case .stat(let s): return "\(Int(s.value.rounded())) %"
        case .item(let i):
            let parts = i.label.split(separator: ",", maxSplits: 1)
            return parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : nil
        }
    }
    private var isValueGlyph: Bool {
        if case .item(let i) = content, let img = i.image, img.size.height > 0 {
            return img.size.width / img.size.height > 1.7
        }
        return false
    }
    private var isIconOnly: Bool { if case .item(let i) = content { return i.label.isEmpty }; return false }
    private var monogram: String { String(titleText.first ?? "•").uppercased() }
    private var tileFill: Color { Color.primary.opacity(hover.on ? 0.16 : 0.10) }

    // MARK: style dispatch

    @ViewBuilder private var tile: some View {
        switch style {
        case .dashboard: dashboardTile
        case .capsules:  capsuleTile
        case .grid:      gridTile
        case .strip:     stripTile
        }
    }

    // Shared: white disc + tinted glyph
    private func badge(_ d: CGFloat = 34) -> some View {
        ZStack {
            Circle().fill(Color.white.opacity(0.92)).frame(width: d, height: d)
            tintedGlyph(size: d * 0.56)
        }
    }
    @ViewBuilder private func tintedGlyph(size: CGFloat) -> some View {
        Group {
            if let img = itemImage {
                Image(nsImage: img).resizable().renderingMode(.template).interpolation(.high)
                    .scaledToFit().frame(width: size, height: size)
            } else if let sym = symbol {
                Image(systemName: sym).font(.system(size: size - 2, weight: .semibold))
            } else {
                Text(monogram).font(.system(size: size - 3, weight: .bold, design: .rounded))
            }
        }
        .foregroundStyle(accent)
    }
    // Original-colour glyph (for grid/strip — "as in the bar")
    @ViewBuilder private func rawGlyph(height: CGFloat, maxWidth: CGFloat) -> some View {
        if let img = itemImage {
            Image(nsImage: img).resizable().interpolation(.high).scaledToFit()
                .frame(maxWidth: maxWidth, maxHeight: height)
        } else if let sym = symbol {
            Image(systemName: sym).font(.system(size: height * 0.8, weight: .medium)).foregroundStyle(accent)
        } else {
            Text(monogram).font(.system(size: height * 0.72, weight: .bold, design: .rounded)).foregroundStyle(.primary)
        }
    }
    private func ring(_ value: Double, d: CGFloat = 40) -> some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.14), lineWidth: 4)
            Circle().trim(from: 0, to: min(max(value / 100, 0), 1))
                .stroke(accent, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(Int(value.rounded()))").font(.system(size: 11, weight: .bold)).foregroundStyle(.primary)
        }.frame(width: d, height: d)
    }

    // MARK: C — dashboard
    @ViewBuilder private var dashboardTile: some View {
        if let v = statValue {
            HStack(spacing: 10) {
                ring(v)
                VStack(alignment: .leading, spacing: 1) {
                    Text(titleText).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    Text("\(Int(v.rounded())) %").font(.system(size: 14, weight: .semibold))
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).frame(width: 155, height: 54, alignment: .leading)
            .background(tileFill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        } else if isValueGlyph {
            valueGlyphTile(gradient: true)
        } else if isIconOnly {
            squareBadgeTile
        } else {
            capsuleRow
        }
    }

    // MARK: A — capsules
    @ViewBuilder private var capsuleTile: some View {
        if isValueGlyph { valueGlyphTile(gradient: false) }
        else if isIconOnly { squareBadgeTile }
        else { capsuleRow }
    }

    private var capsuleRow: some View {
        HStack(spacing: 9) {
            badge()
            VStack(alignment: .leading, spacing: 1) {
                Text(titleText).font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1).truncationMode(.tail)
                if let sub = subtitleText {
                    Text(sub).font(.system(size: 10.5)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.tail)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9).frame(width: 155, height: 52, alignment: .leading)
        .background(tileFill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func valueGlyphTile(gradient: Bool) -> some View {
        VStack(spacing: 6) {
            if let img = itemImage {
                Image(nsImage: img).resizable().interpolation(.high).scaledToFit().frame(height: 28)
            }
            Text(titleText).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.tail)
        }
        .padding(.horizontal, 16).frame(height: 54).frame(minWidth: 66)
        .background(valueTileBackground(gradient: gradient),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func valueTileBackground(gradient: Bool) -> AnyShapeStyle {
        if gradient {
            return AnyShapeStyle(LinearGradient(
                colors: [accent.opacity(hover.on ? 0.42 : 0.30), accent.opacity(0.12)],
                startPoint: .top, endPoint: .bottom))
        }
        return AnyShapeStyle(tileFill)
    }

    private var squareBadgeTile: some View {
        badge().frame(width: 52, height: 52)
            .background(tileFill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: B — grid
    private var gridTile: some View {
        VStack(spacing: 4) {
            if let v = statValue {
                Text("\(Int(v.rounded()))%").font(.system(size: 13, weight: .semibold))
            } else {
                rawGlyph(height: 24, maxWidth: isValueGlyph ? 42 : 24)
            }
            Text(titleText.isEmpty ? " " : titleText)
                .font(.system(size: 8.5)).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.tail).frame(maxWidth: 58)
        }
        .frame(minWidth: 60, minHeight: 60)
        .padding(.horizontal, isValueGlyph ? 10 : 0)
        .background(tileFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: D — strip
    private var stripTile: some View {
        HStack(spacing: 5) {
            if statValue == nil { rawGlyph(height: 17, maxWidth: 40) }
            else { Image(systemName: symbol ?? "gauge").font(.system(size: 13, weight: .medium)).foregroundStyle(accent) }
            if let v = statValue {
                Text("\(Int(v.rounded()))%").font(.system(size: 11, weight: .semibold))
            } else if isValueGlyph, let sub = valueFromGlyphLabel {
                Text(sub).font(.system(size: 11, weight: .semibold))
            }
        }
        .padding(.horizontal, 7).frame(height: 30)
        .background(hover.on ? tileFill : Color.clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
    private var valueFromGlyphLabel: String? { nil }
}
