import AppKit

/// macOS 27 "Tidier-Leiste": a slim strip that drops down under the menu bar when the user
/// clicks the chevron and shows every item Tidier hides — even when far too many apps live in
/// the bar for Apple's own (notched) menu bar to fit them all. Clicking an icon briefly lets
/// that one item back into the real menu bar and opens it there (see StatusBarController).
///
/// On macOS 27 hidden items are not rendered at all, so their real glyph can't be captured —
/// third-party apps show their app icon, system items an SF Symbol.
struct EngineBarEntry {
    enum Kind { case app(bundleID: String, pid: pid_t), system(id: Int) }
    let kind: Kind
    let name: String
    let image: NSImage?
    let isTemplate: Bool
    /// Apple/system group (Spotlight + system items) — shown after a divider.
    var isSystemGroup: Bool { isTemplate }

    /// All items currently hidden by the engine: hidden third-party apps that are running,
    /// Spotlight (if hidden) and hidden system items.
    static func currentlyHidden() -> [EngineBarEntry] {
        let prefs = Preferences.shared
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var apps: [EngineBarEntry] = []
        var seen = Set<String>()
        for app in NSWorkspace.shared.runningApplications {
            guard let bid = app.bundleIdentifier, app.processIdentifier != ownPID,
                  prefs.hiddenBundleIDs.contains(bid), !seen.contains(bid) else { continue }
            seen.insert(bid)
            let name = TidierBar.cleanAppName(app.localizedName ?? bid)
            apps.append(EngineBarEntry(kind: .app(bundleID: bid, pid: app.processIdentifier),
                                       name: name, image: app.icon, isTemplate: false))
        }
        apps.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        var system: [EngineBarEntry] = []
        if prefs.hideSpotlight,
           let app = MenuBarHideEngine.spotlightBundleIDs
               .lazy.compactMap({ NSRunningApplication.runningApplications(withBundleIdentifier: $0).first }).first,
           let bid = app.bundleIdentifier {
            system.append(EngineBarEntry(kind: .app(bundleID: bid, pid: app.processIdentifier),
                                         name: "Spotlight", image: Self.symbol("magnifyingglass"),
                                         isTemplate: true))
        }
        for item in MenuBarHideEngine.knownSystemItems where prefs.isSystemItemHidden(item.id) {
            system.append(EngineBarEntry(kind: .system(id: item.id), name: L(item.labelKey),
                                         image: Self.symbol(item.symbol), isTemplate: true))
        }
        return apps + system
    }

    private static func symbol(_ name: String) -> NSImage? {
        let cfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
        img?.isTemplate = true
        return img
    }
}

final class EngineBar: NSObject, NSWindowDelegate {
    static let shared = EngineBar()
    private var panel: NSPanel?
    var onClose: (() -> Void)?
    var isVisible: Bool { panel?.isVisible ?? false }

    private static let barHeight: CGFloat = 34
    private static let cell: CGFloat = 30

    /// Open the strip directly under the menu bar, right edge aligned with the chevron.
    func show(entries: [EngineBarEntry], near anchor: NSRect, onActivate: @escaping (EngineBarEntry) -> Void) {
        let p = panel ?? makePanel()
        panel = p
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(anchor) }) ?? NSScreen.main
        let maxW = (screen?.frame.width ?? 1400) - 16

        // Content: icon buttons, a thin divider between apps and system items.
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 6, bottom: 2, right: 6)
        var lastWasApp: Bool?
        for e in entries {
            let isApp = !e.isSystemGroup
            if let last = lastWasApp, last != isApp { stack.addArrangedSubview(Self.divider()) }
            lastWasApp = isApp
            let b = BarIconButton(entry: e, size: Self.cell) { [weak self] entry in
                self?.hide()
                onActivate(entry)
            }
            stack.addArrangedSubview(b)
        }
        if entries.isEmpty {
            let label = NSTextField(labelWithString: L("bar.empty"))
            label.font = .systemFont(ofSize: 12)
            label.textColor = .secondaryLabelColor
            stack.edgeInsets = NSEdgeInsets(top: 2, left: 14, bottom: 2, right: 14)
            stack.addArrangedSubview(label)
        }
        stack.layoutSubtreeIfNeeded()
        let width = min(maxW, max(60, ceil(stack.fittingSize.width)))
        let h = Self.barHeight

        let container = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: width, height: h))
        container.material = .menu
        container.blendingMode = .behindWindow
        container.state = .active
        container.wantsLayer = true
        container.layer?.cornerRadius = 10
        container.layer?.masksToBounds = true
        container.layer?.borderWidth = 1
        container.layer?.borderColor = NSColor.white.withAlphaComponent(0.10).cgColor
        stack.frame = container.bounds
        stack.autoresizingMask = [.width, .height]
        container.addSubview(stack)
        p.contentView = container
        p.setContentSize(NSSize(width: width, height: h))

        if let screen {
            // Directly under the menu bar (visibleFrame.maxY = bottom edge of the bar).
            let x = min(max(screen.frame.minX + 8, anchor.maxX - width), screen.frame.maxX - width - 8)
            let y = screen.visibleFrame.maxY - h - 4
            p.setFrameOrigin(NSPoint(x: x, y: y))
        }
        let wasVisible = p.isVisible
        if !wasVisible { p.alphaValue = 0 }
        p.makeKeyAndOrderFront(nil)
        if !wasVisible {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.14
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                p.animator().alphaValue = 1
            }
        }
    }

    func hide() {
        guard let p = panel, p.isVisible else { return }
        p.orderOut(nil)
        onClose?()
    }

    func windowDidResignKey(_ notification: Notification) { hide() }

    private static func divider() -> NSView {
        let v = NSBox()
        v.boxType = .separator
        v.translatesAutoresizingMaskIntoConstraints = false
        v.widthAnchor.constraint(equalToConstant: 1).isActive = true
        v.heightAnchor.constraint(equalToConstant: 18).isActive = true
        return v
    }

    private func makePanel() -> NSPanel {
        let p = StripPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: Self.barHeight),
                           styleMask: [.borderless, .nonactivatingPanel],
                           backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .statusBar
        p.hidesOnDeactivate = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.animationBehavior = .none
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.delegate = self
        return p
    }
}

private final class StripPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// One icon in the strip: menu-bar-like hover highlight, tooltip with the app's name.
private final class BarIconButton: NSView {
    private let entry: EngineBarEntry
    private let action: (EngineBarEntry) -> Void
    private let imageView = NSImageView()
    private var hovering = false { didSet { needsDisplay = true } }

    init(entry: EngineBarEntry, size: CGFloat, action: @escaping (EngineBarEntry) -> Void) {
        self.entry = entry
        self.action = action
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: size).isActive = true
        heightAnchor.constraint(equalToConstant: size).isActive = true
        toolTip = entry.name
        setAccessibilityLabel(entry.name)
        setAccessibilityRole(.button)
        imageView.image = entry.image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        if entry.isTemplate { imageView.contentTintColor = .labelColor }
        let icon: CGFloat = entry.isTemplate ? 16 : 20
        imageView.frame = NSRect(x: (size - icon) / 2, y: (size - icon) / 2, width: icon, height: icon)
        addSubview(imageView)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    // The icon must not swallow the click (NSImageView eats mouseDown).
    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action(entry) }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard hovering else { return }
        NSColor.labelColor.withAlphaComponent(0.12).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 2), xRadius: 6, yRadius: 6).fill()
    }
}
