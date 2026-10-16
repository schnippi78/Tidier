import Foundation
import os

/// macOS 27+ hide engine. On macOS 27 Apple renders the whole menu bar in `MenuBarAgent`
/// and ships a private framework — `MenuBarClientCore.framework` — that lets a caller put the
/// bar into an "assessment"/allow-list mode: you name the system items and app bundle ids that
/// stay visible, and MenuBarAgent hides everything else itself. No screen recording, no
/// synthetic drag, no length trick — those are all dead on macOS 27. Requires: unsandboxed app,
/// Accessibility, and (for its own icon to show) living in /Applications.
///
/// Two ObjC classes are resolved at runtime via dlopen, so a missing/renamed framework simply
/// degrades to `isAvailable == false` instead of crashing. Technique learned from the MIT-licensed
/// MenuBarHider (happy666End/MenuBarHider); this is an independent reimplementation.
@objc private protocol MBAssertion {
    @objc(activateWithConfiguration:completionHandler:)
    func activate(with configuration: AnyObject, completionHandler: @escaping (NSError?) -> Void)
    func invalidate()
}

final class MenuBarHideEngine {
    static let shared = MenuBarHideEngine()

    private static let frameworkPath =
        "/System/Library/PrivateFrameworks/MenuBarClientCore.framework/MenuBarClientCore"
    private static let configInit =
        NSSelectorFromString("initWithAllowedSystemItems:allowedBundleIdentifiers:")

    /// System menu-bar item identifiers (MBSystemItemIdentifier) on macOS 27.0:
    /// 0 battery · 1 bluetooth · 2 clock · 3 displays · 4 keyboard · 5 volume · 6 wifi
    /// · 7 screenMirroring · 8 primaryBentoBox. A generous 0..<64 keeps items added in later
    /// builds visible too.
    static let allowedSystemItems: [NSNumber] = (0..<64).map { NSNumber(value: $0) }

    /// A hideable system menu-bar item (MBSystemItemIdentifier) with a label + SF symbol for
    /// the Settings list. Items addressed by bundle id (Siri/Spotlight/…) aren't here — they're
    /// in `alwaysAllowedBundleIDs`.
    struct SystemItem { let id: Int; let labelKey: String; let symbol: String }
    static let knownSystemItems: [SystemItem] = [
        .init(id: 6, labelKey: "sysitem.wifi",          symbol: "wifi"),
        .init(id: 1, labelKey: "sysitem.bluetooth",     symbol: "dot.radiowaves.left.and.right"),
        .init(id: 0, labelKey: "sysitem.battery",       symbol: "battery.100"),
        .init(id: 5, labelKey: "sysitem.volume",        symbol: "speaker.wave.2.fill"),
        .init(id: 2, labelKey: "sysitem.clock",         symbol: "clock"),
        .init(id: 3, labelKey: "sysitem.displays",      symbol: "display"),
        .init(id: 4, labelKey: "sysitem.keyboard",      symbol: "keyboard"),
        .init(id: 7, labelKey: "sysitem.screenMirror",  symbol: "rectangle.on.rectangle"),
        .init(id: 8, labelKey: "sysitem.controlCenter", symbol: "switch.2"),
    ]

    /// All system item ids (0..<64) except the ones being hidden — for the config's allow list.
    static func allowedSystemItems(hiding hidden: Set<Int>) -> [NSNumber] {
        (0..<64).filter { !hidden.contains($0) }.map { NSNumber(value: $0) }
    }

    /// Apple agents that must NEVER be hidden (they host the system items / core UI). Always
    /// appended to the allow-list by `restrict`.
    static let mandatoryBundleIDs: [String] = [
        "com.apple.controlcenter", "com.apple.MenuBarAgent", "com.apple.systemuiserver",
        "com.apple.TextInputMenuAgent",
        "com.apple.wifi.WiFiAgent", "com.apple.ScreenTimeAgent", "com.apple.AirPlayUIAgent",
        "com.apple.UserNotificationCenter", "com.apple.notificationcenterui", "com.apple.loginwindow",
    ]

    /// The Spotlight/Siri search item (one process `com.apple.campo` on macOS 27; older aliases
    /// kept for safety). Allowed by default, but hideable via the Spotlight toggle.
    static let spotlightBundleIDs: [String] = ["com.apple.campo", "com.apple.Spotlight", "com.apple.Siri"]

    /// Apple agents never offered in the third-party app list (mandatory + Spotlight).
    static let alwaysAllowedBundleIDs: [String] = mandatoryBundleIDs + spotlightBundleIDs

    private let log = OSLog(subsystem: "de.csho.Tidier", category: "HideEngine")
    private let assertionClass: NSObject.Type?
    private let configClass: NSObject.Type?
    private var active: MBAssertion?

    private init() {
        if dlopen(Self.frameworkPath, RTLD_NOW) != nil,
           let a = NSClassFromString("MBAssessmentModeAssertion") as? NSObject.Type,
           let c = NSClassFromString("MBAssessmentModeConfiguration") as? NSObject.Type,
           a.instancesRespond(to: #selector(MBAssertion.activate(with:completionHandler:))),
           a.instancesRespond(to: #selector(MBAssertion.invalidate)),
           c.instancesRespond(to: Self.configInit) {
            assertionClass = a; configClass = c
        } else {
            assertionClass = nil; configClass = nil
        }
    }

    /// True when the private framework and its classes are present (macOS 27+).
    var isAvailable: Bool { assertionClass != nil && configClass != nil }

    /// Keep exactly these app bundle ids and these system items visible (plus the always-allowed
    /// Apple agents); MenuBarAgent hides everything else. `allowedSystemItems` defaults to all of
    /// them; pass a reduced list to also hide specific system items (battery/bluetooth/clock/…).
    /// Replaces any prior restriction. `completion` runs on the main thread.
    func restrict(keepVisibleBundleIDs: [String],
                  allowedSystemItems: [NSNumber] = MenuBarHideEngine.allowedSystemItems,
                  completion: @escaping (Error?) -> Void) {
        guard let assertionClass, let configClass else {
            completion(NSError(domain: "Tidier.HideEngine", code: 1,
                               userInfo: [NSLocalizedDescriptionKey: "MenuBarClientCore nicht verfügbar"]))
            return
        }
        let allowed = Array(Set(keepVisibleBundleIDs + Self.mandatoryBundleIDs))
        // [[MBAssessmentModeConfiguration alloc] initWithAllowedSystemItems:allowedBundleIdentifiers:]
        guard let allocated = (configClass as AnyObject).perform(NSSelectorFromString("alloc"))?.takeUnretainedValue(),
              let config = allocated.perform(Self.configInit,
                                             with: allowedSystemItems as NSArray,
                                             with: allowed as NSArray)?.takeRetainedValue() else {
            completion(NSError(domain: "Tidier.HideEngine", code: 2,
                               userInfo: [NSLocalizedDescriptionKey: "Konfiguration fehlgeschlagen"]))
            return
        }
        let newAssertion = unsafeBitCast(assertionClass.init(), to: MBAssertion.self)
        released = false
        newAssertion.activate(with: config) { [weak self] error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    newAssertion.invalidate()                 // keep prior restriction on failure
                    completion(error)
                } else if self.released {
                    // A release() landed while this assertion was activating — honour it: don't
                    // install a restriction the caller already asked to lift (race fix).
                    newAssertion.invalidate()
                    completion(nil)
                } else {
                    self.active?.invalidate()                 // swap only once the new one holds → no flash
                    self.active = newAssertion
                    completion(nil)
                }
            }
        }
    }

    /// True once `release()` has been called and no later `restrict` has superseded it.
    private var released = false

    /// Lift the restriction — every hidden item comes back.
    func release() {
        released = true
        active?.invalidate()
        active = nil
    }
}
