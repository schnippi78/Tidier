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

    /// Apple agents addressed by bundle id (not by system-item number) that must never be hidden.
    static let alwaysAllowedBundleIDs: [String] = [
        "com.apple.controlcenter", "com.apple.MenuBarAgent", "com.apple.systemuiserver",
        "com.apple.TextInputMenuAgent", "com.apple.Siri", "com.apple.Spotlight", "com.apple.campo",
        "com.apple.wifi.WiFiAgent", "com.apple.ScreenTimeAgent", "com.apple.AirPlayUIAgent",
        "com.apple.UserNotificationCenter", "com.apple.notificationcenterui", "com.apple.loginwindow",
    ]

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

    /// Keep exactly these app bundle ids visible (plus all system items and the always-allowed
    /// Apple agents); MenuBarAgent hides every other third-party item. Replaces any prior
    /// restriction. `completion` runs on the main thread.
    func restrict(keepVisibleBundleIDs: [String], completion: @escaping (Error?) -> Void) {
        guard let assertionClass, let configClass else {
            completion(NSError(domain: "Tidier.HideEngine", code: 1,
                               userInfo: [NSLocalizedDescriptionKey: "MenuBarClientCore nicht verfügbar"]))
            return
        }
        let allowed = Array(Set(keepVisibleBundleIDs + Self.alwaysAllowedBundleIDs))
        // [[MBAssessmentModeConfiguration alloc] initWithAllowedSystemItems:allowedBundleIdentifiers:]
        guard let allocated = (configClass as AnyObject).perform(NSSelectorFromString("alloc"))?.takeUnretainedValue(),
              let config = allocated.perform(Self.configInit,
                                             with: Self.allowedSystemItems as NSArray,
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
