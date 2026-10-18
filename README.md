# Tidier

Ein freier, quelloffener **Menüleisten-Manager für macOS** — blendet Menüleisten-Symbole
aus, holt sie per Klick zurück und hält die Leiste aufgeräumt. Freie Alternative zu
[Bartender](https://www.macbartender.com/) (mächtig, aber kostenpflichtig und Closed-Source)
und [Ice](https://icemenubar.app/) (kostenlos, aber nur teilweise übersetzt).

**Alleinstellungsmerkmal:** echte Voll-Lokalisierung in **26 Sprachen** (inkl. CJK und RTL) —
handübersetzt, nicht maschinell, direkt in der App umschaltbar (ohne die Systemsprache zu ändern).

Produktseite: **https://tidier.csho.de**

---

## Download

- **Neueste Version:** [**Releases**](https://github.com/schnippi78/Tidier/releases/latest) →
  `Tidier-x.y.z.dmg` (Universal: Apple Silicon + Intel, **macOS 14–27**)
- ⚠️ Tidier ist aktuell **self-signed und nicht notarisiert** → macOS blockiert den ersten Start.
  So erlaubst du es einmalig: siehe **[INSTALL.md](INSTALL.md)**.

## Status

**v1.1.1 (Beta)** — läuft und wird weiter ausgebaut.

macOS 27 hat die früher genutzten **öffentlichen** Wege zum Ausblenden geschlossen (der
Längen-Trick und das ⌘-Drag-Umsortieren — darum funktionieren Ice/Dozer dort nicht mehr).
Tidier nutzt stattdessen eine **neu gebaute Hide-Engine** über private WindowServer-APIs
(wie Bartender 7, BetterTouchTool) und blendet auf **macOS 14–27** weiter aus — Drittanbieter-
Apps **und** System-Items. Untersuchung, Belege und Technik: [`docs/MACOS27.md`](docs/MACOS27.md).

**Fertig**
- Ausblenden/Einblenden der Menüleisten-Symbole (macOS 14–27, live verifiziert)
- Hide-Engine für macOS 27, auch **System-Items** (WLAN, Bluetooth, Batterie, Uhr, Spotlight …)
- Auswahl **pro App** und **pro System-Symbol** (Einstellungen → „Menüleiste")
- **26 Sprachen**, live umschaltbar (LTR, CJK, RTL)
- Auto-Rehide (Intervall), Reveal-on-Hover, „immer ausgeblendet"-Sektion, Kontextmenü
- Launch-at-Login, Einstellungen (4 Tabs), App-Icon, Universal-Build + DMG

**Geplant**
- Items in der Menüleiste selbst umsortieren
- Menüleisten-Styling (Tint / Rand / Pills)
- Trigger (WLAN / Akku / VPN / Script), Suche in Items, globale Hotkeys
- Notarisierung & automatische Updates

## So funktioniert's

1. Installieren und einmalig die **Bedienungshilfen** erlauben.
2. In den **Einstellungen → Menüleiste** festlegen, welche Apps und System-Symbole
   ausgeblendet werden sollen.
3. Ein Klick auf das **Tidier-Symbol** (Chevron) versteckt die ausgewählten Symbole —
   noch ein Klick holt sie zurück; optional automatisch nach Intervall.

## Berechtigungen

- **Bedienungshilfen** (nötig) — fürs Ausblenden über die WindowServer-API.
- **Bildschirmaufnahme** (optional) — nur, um echte Icon-Glyphen zu erfassen.
- Keine Cloud, kein Tracking — alles bleibt lokal.

> **Hinweis (self-signed):** Ein Rebuild mit selbst­signiertem Zertifikat kann die
> TCC-Freigaben zurücksetzen. Bei Problemen: `tccutil reset Accessibility de.csho.Tidier`
> (und ggf. `ScreenCapture`), dann einmal neu erlauben. Dauerhaft stabil erst mit
> Developer-ID + Notarisierung.

## Aus dem Quellcode bauen

Kein volles Xcode nötig — nur die Command Line Tools (`swiftc`).

```bash
./build.sh                # baut build/Tidier.app (aktuelle Architektur), self-signed
open build/Tidier.app
```

Release-DMG (Universal arm64 + x86_64; notarisiert, falls Developer-ID + Profil vorhanden):

```bash
scripts/release.sh        # → build/Tidier-<version>.dmg
```

Übersetzungen neu erzeugen (Single Source of Truth: `scripts/gen_strings.py`):

```bash
python3 scripts/gen_strings.py
```

Tidier läuft als Menüleisten-Agent (kein Dock-Icon). Einstellungen: Rechtsklick auf das
Tidier-Symbol → „Einstellungen …".

## Projektstruktur

```
Sources/
  main.swift / AppDelegate.swift   App-Einstieg (LSUIElement-Agent) + Lifecycle
  StatusBarController.swift        Toggle, Auto-Rehide, Reveal-on-Hover, Kontextmenü
  MenuBarHideEngine.swift          Hide-Engine (macOS 27, private WindowServer-API)
  MenuBarScanner.swift             Menüleisten-Items abtasten (Geometrie)
  MenuBarApps.swift / AXResolver   App-/System-Item-Identität (Accessibility)
  CaptureEngine.swift              Icon-Glyphen erfassen (optional, Bildschirmaufnahme)
  PermissionManager.swift          Bedienungshilfen / Bildschirmaufnahme preflight
  SettingsView.swift               SwiftUI-Einstellungen (Allgemein / Menüleiste / Sprache / Über)
  LanguageManager.swift            26 Sprachen + Live-Umschaltung + L("…")-Helfer
  Preferences.swift                UserDefaults-Wrapper (ObservableObject)
  LaunchAtLogin.swift              SMAppService
Resources/<code>.lproj/Localizable.strings   handübersetzte Strings
Resources/AppIcon.icns             App-Icon
scripts/gen_strings.py             Übersetzungs-Generator
scripts/release.sh                 Universal-Build + DMG (+ optionale Notarisierung)
Info.plist                         LSUIElement, CFBundleLocalizations, Bundle-ID de.csho.Tidier
docs/MACOS27.md                    Warum/Wie des Ausblendens unter macOS 27
```

## Unterstützte Sprachen (26)

en, de, fr, es, it, pt-BR, nl, sv, da, nb, fi, pl, cs, ru, uk, tr, el, ro, hu,
id, ja, ko, zh-Hans, zh-Hant, ar, he

Eine Sprache hinzufügen: Eintrag in `scripts/gen_strings.py` und `LanguageManager.swift`
ergänzen, `CFBundleLocalizations` in `Info.plist` erweitern, dann
`python3 scripts/gen_strings.py` und `./build.sh`.

## Lizenz

**GPL-3.0** — siehe [LICENSE](LICENSE). Tidier adaptiert Technik aus
[Ice](https://github.com/jordanbaird/Ice) (Umsortieren/Positionierung) und MenuBarHider
(Hide-Engine für macOS 27) — Attribution in [NOTICE](NOTICE).
