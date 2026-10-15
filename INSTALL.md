# Tidier installieren

Universal-App (Intel + Apple Silicon), **macOS 14 oder neuer**.

## 1. Installieren

1. `Tidier-x.y.z.dmg` öffnen.
2. **Tidier** auf den **Programme**-Ordner ziehen.
3. DMG auswerfen.

> Tidier **muss** aus dem Programme-Ordner laufen — macOS blendet die Symbole von Apps
> aus, die woanders gestartet werden (auch Tidiers eigenes Chevron).

## 2. Beim ersten Start (Gatekeeper)

Tidier ist aktuell **selbst­signiert, nicht notarisiert**. macOS verweigert deshalb beim
ersten Start die Ausführung („… kann nicht geöffnet werden, da der Entwickler nicht
überprüft werden kann"). So erlaubst du es einmalig:

**macOS 15 Sequoia / macOS 26 / macOS 27:**
1. Tidier einmal per Doppelklick starten → die Blockier-Meldung erscheint, auf **Fertig** klicken.
2. **Systemeinstellungen → Datenschutz & Sicherheit** öffnen, ganz nach unten scrollen.
3. Bei „Tidier wurde blockiert…" auf **Trotzdem öffnen** klicken, dann bestätigen.

**macOS 14 Sonoma:**
- Im **Programme**-Ordner mit **Rechtsklick** (oder ctrl-Klick) auf **Tidier** → **Öffnen** →
  im Dialog nochmal **Öffnen**.

Danach startet Tidier ganz normal.

## 3. Berechtigungen erteilen

Tidier braucht **Bedienungshilfen**, um die Menüleiste zu lesen und Symbole aus- und
einzublenden:

- **Systemeinstellungen → Datenschutz & Sicherheit → Bedienungshilfen** → **Tidier** aktivieren.

(Optional, nur für ältere macOS-Versionen mit Kachel-Vorschau: **Bildschirmaufnahme**.)

## 4. Benutzen

- **Rechtsklick auf das Chevron** `‹` in der Menüleiste → **Einstellungen → Menüleiste**:
  dort wählst du, welche **App-Symbole** und **System-Symbole** (WLAN, Bluetooth, Batterie,
  Uhr …) im Ruhezustand ausgeblendet werden.
- **Linksklick auf das Chevron** blendet die versteckten Symbole kurz wieder ein; nach ein
  paar Sekunden (oder beim Klick woanders) verschwinden sie wieder.

---

*Hinweis: Eine notarisierte Version (ohne den Gatekeeper-Umweg aus Schritt 2) folgt, sobald
ein Apple-Developer-ID-Zertifikat vorliegt.*
