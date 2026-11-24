# ---- Hilfe-Fenster
function Show-Help {
    $d = New-Object System.Windows.Forms.Form
    $d.Text = 'DirToy - Hilfe'; $d.ClientSize = New-Object System.Drawing.Size(680, 640); $d.MinimumSize = New-Object System.Drawing.Size(520, 400)
    $d.StartPosition = 'CenterParent'; $d.ShowInTaskbar = $false; $d.BackColor = $th.Surface; $d.ForeColor = $th.Text; $d.Font = $fNormal
    $rb = New-Object System.Windows.Forms.RichTextBox
    $rb.ReadOnly = $true; $rb.BorderStyle = 'None'; $rb.BackColor = $th.Surface; $rb.ForeColor = $th.Text; $rb.Font = $fNormal
    $rb.Location = New-Object System.Drawing.Point(24, 16); $rb.Size = New-Object System.Drawing.Size(632, 552); $rb.Anchor = $A_ALL
    $rb.DetectUrls = $false; $rb.TabStop = $false
    $d.Controls.Add($rb)
    function HelpH($t) { $rb.SelectionStart = $rb.TextLength; $rb.SelectionFont = $fBold; $rb.SelectionColor = $th.Accent; $rb.AppendText("`n$t`n") }
    function HelpP($t) { $rb.SelectionStart = $rb.TextLength; $rb.SelectionFont = $fNormal; $rb.SelectionColor = $th.Text; $rb.AppendText("$t`n") }
    function HelpB($k, $t) {
        $rb.SelectionStart = $rb.TextLength; $rb.SelectionFont = $fBold; $rb.SelectionColor = $th.Text; $rb.AppendText("   $k")
        $rb.SelectionStart = $rb.TextLength; $rb.SelectionFont = $fNormal; $rb.SelectionColor = $th.Text; $rb.AppendText("  $t`n")
    }
    $rb.SelectionStart = 0; $rb.SelectionFont = $fTitle; $rb.SelectionColor = $th.Accent; $rb.AppendText("DirToy`n")
    $rb.SelectionStart = $rb.TextLength; $rb.SelectionFont = $fSmall; $rb.SelectionColor = $th.Muted; $rb.AppendText("Version $($script:version)`n`n")
    HelpP 'Hält zwei Ordner synchron. Du kannst beliebig viele Aufgaben anlegen, jede mit eigenen Ordnern, Modus, Ausschlüssen und Zeitplan.'
    HelpH 'So geht es'
    HelpB '1.' 'Links auf "+ Neu" klicken und der Aufgabe einen Namen geben.'
    HelpB '2.' 'Ordner A und Ordner B wählen (Button "...").'
    HelpB '3.' 'Modus wählen (siehe unten).'
    HelpB '4.' '"Vorschau" zeigt, was passieren würde, ohne etwas zu verändern.'
    HelpB '5.' '"Synchronisieren" führt es aus. Der Balken zeigt den Fortschritt, die Liste das Ergebnis.'
    HelpH 'Die drei Modi'
    HelpB 'Synchronisieren' 'Beide Richtungen. Neue und geänderte Dateien werden auf die andere Seite kopiert, bei Änderungen auf beiden Seiten gewinnt die neuere Datei. Löscht du eine Datei auf einer Seite, wird sie beim nächsten Lauf auch auf der anderen gelöscht. Beim allerersten Lauf wird nichts gelöscht.'
    HelpB 'Echo' 'Nur A nach B. B wird zu einer exakten Kopie von A: Was in A fehlt, wird in B gelöscht, und Änderungen in B werden überschrieben.'
    HelpB 'Beitragen' 'Nur A nach B. Neue und geänderte Dateien aus A werden kopiert, es wird nie etwas gelöscht.'
    HelpP '   Bei gleicher Zeit, aber anderer Größe meldet das Tool einen Konflikt und überspringt die Datei.'
    HelpH 'Nicht synchronisieren'
    HelpP 'Im Feld stehen Dateinamen oder Muster, getrennt mit Semikolon. * steht für beliebig viele Zeichen, ? für ein Zeichen. Die Muster gelten für Dateien und Ordnernamen in beiden Ordnern. Ausgeschlossenes wird weder kopiert noch gelöscht.'
    HelpB 'Beispiele' 'Thumbs.db;*.tmp;~$*;node_modules;*.bak'
    HelpH 'Ordner abwählen'
    HelpP 'Mit "Ordner wählen ..." siehst du beide Ordner als Baum nebeneinander. Entfernst du bei einem Ordner den Haken, wird er samt allen Unterordnern nicht synchronisiert (auf keiner Seite kopiert oder gelöscht). Der Haken gilt für beide Seiten. Neue Ordner, die später dazukommen, sind immer dabei, gespeichert werden nur die abgewählten. Ein abgewählter Ordner bleibt auch dann abgewählt, wenn er gelöscht und später neu angelegt wird; solche Einträge erscheinen grau mit "(nicht vorhanden)" und lassen sich durch Anhaken entfernen. "Alle wieder einschließen" setzt alle Haken zurück.'
    HelpH 'Löschen und Sicherheit'
    HelpP 'Dateien werden zuerst unter einem Zwischennamen (.dirtoy-tmp) kopiert und erst am Ende umbenannt. Bricht ein Lauf ab oder schließt du das Fenster, bleibt die alte Datei im Ziel unverändert; übrig gebliebene Zwischendateien räumt DirToy beim nächsten Lauf auf. Mit "Abbrechen" stoppst du einen Lauf nach der aktuellen Datei.'
    HelpP 'Vor dem Löschen fragt das Tool nach. Gelöscht wird in den Papierkorb, bei Netzlaufwerken ohne Papierkorb aber endgültig. Schau dir deshalb bei "Synchronisieren" und "Echo" zuerst die Vorschau an. Ordner dürfen nicht identisch sein oder ineinander liegen. Ordner werden komplett mit allen Unterordnern gespiegelt, auch leere. Ein Ordner wird nur gelöscht, wenn er danach wirklich leer ist (ausgeschlossene Dateien darin verhindern das Löschen).'
    HelpH 'Zeitplan (automatisch)'
    HelpP 'Mit "Zeitplan ..." legst du für die gewählte Aufgabe einen Eintrag im Windows-Aufgabenplaner an: täglich, wöchentlich, alle X Minuten (mit Startzeit) oder bei der Anmeldung. Täglich und wöchentlich lassen sich mit "Danach wiederholen alle ... Min. für ... Std." kombinieren (z. B. täglich ab 08:00 alle 20 Minuten für 10 Stunden). Du kannst den Eintrag im Aufgabenplaner jederzeit ändern oder entfernen. Das Tool muss dafür nicht laufen, aber du musst bei Windows angemeldet sein. Verpasste Läufe werden nachgeholt, bei Intervallen und Wiederholungen aber nicht. DirToy prüft nach dem Anlegen, ob der Eintrag wirklich existiert. Fehlen auf dem Rechner die Rechte (kein Administrator), zeigt DirToy eine Anleitung zum Anlegen von Hand, mit kopierbarem Befehl und als Notlösung einem Autostart-Eintrag. Bei automatischen Läufen gibt es keine Rückfrage vor dem Löschen.'
    HelpP 'Nach einem automatischen Lauf kann eine Windows-Meldung erscheinen: nie, wenn etwas passiert ist oder Fehler auftraten, oder nur bei Fehlern.'
    HelpH 'Große Vorschau'
    HelpP 'Die Liste zeigt höchstens 2000 Zeilen. Gibt es mehr Aktionen, steht am Ende die Zeile "... und N weitere Aktionen": Ein Doppelklick darauf öffnet die komplette Vorschau als CSV-Datei (DirToy-Daten\vorschau.csv, z. B. in Excel) mit den Spalten Aktion, Ordner, Datei und Relativer Pfad, die du dort filtern und sortieren kannst. Die Summen je Aktion stehen schon in der Liste. Bei einem echten Lauf läuft die Liste mit: Es bleiben die letzten 2000 Aktionen sichtbar, die ältesten fallen oben heraus (Fehler werden am Ende noch einmal aufgelistet). Alle Aktionen werden ausgeführt und stehen im Protokoll.'
    HelpH 'Protokoll'
    HelpP 'Die Liste unten zeigt den aktuellen Lauf. Alle echten Läufe, manuell und automatisch, stehen zusätzlich mit Uhrzeit in DirToy-Daten\sync.log. Der Button "Protokoll" öffnet diese Datei.'
    HelpP 'Nach einem manuellen Lauf, bei dem etwas passiert ist oder Fehler auftraten, öffnet sich ein Ergebnis-Fenster: Zusammenfassung je Aktion (kopiert, aktualisiert, gelöscht ...), Fehler, Dauer und Datenmenge, darunter die einzelnen Aktionen (Fehler zuerst). Ein Klick auf einen Spaltenkopf sortiert, Strg+C kopiert markierte Zeilen, "Details als CSV öffnen" zeigt alles in Excel. Das Fenster lässt sich unten im Hilfe-Fenster abschalten. Auch die Liste im Hauptfenster ist sortierbar und kopierbar (Strg+C, Strg+A, Rechtsklick).'
    HelpH 'Design'
    HelpP 'Der Button "Design" unten links wechselt zwischen Automatisch (wie Windows), Hell und Dunkel. DirToy startet dabei kurz neu, die Einstellung steht in DirToy-Daten\einstellungen.json.'
    HelpH 'Updates'
    HelpP 'Beim Start fragt DirToy im Hintergrund bei GitHub nach einer neueren Version (nur die Versionsnummer wird abgefragt, es werden keine Daten von dir gesendet). Gibt es eine, erscheint links der Button "Update verfügbar". Dort kannst du "Jetzt aktualisieren" wählen (lädt DirToy.ps1 aus dem Release, prüft sie, sichert die alte Datei als DirToy.ps1.bak-<Version> und startet neu) oder die Release-Seite im Browser öffnen. Ein Klick auf "Updates prüfen" unter dem Titel sucht von Hand; dort lässt sich die automatische Suche auch abschalten. Aufgaben im Aufgabenplaner suchen nie nach Updates.'
    HelpH 'Wo liegen meine Daten?'
    HelpP 'Aufgaben und Zeitpläne stehen in DirToy-Daten\aufgaben.json neben dem Programm. Darf DirToy dort nicht schreiben (z. B. in C:\Program Files ohne Administratorrechte), nutzt es automatisch den Ordner %APPDATA%\DirToy und übernimmt vorhandene Aufgaben dorthin. Verschiebst du DirToy.ps1, speichere die Zeitpläne danach einmal neu. Bei Startproblemen steht der Grund in DirToy-Daten\fehler.log.'
    $rb.SelectionStart = 0; $rb.ScrollToCaret()
    $bs = New-Btn $d 24 584 200 36 'Desktop-Verknüpfung' $false $th.Surface; $bs.Anchor = $A_BL
    $bs.Add_Click({
        $p = New-DesktopShortcut
        if ($p) { [void](Show-Msg "Die Verknüpfung wurde auf dem Desktop angelegt:`n$p" 'DirToy' 'OK' 'Information') }
        else { [void](Show-Msg 'Die Verknüpfung konnte nicht angelegt werden.' 'DirToy' 'OK' 'Warning') }
    })
    $cbr = New-Object System.Windows.Forms.CheckBox; $cbr.Text = 'Ergebnis-Fenster nach dem Lauf zeigen'; $cbr.AutoSize = $true; $cbr.BackColor = [System.Drawing.Color]::Transparent
    $cbr.Checked = [bool](Get-Setting 'ShowResult' $true); $cbr.Location = New-Object System.Drawing.Point(240, 592); $cbr.Anchor = $A_BL
    $cbr.Add_CheckedChanged({ Set-Setting 'ShowResult' $this.Checked })
    $d.Controls.Add($cbr)
    $bc = New-Btn $d 556 584 100 36 'Schließen' $true $null; $bc.Anchor = $A_BR
    $script:helpClose = $bc
    $bc.Add_Click({ $script:helpClose.FindForm().Close() })
    $d.Add_HandleCreated({
        try { $v = if ($isDark) { 1 } else { 0 }; [void][Win32.Dwm]::DwmSetWindowAttribute($script:helpClose.FindForm().Handle, 20, [ref]$v, 4) } catch { }
    })
    [void]$d.ShowDialog($form)
    $d.Dispose()
}
