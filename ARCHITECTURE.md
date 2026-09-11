# Tidier – Architektur der echten Einzel-Item-Verwaltung

Ziel: Ice/Bartender-Niveau — einzelne Menüleisten-Items gezielt verstecken/zeigen,
**unabhängig von ihrer Position** (z. B. iStat + System behalten, nur den Kram in
der Mitte ausblenden). Der naive Längen-Trick kann das nicht (er versteckt nur
einen zusammenhängenden Block links eines Trenners).

## Was macOS 26 zulässt (empirisch geprüft 2026-09-11)

- **Enumerieren:** `CGWindowListCopyWindowInfo` + Layer 25 liefert alle Status-Items
  mit Geometrie (X/Breite) und Besitzer. ✅ ohne Sonderrechte (siehe `probe/`).
- **Identität (Fenster-Name, z. B. `com.bjango.istatmenus.cpu`, `WiFi`, `Clock`):**
  nur mit **Bildschirmaufnahme-Berechtigung** (Screen Recording / TCC). Ohne sie
  heißen alle Items „Kontrollzentrum" (macOS 26 hostet alle Items unter PID von
  Control Center). ⇒ App muss Screen-Recording anfragen.
- **Items bewegen/umsortieren:** kein öffentliches API bewegt fremde Status-Items
  direkt. Einziger gangbarer Weg = **synthetischer ⌘-Drag** per `CGEvent`
  (mouseDown mit ⌘ → move → up) an den Item-Koordinaten. Braucht
  **Bedienungshilfen-Berechtigung** (Accessibility) zum Event-Posten. So machen es
  Tools wie Bartender.

## Konsequenz: Repositioning-Engine (Kern des Umbaus)

Sektionsmodell wie Ice: `[immer sichtbar] | Trenner | [versteckbar]`. Tidier hält
seinen Trenner + Toggle rechts. Beim „Verstecken":

1. Nutzer markiert in den Einstellungen je Item **Sichtbar / Verstecken**
   (Liste kommt aus `MenuBarScanner`).
2. Engine sortiert per synthetischem ⌘-Drag die „Verstecken"-Items **links** des
   Trenners und die „Sichtbar"-Items **rechts** davon — einmalig/bei Änderung.
3. Danach reicht der bereits funktionierende Längen-Trick zum Ein-/Ausklappen des
   linken Blocks. Ergebnis: beliebige (auch „mittige") Items lassen sich behalten
   oder verstecken, weil sie vorher passend einsortiert wurden.

### Bausteine
- `MenuBarScanner` (vorhanden): Enumeration.
- `PermissionManager` (neu): Screen-Recording (Namen) + Accessibility (Events)
  anfragen/prüfen, mit klarer UI.
- `DragEngine` (neu): CGEvent-⌘-Drag von Item A nach Position B; robust gegen
  Menubar-Animationen (Schrittweise, Verifikation per Re-Scan).
- `SectionStore` (neu): Persistente Zuordnung Item→Sektion (stabiler Key: Fenster-
  Name falls verfügbar, sonst Besitzer+relative Position/Heuristik).
- `StatusBarController` (vorhanden): Trenner/Toggle + Längen-Trick (bleibt).

### Optional: „Tidier Bar"
Statt Items nur off-screen zu schieben, in einem eigenen Popover-Fenster als
klickbare Proxys anzeigen (Item-Bild via CGWindowList-Capture; Klick per CGEvent
an die echte Item-Position weiterreichen). Das ist Ices „Ice Bar".

## Risiken / offene Punkte
- ⌘-Drag-Choreografie ist macOS-versionsabhängig und muss sorgfältig getestet
  werden (genau der Grund, warum das eine eigene, fokussierte Bau-Session ist).
- Zwei TCC-Berechtigungen nötig (Screen Recording + Accessibility) → Onboarding-UI.
- Stabile Item-Identität ohne Namen (fehlende Screen-Recording-Freigabe) nur
  heuristisch.

## Status
- ✅ Enumeration in App integriert (Tab „Menüleiste" listet Items + Positionen).
- ⏳ PermissionManager, DragEngine, SectionStore, Tidier Bar.
