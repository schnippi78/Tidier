import AppKit

/// Manages Tidier's own status items and the hide/show mechanism.
///
/// Mechanism (the same proven AppKit trick used by Hidden Bar / Dozer and,
/// underneath, Bartender): the menu bar lays out status items contiguously from
/// the right edge leftwards. By expanding a "separator" status item to a huge
/// width, every item to its LEFT is pushed off the left edge of the screen and
/// becomes invisible — no accessibility permissions required. The user arranges
/// which icons are hidden by ⌘-dragging them to the left of the separator.
final class StatusBarController {
    static var shared: StatusBarController?

    private let bar = NSStatusBar.system
    private var mainItem: NSStatusItem!          // always-visible toggle (rightmost)
    private var hiddenSep: NSStatusItem!         // items to its left = "hidden"
    private var alwaysSep: NSStatusItem?         // items to its left = "always hidden"

    private let normalLength: CGFloat = 24
    private let sepLength: CGFloat = 10
    private let collapsedLength: CGFloat = 10_000

    private var expanded = true   // true only briefly at launch to cache items; resting = collapsed
    private var revealingAlways = false
    private var rehideTimer: Timer?
    private var hoverMonitor: Any?
    private var tileOpen = false
    private var cachedGroups: [BarGroup] = []
    /// When the panel was last dismissed, so the very click that dismissed it
    /// (via the outside-click monitor) can't immediately re-open it.
    private var lastTileClose = Date.distantPast
    /// While a tile-activated item's menu is open, the bar stays revealed; these
    /// re-hide it once the user is done (next click, or a safety timeout).
    private var revealCollapseMonitor: Any?
    private var revealSafetyTimer: Timer?
    private var arranging = false   // Arrange mode: bar fully revealed, separator marked

    init() {
        StatusBarController.shared = self
        buildItems()
        applyLayout()
        setupHover()
        TidierBar.shared.onClose = { [weak self] in
            self?.tileOpen = false
            self?.lastTileClose = Date()
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(prefsChanged),
            name: .tidierPrefsChanged, object: nil)
        // Items are visible now; cache them, then settle into the clean resting state.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            self?.refreshCache()
            self?.collapseToResting()
        }
    }

    // MARK: - Build

    /// Seed sensible initial positions on first launch so hiding works out of the box.
    ///
    /// macOS stores each status item's spot in `"NSStatusItem Preferred Position <autosaveName>"`.
    /// A *smaller* value means further right (verified against Ice's own defaults). We put the
    /// toggle rightmost among movable items, the hidden separator just to its left, and the
    /// always-hidden separator further left — so by default ALL other menu bar icons fall to the
    /// left of the separator and disappear on the first collapse, with no manual ⌘-drag.
    private func seedDefaultPositionsIfNeeded() {
        let d = UserDefaults.standard
        let flag = "seededPositionsV1"
        guard !d.bool(forKey: flag) else { return }
        d.set(0,   forKey: "NSStatusItem Preferred Position Tidier.Main")
        d.set(32,  forKey: "NSStatusItem Preferred Position Tidier.HiddenSeparator")
        d.set(64,  forKey: "NSStatusItem Preferred Position Tidier.AlwaysHiddenSeparator")
        d.set(true, forKey: flag)
    }

    private func buildItems() {
        seedDefaultPositionsIfNeeded()
        // Create rightmost first so the separators land to its left by default.
        mainItem = bar.statusItem(withLength: normalLength)
        mainItem.autosaveName = "Tidier.Main"
        configureToggleButton(mainItem.button)

        hiddenSep = bar.statusItem(withLength: sepLength)
        hiddenSep.autosaveName = "Tidier.HiddenSeparator"
        configureSeparatorButton(hiddenSep.button, dim: false)

        if Preferences.shared.enableAlwaysHidden { addAlwaysSeparator() }
    }

    private func addAlwaysSeparator() {
        guard alwaysSep == nil else { return }
        let it = bar.statusItem(withLength: sepLength)
        it.autosaveName = "Tidier.AlwaysHiddenSeparator"
        configureSeparatorButton(it.button, dim: true)
        alwaysSep = it
    }

    private func removeAlwaysSeparator() {
        if let it = alwaysSep { bar.removeStatusItem(it); alwaysSep = nil }
    }

    private func configureToggleButton(_ button: NSStatusBarButton?) {
        guard let b = button else { return }
        if let img = symbol(expanded ? "chevron.right" : "chevron.left") {
            b.image = img
            b.image?.isTemplate = true
        } else {
            b.title = "T"   // fallback so the toggle is never invisible
        }
        b.target = self
        b.action = #selector(mainClicked)
        b.sendAction(on: [.leftMouseUp, .rightMouseUp])
        b.toolTip = "Tidier"
    }

    private func configureSeparatorButton(_ button: NSStatusBarButton?, dim: Bool) {
        guard let b = button else { return }
        b.image = symbol("line.diagonal")
        b.image?.isTemplate = true
        b.appearsDisabled = dim
        b.target = self
        b.action = #selector(mainClicked)
        b.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func symbol(_ name: String) -> NSImage? {
        let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        return NSImage(systemSymbolName: name, accessibilityDescription: name)?
            .withSymbolConfiguration(cfg)
    }

    // MARK: - Interaction

    @objc private func mainClicked() {
        if arranging { return }   // while arranging, the HUD's "Fertig" is the exit
        if let e = NSApp.currentEvent,
           e.type == .rightMouseUp || e.modifierFlags.contains(.control) {
            showMenu()
        } else {
            toggleTile()
        }
    }

    /// Left-click: open/close the tile. The menu bar stays collapsed either way —
    /// the hidden icons live only in the tile, never back in the bar. We key off the
    /// panel's real visibility (not a bool the dismiss monitor may already have
    /// flipped) and debounce, so one click on `<` can only ever toggle once.
    private func toggleTile() {
        if TidierBar.shared.isVisible {
            closeTile()
        } else if Date().timeIntervalSince(lastTileClose) > 0.25 {
            openTile()
        }
        // else: this is the same click that just dismissed the panel — ignore it.
    }

    private func openTile() {
        // macOS can't snapshot a hidden (off-screen) status item, so to show the tiles
        // with *live* glyph values (iStat %, weather °C) we reveal the bar for a beat,
        // re-capture + re-resolve every item while it's on-screen, then collapse and
        // present the panel. Falls back to the last snapshot if capture yields nothing.
        expanded = true
        revealingAlways = false
        applyLayout()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self = self else { return }
            let fresh = TidierBar.makeGroups(from: self.hiddenCandidates())
            if !fresh.isEmpty { self.cachedGroups = fresh; ScannerModel.shared.detected = fresh.flatMap { $0.items } }
            self.expanded = false
            self.applyLayout()
            self.presentTile()
        }
    }

    private func presentTile() {
        if cachedGroups.isEmpty { cachedGroups = TidierBar.makeGroups(from: hiddenCandidates()) }
        TidierBar.shared.show(groups: cachedGroups,
                              near: toggleScreenRect(),
                              onActivate: { [weak self] in self?.activateItem($0) },
                              onStat: { [weak self] in self?.activateStat($0) })
        tileOpen = true
    }

    /// The System rings aren't real menu bar items — open the matching system app:
    /// CPU/RAM/Disk/Network → Activity Monitor, battery → Battery settings.
    private func activateStat(_ stat: Stat) {
        closeTile()
        if stat.key == "sys.batt" {
            if let url = URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension") {
                NSWorkspace.shared.open(url)
            }
            return
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.ActivityMonitor") {
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: cfg)
        }
    }

    /// Clicking a tile activates the real menu bar item behind it (Ice-Bar style).
    /// The item is currently pushed off-screen, so we reveal the bar, click the item
    /// at its true position, and then — crucially — put the cursor back where the user
    /// clicked and LEAVE the bar revealed so the item's own menu stays open and usable.
    /// The bar re-hides on the user's next click (or a safety timeout). Needs
    /// Accessibility to post the click — the tile shows a grant button otherwise.
    private func activateItem(_ item: BarItem) {
        closeTile()
        expanded = true
        revealingAlways = false
        applyLayout()
        // Let the menu bar finish re-laying-out the revealed items before clicking.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self = self else { return }
            // Leave the cursor at the item so its just-opened menu is right under the
            // pointer, ready to use (the click warped it there — we keep it).
            self.clickMenuBarItem(windowID: item.info.id, name: item.info.name, owner: item.info.owner)
            self.armRevealCollapse()
        }
    }

    /// Re-scan for the item's CURRENT on-screen position (window ids are stable while
    /// they live; fall back to name/owner) and post a left click there.
    private func clickMenuBarItem(windowID: Int, name: String, owner: String) {
        let items = MenuBarScanner.scan()
        let target = items.first { $0.id == windowID }
            ?? items.first { !name.isEmpty && $0.name == name }
            ?? items.first { $0.owner == owner && owner != "Tidier" }
        guard let t = target else { return }
        // CGWindow bounds share CGEvent's top-left global coordinate space.
        let p = CGPoint(x: t.centerX, y: t.centerY)
        let src = CGEventSource(stateID: .combinedSessionState)
        CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: p, mouseButton: .left)?
            .post(tap: .cghidEventTap)
        CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: p, mouseButton: .left)?
            .post(tap: .cghidEventTap)
    }

    /// After activating an item its menu is open and the bar stays revealed. Keep it
    /// revealed as long as the user keeps clicking *in the menu bar* (so they can open
    /// other items' menus too); collapse only when they click below the bar — into an
    /// app or the desktop — or after a safety timeout.
    private func armRevealCollapse() {
        disarmRevealCollapse()
        revealCollapseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                guard let self = self else { return }
                if self.clickIsInMenuBar() {
                    self.bumpRevealSafety()          // still using the bar — keep it open
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                        self?.finishReveal()
                    }
                }
        }
        bumpRevealSafety()
    }

    private func clickIsInMenuBar() -> Bool {
        let loc = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(loc) }) ?? NSScreen.main
        else { return false }
        let menuBarHeight = max(screen.frame.maxY - screen.visibleFrame.maxY, 24)
        return loc.y >= screen.frame.maxY - menuBarHeight
    }

    private func bumpRevealSafety() {
        revealSafetyTimer?.invalidate()
        revealSafetyTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { [weak self] _ in
            self?.finishReveal()
        }
    }

    private func disarmRevealCollapse() {
        if let m = revealCollapseMonitor { NSEvent.removeMonitor(m); revealCollapseMonitor = nil }
        revealSafetyTimer?.invalidate(); revealSafetyTimer = nil
    }

    private func finishReveal() {
        disarmRevealCollapse()
        ensureCollapsed()
    }

    private func closeTile() {
        TidierBar.shared.hide()
        tileOpen = false
        lastTileClose = Date()
    }

    /// Hide icons from the menu bar without touching the tile/cache.
    private func ensureCollapsed() {
        guard expanded else { return }
        expanded = false
        revealingAlways = false
        applyLayout()
    }

    /// Resolve + cache the currently visible items for the tile (only valid while
    /// they are on-screen, i.e. expanded).
    private func refreshCache() {
        guard expanded else { return }
        cachedGroups = TidierBar.makeGroups(from: hiddenCandidates())
        ScannerModel.shared.detected = cachedGroups.flatMap { $0.items }
    }

    /// Re-detect the real hidden items for the Settings list: reveal briefly (so they
    /// are on-screen and identifiable), capture, publish, then restore.
    func refreshDetected() {
        let wasExpanded = expanded
        let wasAlways = revealingAlways
        expanded = true
        revealingAlways = true
        applyLayout()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self = self else { return }
            let groups = TidierBar.makeGroups(from: self.hiddenCandidates())
            ScannerModel.shared.detected = groups.flatMap { $0.items }
            if !self.arranging {
                self.expanded = wasExpanded
                self.revealingAlways = wasAlways
                self.applyLayout()
            }
        }
    }

    private func collapseToResting() {
        expanded = false
        revealingAlways = false
        applyLayout()
        tileOpen = false
    }

    /// Rare: put the hidden icons back into the menu bar (right-click option).
    func showInBar() {
        closeTile()
        guard !expanded else { return }
        expanded = true
        applyLayout()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.refreshCache() }
    }

    private func toggleScreenRect() -> NSRect {
        mainItem.button?.window?.frame
            ?? NSRect(x: 0, y: (NSScreen.main?.frame.maxY ?? 900) - 24, width: 24, height: 24)
    }

    private func hiddenCandidates() -> [MenuBarItemInfo] {
        let threshold = mainItem.button?.window?.frame.minX ?? .greatestFiniteMagnitude
        return MenuBarScanner.scan().filter { $0.owner != "Tidier" && $0.x + $0.width <= threshold + 2 }
    }

    private func toggleAlwaysReveal() {
        revealingAlways.toggle()
        if revealingAlways { expanded = true }
        applyLayout()
        scheduleRehideIfNeeded()
    }

    private func applyLayout() {
        hiddenSep.length = (expanded || arranging) ? sepLength : collapsedLength
        alwaysSep?.length = (revealingAlways || arranging) ? sepLength : collapsedLength
        mainItem.button?.image = symbol(expanded ? "chevron.right" : "chevron.left")
        // Mark the hidden-separator clearly while arranging: it is the "hidden ↔ visible"
        // boundary the user drags items across.
        if let b = hiddenSep.button {
            b.image = symbol(arranging ? "arrow.left.and.right" : "line.diagonal")
            b.image?.isTemplate = true
        }
    }

    // MARK: - Arrange mode

    /// Reveal everything and mark the separator so the user can ⌘-drag which icons
    /// stay always-visible (right of the marker) vs. hidden (left). macOS 26 blocks
    /// programmatic reordering, so this guides the one-time manual arrangement.
    func enterArrangeMode() {
        guard !arranging else { return }
        closeTile()
        arranging = true
        expanded = true
        revealingAlways = true
        rehideTimer?.invalidate()
        applyLayout()
        ArrangeHUD.shared.onDone = { [weak self] in self?.exitArrangeMode() }
        ArrangeHUD.shared.show(near: toggleScreenRect())
    }

    func exitArrangeMode() {
        guard arranging else { return }
        arranging = false
        ArrangeHUD.shared.hide()
        expanded = false
        revealingAlways = false
        applyLayout()
    }

    // MARK: - Auto re-hide

    private func scheduleRehideIfNeeded() {
        rehideTimer?.invalidate()
        guard !arranging, expanded, Preferences.shared.autoRehide else { return }
        let interval = TimeInterval(Preferences.shared.rehideInterval)
        rehideTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            self?.ensureCollapsed()
        }
    }

    // MARK: - Hover reveal

    private func setupHover() {
        if let m = hoverMonitor { NSEvent.removeMonitor(m); hoverMonitor = nil }
        guard Preferences.shared.revealOnHover else { return }
        hoverMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            self?.handleHover()
        }
    }

    private func handleHover() {
        guard Preferences.shared.revealOnHover, !tileOpen, !arranging else { return }
        let loc = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(loc) }) ?? NSScreen.main else { return }
        let menuBarHeight = screen.frame.maxY - screen.visibleFrame.maxY
        let strip = max(menuBarHeight, 24)
        if loc.y >= screen.frame.maxY - strip {
            openTile()
        }
    }

    // MARK: - Context menu

    private func showMenu() {
        let menu = NSMenu()
        let toggle = NSMenuItem(title: expanded ? L("menu.hide") : L("menu.show"),
                                action: #selector(menuToggle), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)

        let arrange = NSMenuItem(title: "Menüleiste anordnen…",
                                 action: #selector(menuArrange), keyEquivalent: "")
        arrange.target = self
        menu.addItem(arrange)

        if alwaysSep != nil {
            let a = NSMenuItem(title: L("menu.alwaysHidden"),
                               action: #selector(menuAlways), keyEquivalent: "")
            a.target = self
            menu.addItem(a)
        }
        menu.addItem(.separator())

        // Design picker
        let design = NSMenuItem(title: "Design", action: nil, keyEquivalent: "")
        let designMenu = NSMenu()
        let current = Preferences.shared.tileStyle
        for style in TileStyle.allCases {
            let mi = NSMenuItem(title: style.title, action: #selector(menuPickStyle(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = style.rawValue
            mi.state = (style == current) ? .on : .off
            designMenu.addItem(mi)
        }
        design.submenu = designMenu
        menu.addItem(design)

        menu.addItem(.separator())

        let settings = NSMenuItem(title: L("menu.settings"),
                                  action: #selector(menuSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let about = NSMenuItem(title: L("menu.about"),
                               action: #selector(menuAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: L("menu.quit"),
                              action: #selector(menuQuit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        mainItem.menu = menu
        mainItem.button?.performClick(nil)
        mainItem.menu = nil   // restore left-click toggle behaviour afterwards
    }

    @objc private func menuPickStyle(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let style = TileStyle(rawValue: raw) else { return }
        Preferences.shared.tileStyle = style
        // Reopen the panel so the new style shows immediately.
        if TidierBar.shared.isVisible { closeTile(); openTile() }
    }

    @objc private func menuArrange() {
        if arranging { exitArrangeMode() } else { enterArrangeMode() }
    }

    @objc private func menuToggle()  {
        if expanded { refreshCache(); ensureCollapsed() } else { showInBar() }
    }
    @objc private func menuAlways()  { toggleAlwaysReveal() }
    @objc private func menuSettings(){ SettingsWindowController.shared.show() }
    @objc private func menuAbout()   { SettingsWindowController.shared.show(tab: .about) }
    @objc private func menuQuit()    { NSApp.terminate(nil) }

    // MARK: - Preferences

    @objc private func prefsChanged() {
        if Preferences.shared.enableAlwaysHidden { addAlwaysSeparator() }
        else { removeAlwaysSeparator() }
        setupHover()
        applyLayout()
    }
}
