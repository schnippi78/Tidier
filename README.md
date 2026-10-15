# Tidier

Ein freier, offener **Menüleisten-Manager für macOS** — versteckt, ordnet und
zeigt Menüleisten-Symbole. Gedacht als bessere Alternative zu
[Ice](https://icemenubar.app/) (kostenlos, aber nur teilweise übersetzt) und
[Bartender](https://www.macbartender.com/) (mächtig, aber kostenpflichtig und
Closed-Source).

**Alleinstellungsmerkmal:** echte Voll-Lokalisierung in **26 Sprachen**
(inkl. CJK und RTL) — hand­übersetzt, nicht maschinell. Umschaltbar direkt in
der App, ohne Systemsprache zu ändern.

---

## Status (MVP, v0.1.0)

> ⚠️ **macOS 26/27-Hinweis:** Ab macOS 27.0.1 ist das **Ausblenden** fremder
> Menüleisten-Items über **öffentliche** APIs **nicht mehr möglich** (alle drei bisher
> genutzten Mechanismen geschlossen). Verstecken geht weiterhin nur noch über **private
> WindowServer-APIs** (SkyLight/CGS) in einer unsandboxed + notarisierten App — so machen
> es Bartender 7, BetterTouchTool und Bar Keeper's Friend. Details, Belege und die noch
> öffentlich funktionierenden Teile (AX-Enumeration, Umsortieren, Panel/Launcher) in
> [`docs/MACOS27.md`](docs/MACOS27.md). Das Hide-Feature ist **pausiert** (Richtung offen).
> Die Zustandstabelle unten beschreibt den Stand auf macOS ≤ 15.

| Bereich | Zustand |
|---|---|
| Nativer Build (Swift 6 / AppKit + SwiftUI) | ✅ kompiliert & läuft (macOS 14+) |
| Verstecken/Zeigen von Menüleisten-Items | ✅ macOS ≤ 15 — 1 Klick versteckt alle Icons links des Trenners · ☠️ **macOS 26/27: nicht mehr möglich** (s. `docs/MACOS27.md`) |
| Aktive Positionierung (Umschalter rechts vorbelegt) | ✅ Seeding der „Preferred Position" → kein manuelles ⌘-Drag nötig |
| **Tidier Bar** (Panel für versteckte Items, Control-Center-Look) | ✅ fertig: elegantes NSPanel, gruppiert Apple/System · Drittanbieter, echte App-Icons + SF-Symbole, echte Namen (AX), schließt bei Klick außerhalb |
| Icons nur in der Kachel (Leiste bleibt sauber) | ✅ Ruhezustand eingeklappt; Klick öffnet/schließt nur die Kachel |
| — Kacheln anklickbar (Item aktivieren) + selbst anordnen | ⏳ geplant (Klick-Weiterleitung + Repositioning) |
| Berechtigung | **Bedienungshilfen** (+ Screen-Recording für Glyph-Capture/Enumeration); ✅ TCC überlebt jetzt Rebuilds dank stabiler Selbst-Signatur „Tidier Self-Signed" (`build.sh`, signiert per SHA-1-Hash) |
| „Immer ausgeblendet"-Sektion | ✅ zuschaltbar |
| Auto-Rehide (mit Intervall) | ✅ |
| Reveal-on-Hover | ✅ (Basis) |
| Kontextmenü (Rechtsklick auf Icon) | ✅ Zeigen/Verstecken, Einstellungen, Beenden |
| SwiftUI-Einstellungen (4 Tabs) | ✅ getestet DE / JA / AR |
| **26 Sprachen, live umschaltbar** | ✅ getestet (LTR, CJK, RTL) |
| Launch-at-Login (SMAppService) | ✅ verdrahtet |
| Menüleisten-Styling (Tint/Rand/Pills) | ⏳ geplant |
| Trigger (WLAN/Akku/VPN/Script) — Bartenders Killer-Feature | ⏳ geplant |
| Suche in Menüleisten-Items | ⏳ geplant |
| Globale Hotkeys | ⏳ geplant |
| App-Icon / Notarisierung / Sparkle-Updates | ⏳ geplant |

## So funktioniert das Verstecken

Wie Hidden Bar / Dozer (und im Kern auch Bartender): Die Menüleiste ordnet
Status-Items von rechts nach links an. Tidier legt einen **Trenner** als
Status-Item an; wird dessen Breite riesig gesetzt, rutscht **alles links davon**
über den linken Bildschirmrand und verschwindet. Kein Accessibility- oder
Screen-Recording-Recht nötig.

**Einrichtung:** Halte **⌘** und ziehe deine Symbole links neben Tidiers
Trenner. Mit aktivierter „immer ausgeblendet"-Sektion gibt es einen zweiten,
gedimmten Trenner ganz links.

### Aktive Positionierung (verifiziert 2026-09-11)

Beim ersten Start setzt Tidier die „Preferred Position" seiner Items vor
(`Tidier.Main` ganz rechts, `Tidier.HiddenSeparator` direkt links daneben) — so
liegen **alle** anderen Icons links des Trenners und verschwinden beim ersten
Klick, **ohne manuelles ⌘-Drag**. Live getestet: ein Klick blendet die komplette
Icon-Reihe aus, ein weiterer holt sie zurück.

Hinweis: Auf einem **randvollen Notch-Rand** muss ggf. einmalig **ein** Slot frei
sein, damit Tidier überhaupt einen Platz bekommt (danach räumt es selbst auf).

**Noch offen (Komfort):** „Tidier Bar" — versteckte Items zusätzlich in einem
eigenen Panel anzeigen, statt sie nur aus-/einzublenden.

## Bauen & Starten

Kein volles Xcode nötig — nur die Command Line Tools (`swiftc`).

```bash
./build.sh
open build/Tidier.app
```

Übersetzungen neu erzeugen (Quelle: `scripts/gen_strings.py`):

```bash
python3 scripts/gen_strings.py
```

Tidier läuft als Menüleisten-Agent (kein Dock-Icon). Einstellungen: Rechtsklick
auf das Tidier-Symbol → „Einstellungen …", oder `open build/Tidier.app` erneut.

## Projektstruktur

```
Sources/
  main.swift               AppKit-Einstieg (Agent)
  AppDelegate.swift        Lifecycle
  StatusBarController.swift Verstecken/Zeigen, Auto-Rehide, Hover, Kontextmenü
  Preferences.swift        UserDefaults-Wrapper (ObservableObject)
  LanguageManager.swift    Sprachliste (26) + Live-Override + L("…")-Helfer
  LaunchAtLogin.swift      SMAppService
  SettingsView.swift       SwiftUI-Einstellungen (Allgemein/Menüleiste/Sprache/Über)
Resources/<code>.lproj/Localizable.strings   handübersetzte Strings
scripts/gen_strings.py     Generator (Single Source of Truth der Übersetzungen)
Info.plist                 LSUIElement, CFBundleLocalizations, Bundle-ID de.csho.Tidier
build.sh                   swiftc-Build + Bundle-Assemblierung + Ad-hoc-Signatur
```

## Unterstützte Sprachen (26)

en, de, fr, es, it, pt-BR, nl, sv, da, nb, fi, pl, cs, ru, uk, tr, el, ro, hu,
id, ja, ko, zh-Hans, zh-Hant, ar, he

Eine Sprache hinzufügen: Eintrag in `scripts/gen_strings.py` (`T[...]`) und in
`Languages.all` (LanguageManager.swift) ergänzen, `CFBundleLocalizations` in
`Info.plist` erweitern, `python3 scripts/gen_strings.py` und `./build.sh`.

## Lizenz

Noch offen. Vorschlag: MIT (permissiv) oder GPL-3.0 (wie Ice). — Christians Entscheidung.
