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

    /// Background auto-refresh: a cheap `scanAll()` poll (just reads the window list,
    /// invisible) watches the *set* of menu bar items. Only when it changes (an app
    /// added/removed its item) do we run the expensive move-capture rebuild — so the
    /// visible bar shuffle happens only when something really changed, never on a blind timer.
    private var watchTimer: Timer?
    private var lastBarSignature = ""

    /// macOS 27+: hide via the MenuBarClientCore engine (allow-list) instead of the dead
    /// length-trick / move-capture. All the capture/move machinery is bypassed on this path.
    private let usesEngine = MenuBarHideEngine.shared.isAvailable
    /// Engine path only: true while the bar is revealed (restriction lifted).
    private var engineRevealed = false

    init() {
        StatusBarController.shared = self
        buildItems()
        setupHover()
        NotificationCenter.default.addObserver(
            self, selector: #selector(prefsChanged),
            name: .tidierPrefsChanged, object: nil)

        if usesEngine {
            // macOS 27 path: drive MenuBarAgent directly. No panel/capture/move.
            updateChevron()
            // Small settle so every app's AXExtrasMenuBar is ready before the first scan —
            // otherwise an app the scan misses would briefly get hidden until the next re-apply.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.engineCollapse()        // resting = hidden apps gone
                self?.startEngineWatch()       // re-apply allow-list as apps launch/quit
            }
            return
        }

        applyLayout()
        TidierBar.shared.onClose = { [weak self] in
            self?.tileOpen = false
            self?.lastTileClose = Date()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            self?.refreshCache()
            self?.collapseToResting()
            // Let the collapse settle before the capture reveals again — otherwise items are
            // still in flight and the move-capture misses most of them.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                // ONE full move-capture at launch: reveals + stages the notch-overflow icons so
                // ALL items (incl. ChatGPT/Spotlight/Emoji) get a real glyph. This is the only
                // visible shuffle; from here the background keeps the list current invisibly.
                self?.rebuildFullCache()
                self?.startAutoRefresh()
            }
        }
    }

    // MARK: - macOS 27 engine path (MenuBarClientCore allow-list)

    /// Compute the allow-list for the collapsed state and apply it: every running app stays
    /// visible EXCEPT the ones the user hid. Revealing lifts the restriction entirely.
    private func applyEngineAllowList() {
        // Keep visible = the Apple system agents (always) + the third-party menu-bar apps the
        // user did NOT hide. Precise, scan-based: allow-listing *all* running apps (over-permissive)
        // makes MenuBarAgent no-op the restriction, so we list only real menu-bar apps.
        let hidden = Preferences.shared.hiddenBundleIDs
        // Keep visible = the third-party menu-bar apps the user did NOT hide, plus Tidier's own
        // toggle (the reveal control). System agents are added by the engine. Everything else is
        // left out → MenuBarAgent hides it. Scan-based (precise): allow-listing *all* running apps
        // is over-permissive and makes MenuBarAgent no-op the restriction.
        var allow = Set(MenuBarApps.scanBundleIDs()).subtracting(hidden)
        if let own = Bundle.main.bundleIdentifier { allow.insert(own) }
        // Spotlight/Siri (campo) is allowed unless the user chose to hide it.
        if !Preferences.shared.hideSpotlight { allow.formUnion(MenuBarHideEngine.spotlightBundleIDs) }
        let allowedSys = MenuBarHideEngine.allowedSystemItems(hiding: Preferences.shared.hiddenSystemItemIDs)
        MenuBarHideEngine.shared.restrict(keepVisibleBundleIDs: Array(allow),
                                          allowedSystemItems: allowedSys) { _ in }
    }

    private func engineCollapse() {
        engineRevealed = false
        disarmRevealCollapse()
        rehideTimer?.invalidate()
        applyEngineAllowList()
        updateChevron()
    }

    private func engineReveal() {
        engineRevealed = true
        MenuBarHideEngine.shared.release()     // show everything
        updateChevron()
        // Re-hide on click outside the menu bar, or after the auto-rehide interval.
        armRevealCollapse()
        if Preferences.shared.autoRehide {
            rehideTimer?.invalidate()
            rehideTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(Preferences.shared.rehideInterval),
                                               repeats: false) { [weak self] _ in self?.engineCollapse() }
        }
    }

    private func engineToggle() {
        if engineRevealed { engineCollapse() } else { engineReveal() }
    }

    /// React to apps launching/quitting: while collapsed, re-apply so a newly launched app is
    /// allowed (stays visible) unless the user hid it, and a quit app drops out cleanly.
    private func startEngineWatch() {
        let wsc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            wsc.addObserver(self, selector: #selector(engineAppsChanged), name: name, object: nil)
        }
    }

    @objc private func engineAppsChanged() {
        watchTimer?.invalidate()
        let t = Timer(timeInterval: 1.2, repeats: false) { [weak self] _ in
            guard let self = self, !self.engineRevealed else { return }
            self.applyEngineAllowList()
        }
        RunLoop.main.add(t, forMode: .common)
        watchTimer = t
    }

    /// Point the chevron the right way for the current state (both paths).
    private func updateChevron() {
        let revealed = usesEngine ? engineRevealed : expanded
        mainItem.button?.image = symbol(revealed ? "chevron.right" : "chevron.left")
        mainItem.button?.image?.isTemplate = true
    }

    // MARK: - Background auto-refresh (event-driven, ALWAYS invisible)
    //
    // The background NEVER moves menu bar items — moving is what caused the "disco" and
    // the cursor jumping to the bar. Like Ice, we only react to apps launching/quitting
    // (that's what actually adds/removes an item) and update the cache invisibly: reuse
    // cached glyphs, drop vanished items, capture newly-appeared *on-screen* items in
    // place. A brand-new *obscured* item gets a stand-in tile (app icon) instead of a
    // move; its real glyph is filled in by the one-time startup pass.

    /// Stable signature: count of real items per owner. Excludes the constantly-renaming
    /// windows (iStat text, Clock) so their churn never triggers a refresh.
    private func barSignature() -> String {
        var counts: [String: Int] = [:]
        for r in CaptureEngine.scanAll() {
            if r.owner == "Tidier" || r.name.hasPrefix("Tidier") { continue }
            if r.name.hasPrefix("com.bjango.istatmenus.") { continue }
            if r.name == "Clock" || r.name == "BentoBox-0" { continue }
            counts[r.owner, default: 0] += 1
        }
        return counts.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: ",")
    }

    /// React to app launch/quit (debounced). No polling timer that moves anything.
    private func startAutoRefresh() {
        lastBarSignature = barSignature()
        let wsc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            wsc.addObserver(self, selector: #selector(appsChanged), name: name, object: nil)
        }
    }

    @objc private func appsChanged() {
        // Debounce bursts of launch/quit notifications into a single check.
        watchTimer?.invalidate()
        let t = Timer(timeInterval: 1.5, repeats: false) { [weak self] _ in
            self?.checkForBarChanges()
        }
        RunLoop.main.add(t, forMode: .common)
        watchTimer = t
    }

    private func checkForBarChanges() {
        guard !buildingCache, !arranging, !expanded, !tileOpen else { return }
        let sig = barSignature()
        guard sig != lastBarSignature else { return }
        lastBarSignature = sig
        invisibleRefresh()
    }

    /// Keep the detected list current on app launch/quit WITHOUT any reveal or move — purely
    /// incremental over the live window ids (session-stable): drop items whose window vanished
    /// (app quit), add newly-appeared items we can capture on-screen now. The notch-overflow
    /// items captured at startup are kept (their window ids persist), never rebuilt — macOS
    /// gives them no stable identity while hidden, so a rebuild-from-scratch would lose them.
    private func invisibleRefresh() {
        let raws = CaptureEngine.scanAll()
        let liveIds = Set(raws.map { Int($0.id) })
        var detected = ScannerModel.shared.detected
        detected.removeAll { !liveIds.contains($0.info.id) }                  // app quit → gone
        let known = Set(detected.map { $0.info.id })
        for r in raws where !known.contains(Int(r.id)) {                      // newly appeared
            if r.owner == "Tidier" || r.name.hasPrefix("Tidier") { continue }
            if r.name.hasPrefix("com.bjango.istatmenus.") { continue }
            if r.name == "Clock" || r.name == "BentoBox-0" { continue }
            guard ItemCapture.image(forWindow: Int(r.id)) != nil,            // only if visible now
                  let made = TidierBar.makeItem(from: r.info),
                  !detected.contains(where: { $0.key == made.key }) else { continue }
            detected.append(made)
        }
        ScannerModel.shared.detected = detected
        applyItemFilter()
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

        // macOS 27: the length-trick is dead — MenuBarAgent hides items via the engine, so no
        // separators are needed (an empty separator would just leave a gap in the bar).
        guard !usesEngine else { return }

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
        b.image = nil                    // marker only appears in Arrange mode (see applyLayout)
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
        } else if usesEngine {
            engineToggle()
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
        // Show the cache immediately (fast). The full capture — which briefly moves the
        // menu bar items around to reach overflow icons — runs once, lazily, and then
        // refreshes the open panel, so the first open isn't blocked and login has no
        // shuffle.
        ensureCollapsed()
        presentTile()
    }

    /// During a capture reveal, collapse Tidier's own toggle + separators to a sliver
    /// so the user's items shift right into that freed space — squeezing one or two
    /// more past the notch so they can be captured.
    private func shrinkOwnItems() {
        // Keep the toggle at full width — the user wants the chevron always visible; only
        // the (invisible) separators collapse to claw back a little room during a reveal.
        hiddenSep.length = 1
        alwaysSep?.length = 1
    }
    private func restoreOwnItems() {
        applyLayout()                   // restore separator lengths + chevron
    }

    private var buildingCache = false
    private var didFullBuild = false

    /// Build the item cache. Reveal + shrink so as many items as possible slide on-screen,
    /// then capture each; items still obscured under the notch are briefly staged on-screen
    /// via MoveEngine, captured, and moved back to their original (hidden) slot — so ALL
    /// items get a real glyph while the visible arrangement is preserved. Then collapse.
    func rebuildFullCache() {
        guard !buildingCache else { return }
        buildingCache = true
        expanded = true
        revealingAlways = true
        applyLayout()
        shrinkOwnItems()
        let threshold = mainItem.button?.window?.frame.minX ?? 1200
        DispatchQueue.global().async { [weak self] in
            usleep(650_000)
            let y = CaptureEngine.scanAll().first(where: { $0.x >= 0 })?.info.centerY ?? 12
            // Move-capture: obscured (notch-overflow) items are briefly staged on-screen,
            // captured, and moved back to their original hidden slot. Preserves the arrangement.
            let items = CaptureEngine.captureAll(stageX: threshold - 40, menuBarY: y, thresholdX: threshold)
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.buildingCache = false
                self.restoreOwnItems()
                self.expanded = false
                self.revealingAlways = false
                self.applyLayout()
                if !items.isEmpty {
                    ScannerModel.shared.detected = items      // full list (Settings shows all)
                    self.applyItemFilter()                    // panel shows only the chosen ones
                    self.lastBarSignature = self.barSignature()
                }
                // A move-captured item can land right of the separator (visible) instead of
                // back in the hidden zone. Sweep it back so nothing "escapes" into the bar.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                    self?.reHideEscapedItems()
                }
            }
        }
    }

    /// After a capture, re-hide any third-party item that ended up visible in the bar but
    /// the user did NOT pin to "Leiste" — it escaped during the move-capture. One targeted
    /// pass; moves only the genuinely-escaped items far left (collapsed state = reliable).
    private func reHideEscapedItems() {
        guard !buildingCache, !arranging, !expanded, !tileOpen else { return }
        guard let toggleX = mainItem.button?.window?.frame.minX,
              let barY = mainItem.button?.window?.frame.midY,
              let sepX = hiddenSep.button?.window?.frame.minX, sepX < 0 else { return }
        let pinned = Preferences.shared.barPinnedKeys
        // Escaped = a third-party "Item-0" that is on-screen and left of the toggle but the
        // user did not pin it. (Genuine visible system items are named / sit right of the toggle.)
        var escaped: [CaptureEngine.Raw] = []
        for r in CaptureEngine.scanAll() {
            guard r.name == "Item-0", r.owner != "Tidier", r.x >= 0, r.x < toggleX - 2,
                  ItemCapture.image(forWindow: Int(r.id)) != nil else { continue }
            if let item = TidierBar.makeItem(from: r.info), pinned.contains(item.key) { continue }
            escaped.append(r)
        }
        guard !escaped.isEmpty else { return }
        // Move each into the hidden cluster (left of the collapsed separator) so it disappears.
        DispatchQueue.global().async {
            var dropX = sepX - 200
            for r in escaped {
                MoveEngine.move(windowID: r.id, pid: r.pid, toX: dropX, menuBarY: barY)
                dropX -= 40
                usleep(280_000)
            }
        }
    }

    /// Rebuild the panel's groups from the full detected list minus the items the user hid
    /// OR pinned to the real bar (pinned = visible in the bar, so not in the panel). Refresh
    /// the panel if it's open. Cheap — no capture, no moving.
    func applyItemFilter() {
        let p = Preferences.shared
        let visible = ScannerModel.shared.detected.filter { !p.isItemHidden($0.key) && !p.isPinned($0.key) }
        cachedGroups = TidierBar.group(visible)
        if tileOpen { presentTile() }
    }

    /// Pin an item into the visible menu bar (right of the hidden separator) or send it back
    /// to the hidden side — one deliberate, user-triggered move via MoveEngine. Reveals to
    /// find the live item by its stable key, moves just that one, then collapses.
    func setItemPinned(_ key: String, pinned: Bool) {
        guard !buildingCache, !arranging else { return }
        closeTile()
        expanded = true
        revealingAlways = true
        applyLayout()
        shrinkOwnItems()
        let threshold = mainItem.button?.window?.frame.minX ?? 1200
        let sepX = hiddenSep.button?.window?.frame.minX ?? (threshold - 20)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) { [weak self] in
            guard let self = self else { return }
            // Find the live window whose resolved key matches (same approach as clicking).
            var target: CaptureEngine.Raw?
            let raws = CaptureEngine.scanAll()
            for r in raws where ItemCapture.image(forWindow: Int(r.id)) != nil {
                if TidierBar.makeItem(from: r.info)?.key == key { target = r; break }
            }
            guard let r = target else { self.collapseAfterMove(); return }
            let barY = raws.first(where: { $0.x >= 0 })?.info.centerY ?? (r.y + r.h / 2)
            // Pin → just left of Tidier's toggle (right of the separator = stays visible).
            // Unpin → left of the separator (hidden when collapsed).
            let toX = pinned ? (threshold - r.w - 2) : (sepX - r.w - 2)
            let id = r.id, pid = r.pid
            DispatchQueue.global().async {
                MoveEngine.move(windowID: id, pid: pid, toX: toX, menuBarY: barY)
                usleep(300_000)
                DispatchQueue.main.async { self.collapseAfterMove() }
            }
        }
    }

    private func collapseAfterMove() {
        restoreOwnItems()
        expanded = false
        revealingAlways = false
        applyLayout()
        // Re-read the bar so the Settings list + panel reflect the new placement.
        rebuildFullCache()
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
        revealingAlways = true
        applyLayout()
        shrinkOwnItems()   // reveal + shrink so as many items as possible are on-screen
        let threshold = mainItem.button?.window?.frame.minX ?? 1200
        armRevealCollapse()
        DispatchQueue.global().async { [weak self] in
            usleep(300_000)
            self?.clickHiddenItem(matching: item, threshold: threshold)
        }
    }

    /// Click the real menu bar item a tile stands for. macOS reports EVERY status item's
    /// CGWindow owner as "Control Center", so identity can only come from AXResolver — which
    /// needs the item on-screen. We revealed the bar in activateItem; now re-resolve the
    /// on-screen items, match the one with the SAME stable key, and click it in place. No
    /// moving, and no owner guessing (that would hit the first Item-0 = the wrong app).
    private func clickHiddenItem(matching item: BarItem, threshold: CGFloat) {
        // 1) On-screen after the reveal? Re-resolve and match by stable key, click in place.
        let onscreen = TidierBar.makeGroups(from: hiddenCandidates()).flatMap { $0.items }
        if let t = onscreen.first(where: { $0.key == item.key }) {
            activate(key: t.key, atX: t.info.centerX, y: t.info.centerY)
            return
        }
        // 2) Still obscured under the notch (didn't fit). Find its live window by its stable
        // window id, stage it onto a visible slot, activate it there. The reveal-collapse
        // afterwards re-hides it (reHideEscapedItems), so it never lingers in the bar.
        let raws = CaptureEngine.scanAll()
        guard let barY = raws.first(where: { $0.x >= 0 })?.info.centerY,
              let target = raws.first(where: { Int($0.id) == item.info.id }) else { return }
        MoveEngine.move(windowID: target.id, pid: target.pid, toX: threshold - 40, menuBarY: barY)
        usleep(340_000)
        if let staged = CaptureEngine.scanAll().first(where: { $0.id == target.id }) {
            activate(key: item.key, atX: staged.x + staged.w / 2, y: staged.y + staged.h / 2)
        }
    }

    /// Activate the real item at a screen point: accessibility press (keeps the item's menu
    /// open), with a synthetic click for the few bundles whose AXPress is a no-op, or as a
    /// fallback when no press action exists.
    private func activate(key: String, atX x: CGFloat, y: CGFloat) {
        if Self.prefersSyntheticClick(key: key) {
            postClick(atX: x, y: y)          // AXPress is a no-op for these — a real click works
            return
        }
        if !AXResolver.press(at: x, y: y) { postClick(atX: x, y: y) }
    }

    /// Some status items report AXPress "success" but do nothing (ChatGPT, Gemini) — those
    /// need a synthetic click. Match on the key so it works whether or not a bundle id
    /// resolved (ChatGPT's helper exposes none, so it keys by name).
    private static let syntheticClickHints = ["geminimacos", "chatgpt"]
    private static func prefersSyntheticClick(key: String) -> Bool {
        let low = key.lowercased()
        return syntheticClickHints.contains { low.contains($0) }
    }

    /// Post a left click at a menu-bar point. CGWindow bounds share CGEvent's top-left
    /// global coordinate space, so item centers map directly. We warp the real cursor onto
    /// the item first (some items hit-test the cursor) and LEAVE it there — warping it back
    /// immediately dismisses a menu/popover that just opened (Telegram et al. close instantly).
    private func postClick(atX x: CGFloat, y: CGFloat) {
        let p = CGPoint(x: x, y: y)
        let src = CGEventSource(stateID: .combinedSessionState)
        CGWarpMouseCursorPosition(p)
        usleep(30_000)
        CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: p, mouseButton: .left)?
            .post(tap: .cghidEventTap)
        usleep(60_000)
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
        if usesEngine { engineCollapse(); return }
        disarmRevealCollapse()
        restoreOwnItems()   // activation shrank the toggle; bring it back
        ensureCollapsed()
        // If activating an obscured item staged it on-screen, tuck it back into hiding.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.reHideEscapedItems()
        }
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
        didFullBuild = true
        rebuildFullCache()   // full move-capture pass, updates ScannerModel.detected + cache
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
        // The separators only need a visible marker while ARRANGING (the "hidden ↔ visible"
        // boundary the user ⌘-drags across). During a normal reveal — e.g. activating an item
        // — show no glyph, so no stray mark appears between the real menu bar icons.
        if let b = hiddenSep.button {
            b.image = arranging ? symbol("arrow.left.and.right") : nil
            b.image?.isTemplate = true
        }
        alwaysSep?.button?.image = nil
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
        mainItem.length = 1   // free the toggle's width so more items are reachable (marker stays visible)
        ArrangeHUD.shared.onDone = { [weak self] in self?.exitArrangeMode() }
        ArrangeHUD.shared.show(near: toggleScreenRect())
    }

    func exitArrangeMode() {
        guard arranging else { return }
        arranging = false
        ArrangeHUD.shared.hide()
        mainItem.length = normalLength
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
        // Open ONLY when the pointer is actually over Tidier's toggle button — not anywhere
        // along the menu bar (which would trigger on the clock, Control Center, …).
        guard let frame = mainItem.button?.window?.frame else { return }
        if frame.insetBy(dx: -3, dy: -3).contains(NSEvent.mouseLocation) {
            if usesEngine { if !engineRevealed { engineReveal() } } else { openTile() }
        }
    }

    // MARK: - Context menu

    private func showMenu() {
        if usesEngine { showEngineMenu(); return }
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

    /// macOS 27 engine path: a lean menu — reveal/hide, settings, about, quit. (Arrange mode and
    /// the panel-design picker are legacy-only; MenuBarAgent does the hiding directly now.)
    private func showEngineMenu() {
        let menu = NSMenu()
        let toggle = NSMenuItem(title: engineRevealed ? L("menu.hide") : L("menu.show"),
                                action: #selector(menuEngineToggle), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)
        menu.addItem(.separator())
        let settings = NSMenuItem(title: L("menu.settings"), action: #selector(menuSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let about = NSMenuItem(title: L("menu.about"), action: #selector(menuAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: L("menu.quit"), action: #selector(menuQuit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        mainItem.menu = menu
        mainItem.button?.performClick(nil)
        mainItem.menu = nil
    }

    @objc private func menuEngineToggle() { engineToggle() }

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
        if usesEngine {
            setupHover()
            if !engineRevealed { applyEngineAllowList() }   // hiding/showing an app takes effect now
            updateChevron()
            return
        }
        if Preferences.shared.enableAlwaysHidden { addAlwaysSeparator() }
        else { removeAlwaysSeparator() }
        setupHover()
        applyLayout()
        applyItemFilter()   // reflect show/hide selection (also re-presents an open panel)
    }
}
