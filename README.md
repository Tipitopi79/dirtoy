# DirToy

Grafisches Tool für Windows, das zwei Ordner synchron hält – inspiriert von SyncToy.
Geschrieben in PowerShell (WinForms), ohne Installation lauffähig.

![Version](https://img.shields.io/badge/version-1.0.0-blue) ![Lizenz](https://img.shields.io/badge/lizenz-MIT-green)

## Funktionen

- Beliebig viele **Sync-Aufgaben** mit je zwei Ordnern (A und B)
- **Drei Modi**: Synchronisieren (beidseitig), Echo (A → B, B wird wie A), Beitragen (A → B, ohne Löschen)
- **Ordner 1:1 identisch**: alle Unterordner werden rekursiv gespiegelt, auch leere; angelegt und (außer im Modus *Beitragen*) auch gelöscht
- **Sicheres Kopieren**: Dateien werden erst als Zwischendatei (`.dirtoy-tmp`) geschrieben und am Ende umbenannt – bei Abbruch oder Absturz bleibt das Original im Ziel unverändert. Mit **Abbrechen** stoppt ein Lauf nach der aktuellen Datei, auch beim Schließen des Fensters.
- **Ordnerbaum zum Abwählen**: beide Ordner nebeneinander als Baum, Haken entfernen = Ordner samt Unterordnern wird nicht synchronisiert. Neue Ordner sind standardmäßig dabei, gespeichert werden nur die abgewählten
- **Ausschlussfeld**: Dateinamen und Muster mit `;` getrennt, z. B. `Thumbs.db;*.tmp;node_modules`
- **Vorschau** zeigt, was passieren würde, ohne etwas zu verändern
- **Fortschrittsbalken** und **Protokoll** (Liste im Fenster und `sync.log`)
- **Zeitpläne** direkt im Tool: legt Einträge im Windows-Aufgabenplaner an, ändert und entfernt sie
- Windows-**Benachrichtigung** nach automatischen Läufen
- **Hell- und Dunkel-Design**: automatisch wie Windows oder fest einstellbar (Button "Design")

## Voraussetzungen

Windows 10 oder 11 (Windows PowerShell 5.1 ist enthalten). Keine Installation nötig.

## Start

1. `DirToy.ps1` und `DirToy.vbs` in einen Ordner legen.
2. Doppelklick auf `DirToy.vbs` (startet ohne schwarzes Fenster).

Beim ersten Start wird der Ordner `DirToy-Daten` angelegt (Aufgaben, Zeitpläne, Protokoll).
Wurde die ZIP-Datei aus dem Internet geladen, ggf. vorher in den Dateieigenschaften "Zulassen" anhaken.
Die Skripte sind nicht signiert, Windows kann daher eine Warnung zeigen.

## Automatisch per Aufgabenplaner

Im Tool: Aufgabe wählen → **Zeitplan ...**. Mögliche Zeitpläne: täglich, wöchentlich, alle X Minuten, bei Anmeldung.
Die Aufgaben laufen im Hintergrund, solange man bei Windows angemeldet ist. Verpasste Läufe werden nachgeholt.
Auch von Hand startbar:

```
powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "C:\Pfad\DirToy.ps1" -Task "Name der Aufgabe"
```

(`-All` führt alle Aufgaben aus.)

## ⚠️ Haftungsausschluss / Disclaimer

**DirToy kopiert, überschreibt und löscht Dateien.** Die Nutzung erfolgt **auf eigene Gefahr**.
Die Software wird **ohne jede Gewährleistung** bereitgestellt (siehe [LICENSE](LICENSE)); der Autor haftet nicht für Datenverlust oder sonstige Schäden.

Bitte unbedingt beachten:

- **Immer zuerst die Vorschau** benutzen, vor allem bei den Modi *Synchronisieren* und *Echo*.
- **Eine Datensicherung** der betroffenen Ordner anlegen, bevor eine neue Aufgabe zum ersten Mal läuft.
- Gelöscht wird in den **Papierkorb**, bei Netzlaufwerken ohne Papierkorb aber **endgültig**.
- Automatische Läufe fragen **nicht** vor dem Löschen nach.

**English:** DirToy copies, overwrites and deletes files. Use at your own risk. Provided "as is" without warranty of any kind (see LICENSE). Always run the preview first and keep a backup.

## Lizenz

[MIT](LICENSE) – Nutzung, Änderung und Weitergabe sind erlaubt, auch kommerziell, solange der Lizenzhinweis erhalten bleibt.
