# Menüleisten-Ausblenden unter macOS 27 (Tahoe-Nachfolger)

**Stand: 2026-10-14, macOS 27.0.1** — Untersuchung warum Tidier (und Ice/Bartender)
die Menüleisten-Icons nicht mehr ausblenden können, und was stattdessen noch geht.

## Kurzfassung

Auf macOS 27 ist das **Ausblenden fremder Menüleisten-Items über ÖFFENTLICHE APIs
nicht mehr möglich** (empirisch verifiziert, s. u.; unabhängig bestätigt von
`menubar-hide`, das auf macOS 27 „Panel mode and Icon Arrangement" deaktiviert).

**Verstecken ist aber NICHT generell tot:** Die kommerzielle Konkurrenz
(**Bartender 7 GoldenGate**, **BetterTouchTool**, **Bar Keeper's Friend**) versteckt
weiter — über **private WindowServer-APIs** (SkyLight/CGS). Zitat Bar Keeper's Friend:
*„Moving other apps' menu bar items needs private WindowServer APIs and an app that is
not sandboxed."* Genau deshalb „Bartender no longer touches your mouse to move items" —
der synthetische ⌘-Drag ist durch einen direkten privaten API-Aufruf ersetzt.

**Preis des privaten Wegs:** App muss **unsandboxed** laufen, **Developer-ID-signiert +
notarisiert** sein (99 $/Jahr Apple-Account), und die Funktionen sind undokumentiert →
**brechen zwischen Point-Releases** (26.1 → 26.5 hat sich schon verändert). Für ein
verkaufbares Produkt machbar (Bartender tut es), aber dauerhafter Wartungsaufwand.

**★ LÖSUNG GEFUNDEN & VERIFIZIERT (2026-10-15):** Der private-API-Weg ist konkret und
funktioniert auf 27.0.1 — siehe Abschnitt „Die Lösung: MenuBarClientCore" unten.
Umgesetzt in `Sources/MenuBarHideEngine.swift`, Test-Arm `--hidetest`. Technik gelernt
vom MIT-lizenzierten **MenuBarHider** (happy666End/MenuBarHider); Thaw/Ice nutzen dagegen
nur CGS zum *Lesen* (kein echtes Hide auf 27).

## Was kaputt ist

### 1. Längen-Trick (NSStatusItem.length) — tot
Früher: ein sehr breites, leeres Separator-Item belegt Platz und schiebt die Nachbarn
links davon über den Bildschirmrand (= versteckt). Auf macOS 27 belegt ein
**contentless NSStatusItem seine `.length` im Layout nicht mehr** — das Menubar-Fenster
blieb im Test bei ~5016px geklemmt, egal wie groß die Länge gesetzt war. Außerdem landen
Tidiers eigene Items unabhängig vom `Preferred Position`-Wert immer **ganz links**;
`NSStatusItem Preferred Position` steuert die app-übergreifende Reihenfolge nicht mehr.

### 2. Per-Item-Fensterrouting (MoveEngine ⌘-Drag an Fensternummer) — tot
Früher: jedes Statusitem war ein eigenes CGWindow (Layer 25) mit eigener Fensternummer;
die MoveEngine adressierte synthetische ⌘-Drag-Events an diese Fensternummer (CGEvent-Feld
rawValue 51) und konnte so auch off-screen-Items bewegen.

Auf macOS 27 **gibt es diese Per-Item-Fenster nicht mehr**. `CGWindowListCopyWindowInfo`
liefert im Menüleisten-Bereich nur noch **ein** komponiertes Fenster:

```
layers= … 24:1
  bar win layer=24 owner=[Window Server] name=[Menubar] x=0 w=1512
```

Kein Layer 25, keine Per-Item-Fensternummern → das Fensterrouting hat kein Ziel mehr.

### 3. Items per Drag vom Bildschirm schieben — geht nicht
Statusitems sind **rechtsbündig gepackt mit hartem linkem Rand**. Ein Item lässt sich per
⌘-Drag nur *mit anderen Items vertauschen*, aber nicht aus dem sichtbaren Streifen
schieben: Beim Ablegen weit links (x=770, Richtung Notch) snappt der Block sofort wieder
rechtsbündig, das Item bleibt an der leftmost-Position (x≈952, Δ=0). Rechts ist durch die
system-gepinnten Control-Center-/Uhr-Items blockiert. Es gibt also keinen Off-Screen-Platz.

## Was noch funktioniert (für spätere Features)

### Enumeration + Identität über die Accessibility-API
CGWindowList ist für Items nutzlos; die AX-API liefert dagegen App-Name, Titel, x/Breite
jedes Items zuverlässig. Entlang der Menüleisten-Zeile abtasten:

```swift
let sysWide = AXUIElementCreateSystemWide()
var el: AXUIElement?
if AXUIElementCopyElementAtPosition(sysWide, Float(x), Float(12), &el) == .success, let e = el {
    var pid: pid_t = 0; AXUIElementGetPid(e, &pid)
    var posV: CFTypeRef?; AXUIElementCopyAttributeValue(e, "AXPosition" as CFString, &posV)
    var sizeV: CFTypeRef?; AXUIElementCopyAttributeValue(e, "AXSize" as CFString, &sizeV)
    // AXValueGetValue(..., .cgPoint/.cgSize) → Rahmen
    let app = NSRunningApplication(processIdentifier: pid)?.localizedName
}
```
Von x=1512 nach links laufen, bei jedem Treffer auf `pt.x - 4` springen. Ergebnis im Test:
WeatherMenu, Telegram, Nextcloud, WireGuard, Claude, Siri/Spotlight + mehrere
`MenuBarAgent`-Items (WLAN/BT/Batterie/Control Center/Uhr).

### Umsortieren per synthetischem On-Screen-⌘-Drag (verifiziert)
Nur bei **Drittanbieter-Items** (System-Items `MenuBarAgent`/`Siri`/Control Center sind
gepinnt). Kein Fensterrouting — echte Cursor-Koordinaten: Cursor auf das Item warpen,
settle, dann ⌘-gedrückter leftMouseDown → mehrere leftMouseDragged → leftMouseUp, alles
auf `.cgSessionEventTap`, danach Cursor zurückwarpen. Im Test bewegte sich WeatherMenu real
(x 952 → 992, an Telegram vorbei).

```swift
CGWarpMouseCursorPosition(start); usleep(60_000)
// mouseMoved → settle
let down = CGEvent(mouseEventSource: src, mouseType: .leftMouseDown,
                   mouseCursorPosition: start, mouseButton: .left)
down?.flags = .maskCommand; down?.post(tap: .cgSessionEventTap)
usleep(260_000)                      // Item „abheben" lassen
// 14× leftMouseDragged mit .maskCommand entlang der Strecke
let up = CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, …)
up?.flags = .maskCommand; up?.post(tap: .cgSessionEventTap)
```

### Aktivierung per AXPress
Tidiers Panel kann Items weiterhin per `AXUIElementPerformAction` (AXPress/AXShowMenu)
auslösen; `.cannotComplete` (-25204) = Menü ging auf (Erfolg). Manche Bundles (chatgpt,
geminimacos) brauchen einen synthetischen Klick.

## Voraussetzungen (wichtig, hat viel Zeit gekostet)

- **Screen Recording** nötig, sonst liefert `CGWindowListCopyWindowInfo` 0 Fenster.
- **Accessibility** nötig für die AX-Enumeration und synthetische Events.
- Beide Freigaben hingen früher an der **ad-hoc-Signatur**, die sich bei *jedem* Build
  änderte → Freigaben bei jedem Rebuild weg. Fix: stabile selbstsignierte Identität
  „Tidier Self-Signed" (siehe `build.sh`), signiert per SHA-1-Hash (Name wäre „ambiguous").
  Das Designated Requirement ist jetzt `certificate leaf = H"…"` → TCC-Freigaben
  überleben Rebuilds dauerhaft.

## Die Lösung: MenuBarClientCore „Assessment Mode" (verifiziert 27.0.1)

macOS 27 bringt das private Framework
`/System/Library/PrivateFrameworks/MenuBarClientCore.framework`. Es stellt einen
Allow-List-/„Assessment"-Modus bereit (ursprünglich für Prüfungs-/Kiosk-Apps): man nennt
die System-Items + App-Bundle-IDs, die **sichtbar bleiben** dürfen — **`MenuBarAgent`
blendet alles andere selbst aus.** Kein Screen Recording, kein Drag, kein Längen-Trick.

Zwei ObjC-Klassen, zur Laufzeit per `dlopen` aufgelöst (fehlt das Framework → sauber
deaktiviert statt Absturz):
- `MBAssessmentModeConfiguration` — `initWithAllowedSystemItems:allowedBundleIdentifiers:`
  (allowedSystemItems = `NSArray<NSNumber>`; `MBSystemItemIdentifier` auf 27.0: 0 battery,
  1 bluetooth, 2 clock, 3 displays, 4 keyboard, 5 volume, 6 wifi, 7 screenMirroring,
  8 primaryBentoBox → großzügig `0..<64` nehmen. allowedBundleIdentifiers = `NSArray<String>`).
- `MBAssessmentModeAssertion` — `activateWithConfiguration:completionHandler:` (completion
  liefert `NSError?`), `invalidate` zum Aufheben.

Immer sichtbar lassen (per Bundle-ID adressierte Apple-Agents): `com.apple.controlcenter`,
`com.apple.MenuBarAgent`, `com.apple.systemuiserver`, `com.apple.TextInputMenuAgent`,
`com.apple.Siri`, `com.apple.Spotlight`, `com.apple.wifi.WiFiAgent`,
`com.apple.ScreenTimeAgent`, `com.apple.AirPlayUIAgent`, `com.apple.UserNotificationCenter`,
`com.apple.notificationcenterui`, `com.apple.loginwindow`.

**Voraussetzungen (verifiziert):** unsandboxed, Accessibility; KEIN spezielles Entitlement
(kein `automatic-assessment-configuration`), kein Hardened Runtime nötig — selbst ad-hoc-
signiert aktivierbar. App sollte aus `/Applications` laufen (sonst versteckt macOS ihr
eigenes Icon). **Test:** `open /Applications/Tidier.app --args --hidetest` → 6 s lang alle
Drittanbieter weg, dann zurück (Screenshots in der Session-History, 2026-10-15).

**Bekannte Nebenwirkung (aus MenuBarHider):** Während die Restriction aktiv ist, öffnet
Notification Center nicht (Uhr-Klick) → beim Hover auf die Uhr kurz `release()`.

**Caveat:** privates Framework, undokumentiert → Klassen-/Selektor-Namen können sich
zwischen Builds ändern (`isAvailable` fängt das ab); bei jedem macOS-Update re-testen.

### Integration in Tidier (Commit af381c2) — zwei harte Lehren

1. **Allow-Liste klein & präzise halten.** `Set(alleLaufendenApps) − hidden` (wie MenuBarHider
   es notiert) funktioniert NICHT: eine fast-alles-erlaubende Liste lässt MenuBarAgent die
   Restriction stillschweigend NO-OPen (48 von ~50 erlaubt → nichts versteckt). Richtig:
   `allow = scanThirdParty() − hidden + Tidier-eigene-Bundle-ID`. Tidiers Chevron MUSS in der
   Liste stehen, sonst versteckt MenuBarAgent es mit.
2. **Menüleisten-Apps über `AXExtrasMenuBar` enumerieren, nicht per Positions-Hit-Test.** Je
   laufende App: `AXUIElementCreateApplication(pid)` → Attribut `"AXExtrasMenuBar"` → dessen
   `kAXChildrenAttribute`; nicht leer ⇒ App hat ein Item. Zuverlässig und unabhängig davon, ob
   das Item gerade on-screen ist (Positions-Scan fand nur 3 von 6 Apps).
3. **Race:** `release()` während die `activate`-Completion noch läuft → `released`-Flag, sonst
   installiert die Completion die gerade aufgehobene Restriction wieder.

## Fazit / Richtung

Weg gewählt & belegt: **MenuBarClientCore** (oben). Die zwei früheren Optionen zur Einordnung:

1. **Privater-WindowServer-API-Weg** (wie Bartender 7 / BKF / BetterTouchTool) — der
   EINZIGE Weg, der auf macOS 27 fremde Items wirklich versteckt. Voraussetzungen:
   unsandboxed, Developer-ID + Notarisierung, undokumentierte SkyLight/CGS-Funktionen
   (reverse-engineeren aus Thaw / Bar Keeper's Friend / Ice-Tahoe-Branch). Fragil über
   Point-Releases, aber kommerziell erprobt. Konkrete Funktionsnamen noch zu ermitteln.
2. **Öffentlich-sauberer Weg** — **Panel/Launcher + Umsortieren** (beides verifiziert),
   KEIN echtes Verstecken; macOS 27 übernimmt das Überlauf-Verstecken selbst („«" /
   Systemeinstellungen → Menüleiste). Stabil, kein Private-API-Risiko.

Monitoring: bei jedem macOS-Update prüfen, ob Apple Layer-25-Fenster oder die
`.length`-Layout-Reservierung zurückbringt (würde Weg 2 wieder zum Vollversteck machen).
