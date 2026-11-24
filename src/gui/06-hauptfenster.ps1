# ---- Seitenleiste
$side =New-Object System.Windows.Forms.Panel; $side.Dock = 'Left'; $side.Width = 270; $side.BackColor = $th.Surface
$form.Controls.Add($side)
$lt = New-Object System.Windows.Forms.Label; $lt.Text = 'DirToy'; $lt.Font = $fTitle; $lt.ForeColor = $th.Accent; $lt.AutoSize = $true
[void](Add-To $side $lt 18 16 0 0)
[void](New-Label $side 20 62 230 'Ordner synchron halten' $true)
$lblVer = New-Label $side 20 80 230 "Version $($script:version)  ·  Updates prüfen" $true
$lblVer.Cursor = 'Hand'; $lblVer.ForeColor = $th.Accent
$script:updTimer = New-Object System.Windows.Forms.Timer; $script:updTimer.Interval = 300
$script:updTimer.Add_Tick({ if ($script:updTask -and $script:updTask.IsCompleted) { Finish-UpdateCheck } })
[void](New-Label $side 20 110 230 'AUFGABEN' $true)
$lb = New-Object System.Windows.Forms.ListBox
$lb.BorderStyle = 'None'; $lb.BackColor = $th.Surface; $lb.ForeColor = $th.Text; $lb.DrawMode = 'OwnerDrawFixed'; $lb.ItemHeight = 38
[void](Add-To $side $lb 0 134 270 430); $lb.Anchor = $A_TLB
$btnNew = New-Btn $side 16 664 112 38 '+ Neu' $false $th.Surface
$btnDel = New-Btn $side 140 664 112 38 'Löschen' $false $th.Surface
$btnNew.Anchor = $A_BL; $btnDel.Anchor = $A_BL
$btnHelp = New-Btn $side 16 618 236 36 'Hilfe' $false $th.Surface; $btnHelp.Anchor = $A_BL
$btnUpd = New-Btn $side 16 530 236 36 'Update verfügbar' $true $null; $btnUpd.Anchor = $A_BL; $btnUpd.Visible = $false
$themeNames = @{ auto = 'Design: Automatisch'; hell = 'Design: Hell'; dunkel = 'Design: Dunkel' }
$btnTheme = New-Btn $side 16 574 236 36 $themeNames[$script:themeSetting] $false $th.Surface; $btnTheme.Anchor = $A_BL
$lb.Add_DrawItem({
    param($s, $e)
    if ($e.Index -lt 0) { return }
    $sel = (($e.State -band [System.Windows.Forms.DrawItemState]::Selected) -ne 0)
    $bg = if ($sel) { $script:th.SelBg } else { $script:th.Surface }
    $br = New-Object System.Drawing.SolidBrush($bg); $e.Graphics.FillRectangle($br, $e.Bounds); $br.Dispose()
    if ($sel) {
        $ab = New-Object System.Drawing.SolidBrush($script:th.Accent)
        $e.Graphics.FillRectangle($ab, $e.Bounds.X + 6, $e.Bounds.Y + 9, 3, $e.Bounds.Height - 18); $ab.Dispose()
    }
    $r = New-Object System.Drawing.Rectangle(($e.Bounds.X + 20), $e.Bounds.Y, ($e.Bounds.Width - 28), $e.Bounds.Height)
    $fl = [System.Windows.Forms.TextFormatFlags]::VerticalCenter -bor [System.Windows.Forms.TextFormatFlags]::EndEllipsis -bor [System.Windows.Forms.TextFormatFlags]::Left
    [System.Windows.Forms.TextRenderer]::DrawText($e.Graphics, [string]$s.Items[$e.Index], $e.Font, $r, $script:th.Text, $fl)
})

# ---- Hauptbereich
$main = New-Object System.Windows.Forms.Panel; $main.Dock = 'Fill'; $main.BackColor = $th.Bg
$form.Controls.Add($main); $main.BringToFront()
$cw = 770   # Breite der Karten (Hauptbereich ist ~810 breit)
$card = New-Card $main 20 20 $cw 292; $card.Anchor = $A_TLR
$iw = $cw - 40
[void](New-Label $card 20 12 300 'Name der Aufgabe' $true)
$tbName = New-Input $card 20 34 $iw; $tbName.Anchor = $A_TLR
[void](New-Label $card 20 72 300 'Ordner A  (Quelle / links)' $true)
$tbA = New-Input $card 20 94 ($iw - 44); $tbA.Anchor = $A_TLR
$btnA = New-Btn $card ($cw - 60) 93 40 30 '…' $false $th.Surface; $btnA.Anchor = $A_TR
[void](New-Label $card 20 132 300 'Ordner B  (Ziel / rechts)' $true)
$tbB = New-Input $card 20 154 ($iw - 44); $tbB.Anchor = $A_TLR
$btnB = New-Btn $card ($cw - 60) 153 40 30 '…' $false $th.Surface; $btnB.Anchor = $A_TR
[void](New-Label $card 20 192 300 'Modus' $true)
$cmb = New-Object System.Windows.Forms.ComboBox; $cmb.DropDownStyle = 'DropDownList'; $cmb.FlatStyle = 'Flat'
$cmb.BackColor = $th.Input; $cmb.ForeColor = $th.Text; $cmb.Font = $fNormal
foreach ($m in $script:modes) { [void]$cmb.Items.Add($m) }
[void](Add-To $card $cmb 20 214 $iw 28); $cmb.Anchor = $A_TLR
[void](New-Label $card 20 250 $iw 'Nicht synchronisieren  (Dateinamen/Muster mit ;  getrennt, z.B.  Thumbs.db;*.tmp;~$*;node_modules)' $true)
$card.Height = 316
$tbEx = New-Input $card 20 272 ($iw - 176); $tbEx.Anchor = $A_TLR
$btnDirs = New-Btn $card ($cw - 20 - 166) 270 166 32 'Ordner wählen ...' $false $th.Surface; $btnDirs.Anchor = $A_TR
$script:btnDirs = $btnDirs

$btnPrev = New-Btn $main 20 340 130 40 'Vorschau' $false $th.Bg
$btnRun  = New-Btn $main 160 340 170 40 'Synchronisieren' $true $null
$btnAll  = New-Btn $main 340 340 200 40 'Alle Aufgaben ausführen' $false $th.Bg
$btnCancel = New-Btn $main 160 340 170 40 'Abbrechen' $false $th.Bg; $btnCancel.Visible = $false
$btnSched = New-Btn $main 550 340 115 40 'Zeitplan ...' $false $th.Bg; $btnSched.Anchor = $A_TL
$btnLog = New-Btn $main 675 340 115 40 'Protokoll' $false $th.Bg; $btnLog.Anchor = $A_TL
# Fortschrittsbalken
$progTrack = New-Object System.Windows.Forms.Panel; $progTrack.BackColor = $th.Border
[void](Add-To $main $progTrack 20 386 $cw 6); $progTrack.Anchor = $A_TLR
$progFill = New-Object System.Windows.Forms.Panel; $progFill.BackColor = $th.Accent; $progFill.Dock = 'Left'; $progFill.Width = 0
$progTrack.Controls.Add($progFill)
$script:progTrack = $progTrack; $script:progFill = $progFill

# ---- Log
$logCard = New-Card $main 20 396 $cw 264; $logCard.Anchor = $A_ALL
$lv = New-Object System.Windows.Forms.ListView
[void]$lv.Columns.Add('Aktion', 250); [void]$lv.Columns.Add('Datei', 330); [void]$lv.Columns.Add('Status', 180)
Set-ListBehavior $lv $true 30
[void](Add-To $logCard $lv 0 0 $cw 264); $lv.Dock = 'Fill'
$script:lv = $lv
$lv.Add_DoubleClick({
    if ($lv.SelectedItems.Count -gt 0) {
        $f = $lv.SelectedItems[0].Tag
        if ($f -is [string] -and $f.EndsWith('vorschau.csv') -and (Test-Path $f)) {
            try { Start-Process -FilePath $f -ErrorAction Stop }
            catch { Start-Process notepad.exe -ArgumentList "`"$f`"" }   # keine Zuordnung fuer .csv: im Editor oeffnen
        }
    }
})
$lv.Add_Resize({
    $w = $lv.ClientSize.Width - $lv.Columns[0].Width - $lv.Columns[2].Width
    if ($w -gt 150) { $lv.Columns[1].Width = $w }
})

$lbl = New-Object System.Windows.Forms.Label; $lbl.Text = 'Bereit.'; $lbl.Font = $fSmall; $lbl.ForeColor = $th.Muted
$lbl.AutoSize = $false; $lbl.BackColor = [System.Drawing.Color]::Transparent
[void](Add-To $main $lbl 20 672 300 24); $lbl.Anchor = $A_BL
$lblSched = New-Object System.Windows.Forms.Label; $lblSched.Font = $fSmall; $lblSched.ForeColor = $th.Muted; $lblSched.AutoSize = $false
$lblSched.TextAlign = 'MiddleRight'; $lblSched.BackColor = [System.Drawing.Color]::Transparent
[void](Add-To $main $lblSched 330 672 460 24); $lblSched.Anchor = $A_BLR
$script:lblSched = $lblSched
$script:lblStatus = $lbl
$tip = New-Object System.Windows.Forms.ToolTip
$tip.SetToolTip($lb, 'Deine Sync-Aufgaben. Auswählen zum Bearbeiten.')
$tip.SetToolTip($tbName, 'Name der Aufgabe (erscheint auch im Aufgabenplaner).')
$tip.SetToolTip($tbA, 'Erster Ordner. Bei "Echo" und "Beitragen" ist das die Quelle.')
$tip.SetToolTip($tbB, 'Zweiter Ordner. Bei "Echo" und "Beitragen" ist das das Ziel.')
$tip.SetToolTip($cmb, 'Synchronisieren: beidseitig, mit Löschungen. Echo: B wird exakt wie A. Beitragen: A nach B, ohne Löschen.')
$tip.SetToolTip($btnPrev, 'Zeigt nur an, was passieren würde. Es wird nichts verändert.')
$tip.SetToolTip($btnRun, 'Führt die gewählte Aufgabe jetzt aus.')
$tip.SetToolTip($btnAll, 'Führt alle Aufgaben nacheinander aus.')
$tip.SetToolTip($btnDirs, 'Zeigt beide Ordner als Baum. Ordner abhaken, die nicht synchronisiert werden sollen.')
$tip.SetToolTip($btnCancel, 'Bricht nach der aktuellen Datei ab. Es bleiben keine halben Dateien zurück.')
$tip.SetToolTip($btnSched, 'Automatische Ausführung im Windows-Aufgabenplaner anlegen, ändern oder entfernen.')
$tip.SetToolTip($btnLog, 'Öffnet das Protokoll aller bisherigen Läufe (sync.log).')
$tip.SetToolTip($btnNew, 'Neue Sync-Aufgabe anlegen.')
$tip.SetToolTip($btnDel, 'Gewählte Aufgabe löschen (Dateien bleiben unverändert, ein Zeitplan wird mit entfernt).')
$tip.SetToolTip($btnHelp, 'Anleitung zum Tool.')
$tip.SetToolTip($btnTheme, 'Wechselt zwischen Automatisch (wie Windows), Hell und Dunkel. DirToy startet dabei kurz neu.')
$tip.SetToolTip($tbEx, 'Mit ; getrennt. Platzhalter * und ? erlaubt. Gilt für Dateien und Ordnernamen in beiden Ordnern.')

# Dunkle Titelleiste
try {
    Add-Type -Namespace Win32 -Name Dwm -MemberDefinition '[System.Runtime.InteropServices.DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(System.IntPtr hwnd, int attr, ref int val, int size);'
} catch { }
$form.Add_HandleCreated({
    try { $v = if ($isDark) { 1 } else { 0 }; [void][Win32.Dwm]::DwmSetWindowAttribute($form.Handle, 20, [ref]$v, 4) } catch { }
})

