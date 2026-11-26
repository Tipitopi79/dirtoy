# ---- Ablauf: Aufgabenliste, Bearbeiten, Starten
$script:modeHelp = @('A und B werden gleich: neuere Datei gewinnt, Löschungen werden übernommen.', 'B wird exakt wie A. Was nur in B liegt, wird gelöscht.', 'Neues und Geändertes von A nach B. Es wird nichts gelöscht.')
$script:items = [System.Collections.ObjectModel.ObservableCollection[DirToyTask]]::new()
$ui.lb.ItemsSource = $script:items
$script:editors = @($ui.tbName, $ui.tbA, $ui.tbB, $ui.tbEx, $ui.m0, $ui.m1, $ui.m2, $ui.btnA, $ui.btnB)
$script:actions = @($ui.btnPrev, $ui.btnRun, $ui.btnDel, $ui.btnSched, $ui.btnDirs, $ui.btnGear)
$script:taskInfo = @{}   # Ergebnis des letzten Laufs in dieser Sitzung je Aufgabe
$script:busy = $false
$script:closeRequested = $false
$script:loading = $false

function Get-LeafName([string]$p) {
    $x = $p.TrimEnd('\')
    if (-not $x) { return 'nicht gewählt' }
    $i = $x.LastIndexOf('\'); if ($i -ge 0 -and $i -lt $x.Length - 1) { return $x.Substring($i + 1) }
    return $x
}
# Punkt und zweite Zeile in der Aufgabenliste. "zuletzt" = Zeitpunkt des gemerkten Stands (auch von Zeitplan-Laeufen)
function Update-Item($item) {
    $inf = $script:taskInfo[$item.Id]
    $f = Join-Path $script:stateDir "$($item.Id).state"
    $when = ''
    if (Test-Path -LiteralPath $f) {
        $d = (Get-Item -LiteralPath $f).LastWriteTime
        $when = if ($d.Date -eq [datetime]::Today) { 'heute ' + $d.ToString('HH:mm') } elseif ($d.Date -eq [datetime]::Today.AddDays(-1)) { 'gestern ' + $d.ToString('HH:mm') } else { $d.ToString('dd.MM.yyyy') }
    }
    if ($inf -and $inf.Failed) { $item.Dot = $script:br.Err; $item.Sub = 'nicht gelaufen, siehe Liste' }
    elseif ($inf -and $inf.Errors -gt 0) { $item.Dot = $script:br.Err; $item.Sub = "$when, $($inf.Errors) Fehler" }
    elseif ($inf -and $inf.Cancelled) { $item.Dot = $script:br.Warn; $item.Sub = 'abgebrochen' }
    elseif ($when) { $item.Dot = $script:br.Ok; $item.Sub = "zuletzt $when" }
    else { $item.Dot = $script:br.Border; $item.Sub = 'noch nie gelaufen' }
}
function Set-TaskInfo($x) {
    $script:taskInfo[$x[0]] = @{ Failed = $x[1]; Errors = $x[2]; Cancelled = $x[3] }
    foreach ($it in $script:items) { if ($it.Id -eq $x[0]) { Update-Item $it } }
}
function Update-DirsButton {
    $n = if ($script:cur) { @($script:cur.ExcludeDirs | Where-Object { $_ }).Count } else { 0 }
    $ui.btnDirs.Content = $(if ($n -gt 0) { "Ordner abwählen ($n)" } else { 'Ordner abwählen ...' })
}
function Refresh-List([int]$select) {
    $script:loading = $true
    $script:items.Clear()
    foreach ($t in $script:tasks) { $it = [DirToyTask]::new(); $it.Id = [string]$t.Id; $it.Name = [string]$t.Name; Update-Item $it; $script:items.Add($it) }
    $ui.lb.SelectedIndex = $(if ($select -ge 0 -and $select -lt $script:items.Count) { $select } else { -1 })
    $script:loading = $false
    Show-Cur
}
$script:modeNames = @('Synchronisieren', 'Echo', 'Beitragen')
# Nach dem ersten Lauf (es gibt einen Stand) wandert die Moduswahl hinters Zahnrad: kein versehentliches Umschalten.
function Test-HasRun($t) { return [bool]($t -and $t.Id -and ((Test-Path -LiteralPath (Join-Path $script:stateDir "$($t.Id).state")) -or (Test-Path -LiteralPath (Join-Path $script:stateDir "$($t.Id).json")))) }
function Place-ModeBox([bool]$inGear) {
    $box = $ui.modeBox; $to = $(if ($inGear) { $ui.gearMode } else { $ui.bar })
    if ($box.Parent -ne $to) {
        $box.Parent.Children.Remove($box)
        if ($inGear) { [void]$to.Children.Add($box) } else { $to.Children.Insert(0, $box) }
    }
    $ui.gearMode.Visibility = $(if ($inGear) { 'Visible' } else { 'Collapsed' })
}
function Show-Mode([int]$m) {
    $ui.lblMode.Text = $(if ($ui.modeBox.Parent -eq $ui.gearMode) { "$($script:modeNames[$m]): $($script:modeHelp[$m])" } else { $script:modeHelp[$m] })
    Show-Direction $m
}
function Show-Cur {
    $i = $ui.lb.SelectedIndex
    $script:loading = $true
    if ($i -ge 0) {
        $script:cur = $script:tasks[$i]
        $ui.tbName.Text = [string]$script:cur.Name; $ui.tbA.Text = [string]$script:cur.A; $ui.tbB.Text = [string]$script:cur.B; $ui.tbEx.Text = [string]$script:cur.Exclude
        $mi = [int]$script:cur.Mode; if ($mi -lt 0 -or $mi -gt 2) { $mi = 0 }
        Place-ModeBox (Test-HasRun $script:cur)
        $ui["m$mi"].IsChecked = $true; Show-Mode $mi
    } else {
        $script:cur = $null
        Place-ModeBox $false
        $ui.tbName.Text = ''; $ui.tbA.Text = ''; $ui.tbB.Text = ''; $ui.tbEx.Text = ''; $ui.lblMode.Text = ''
        foreach ($k in 'm0', 'm1', 'm2') { $ui[$k].IsChecked = $false }
    }
    $ui.lblA.Text = Get-LeafName $ui.tbA.Text; $ui.lblB.Text = Get-LeafName $ui.tbB.Text
    $script:loading = $false
    Update-Enabled
    Update-SchedLabel
    Update-DirsButton
}
function Update-Enabled {
    $has = [bool]$script:cur
    foreach ($c in $script:editors) { $c.IsEnabled = $has }
    foreach ($c in $script:actions) { $c.IsEnabled = ($has -and -not $script:busy) }
    $ui.btnAll.IsEnabled = ($script:tasks.Count -gt 0 -and -not $script:busy)
    $ui.btnNew.IsEnabled = $ui.lb.IsEnabled = $ui.btnTheme.IsEnabled = (-not $script:busy)
}
function Set-Busy([bool]$busy) {
    $script:busy = $busy
    if ($busy) { $script:cancel = $false }
    $ui.btnRun.Visibility = $(if ($busy) { 'Collapsed' } else { 'Visible' })
    $ui.btnCancel.Visibility = $(if ($busy) { 'Visible' } else { 'Collapsed' })
    $ui.btnCancel.IsEnabled = $busy; $ui.btnCancel.Content = 'Abbrechen'
    if ($busy) { Update-Enabled }
    else {
        Show-Cur
        if ($script:closeRequested) { $win.Close() }
    }
}

$ui.lb.Add_SelectionChanged({ if (-not $script:loading) { Set-Opacity $ui.done 0; Show-Cur } })
$ui.tbName.Add_TextChanged({
    if ($script:loading -or -not $script:cur) { return }
    $script:cur.Name = $ui.tbName.Text
    foreach ($it in $script:items) { if ($it.Id -eq $script:cur.Id) { $it.Name = $ui.tbName.Text } }
    Save-Tasks
})
$ui.tbA.Add_TextChanged({ $ui.lblA.Text = Get-LeafName $ui.tbA.Text; if (-not $script:loading -and $script:cur) { $script:cur.A = $ui.tbA.Text; Save-Tasks } })
$ui.tbB.Add_TextChanged({ $ui.lblB.Text = Get-LeafName $ui.tbB.Text; if (-not $script:loading -and $script:cur) { $script:cur.B = $ui.tbB.Text; Save-Tasks } })
$ui.tbEx.Add_TextChanged({ if (-not $script:loading -and $script:cur) { $script:cur.Exclude = $ui.tbEx.Text; Save-Tasks } })
foreach ($k in 'm0', 'm1', 'm2') {
    $ui[$k].Add_Checked({
        if ($script:loading -or -not $script:cur) { return }
        $script:cur.Mode = [int]$this.Name.Substring(1); Show-Mode $script:cur.Mode; Save-Tasks
    })
}
function Pick-Folder($tb) {
    $d = New-Object System.Windows.Forms.FolderBrowserDialog
    if ($tb.Text -and (Test-Path -LiteralPath $tb.Text)) { $d.SelectedPath = $tb.Text }
    if ($d.ShowDialog($form) -eq 'OK') { $tb.Text = $d.SelectedPath }
}
$ui.btnA.Add_Click({ Pick-Folder $ui.tbA })
$ui.btnB.Add_Click({ Pick-Folder $ui.tbB })
$ui.btnGear.Add_Click({ $ui.gear.Visibility = $(if ($ui.gear.Visibility -eq 'Visible') { 'Collapsed' } else { 'Visible' }) })

function New-TaskNow {
    $t = New-Task ('Aufgabe ' + ($script:tasks.Count + 1))
    $script:tasks = @($script:tasks) + $t
    Save-Tasks; Refresh-List ($script:tasks.Count - 1); [void]$ui.tbName.Focus(); $ui.tbName.SelectAll()
}
$ui.btnNew.Add_Click({ New-TaskNow })
$ui.btnDel.Add_Click({
    $i = $ui.lb.SelectedIndex; if ($i -lt 0) { return }
    $t = $script:tasks[$i]
    if ((Show-Msg "Aufgabe '$($t.Name)' löschen?`n(Die Ordner und Dateien bleiben unverändert.)" 'Löschen' 'YesNo' 'Question') -ne 'Yes') { return }
    try { Unregister-Sched $t } catch { }
    $script:tasks = @($script:tasks | Where-Object { $_.Id -ne $t.Id })
    Remove-Item (Join-Path $script:stateDir "$($t.Id).json"), (Join-Path $script:stateDir "$($t.Id).state") -ErrorAction SilentlyContinue
    Save-Tasks; Refresh-List ([math]::Min($i, $script:tasks.Count - 1))
})
$ui.btnHelp.Add_Click({ Show-Help })
$ui.lblVer.Add_Click({ Start-UpdateCheck $true })
$ui.btnUpd.Add_Click({ if ($script:updInfo) { Do-UpdateAction $script:updInfo (Show-UpdateDialog $script:updInfo 'new') } })
$ui.btnTheme.Add_Click({
    if ($script:busy) { return }
    $next = @{ auto = 'hell'; hell = 'dunkel'; dunkel = 'auto' }[$script:themeSetting]
    Set-ThemeSetting $next
    Save-Tasks
    # Design wird beim Aufbau des Fensters gesetzt: Programm kurz neu starten
    Restart-DirToy
    $win.Close()
})
$ui.btnLog.Add_Click({
    if (Test-Path $script:logFile) { Start-Process notepad.exe -ArgumentList "`"$($script:logFile)`"" }
    else { [void](Show-Msg 'Es gibt noch kein Protokoll. Es entsteht beim ersten Sync-Lauf.' 'Protokoll') }
})
$ui.btnDirs.Add_Click({ if ($script:cur) { Show-FolderDialog $script:cur; Update-DirsButton } })
$ui.btnSched.Add_Click({ if ($script:cur) { Show-ScheduleDialog $script:cur; Update-SchedLabel } })
# Lauf starten; schlaegt schon der Start fehl, wird das Fenster wieder freigegeben
function Invoke-Run($tasks, [bool]$preview, [string]$doneText, [bool]$showResult) {
    if ($script:busy) { return }
    Clear-Log; Set-Busy $true
    try {
        Start-Flow $(if (@($tasks).Count -eq 1) { [int]@($tasks)[0].Mode } else { 0 }) $preview
        $ui.task.ProgressState = 'Normal'; $ui.task.ProgressValue = 0
        Start-SyncJob $tasks $preview $doneText $showResult
    }
    catch { $m = $_.Exception.Message; $script:job = $null; $script:brg = $null; Stop-Flow 'err'; $ui.task.ProgressState = 'None'; Set-Busy $false; [void](Show-Msg "Der Lauf konnte nicht gestartet werden:`n`n$m" 'DirToy' 'OK' 'Error') }
}
$ui.btnPrev.Add_Click({ if ($script:cur) { Invoke-Run @($script:cur) $true 'Vorschau fertig.' $false } })
$ui.btnRun.Add_Click({ if ($script:cur) { Invoke-Run @($script:cur) $false 'Fertig.' $true } })
$ui.btnAll.Add_Click({ Invoke-Run @($script:tasks) $false 'Alle Aufgaben abgearbeitet.' $true })
$ui.btnCancel.Add_Click({
    Request-Cancel; $ui.btnCancel.IsEnabled = $false; $ui.btnCancel.Content = 'Bricht ab ...'
    $ui.lblStatus.Text = 'Wird nach der aktuellen Datei abgebrochen ...'
})
$win.Add_Closing({
    param($s, $e)
    if ($script:busy) {
        $q = "Es läuft noch ein Vorgang.`nJetzt abbrechen und beenden?`n`nDas Programm beendet sich nach der aktuellen Datei. Es bleiben keine halben Dateien zurück."
        $e.Cancel = $true
        if ($script:asking) { return }
        $script:asking = $true   # solange die Frage offen ist, wird der Lauf nicht abgeschlossen
        try { if ((Show-Msg $q 'DirToy' 'YesNo' 'Question') -eq 'Yes') { Request-Cancel; $script:closeRequested = $true } }
        finally { $script:asking = $false }
    }
})

Refresh-List 0
$win.Add_ContentRendered({
    # Beim allerersten Start einmal anbieten, eine Desktop-Verknuepfung anzulegen (startet ohne aufblitzendes Fenster)
    if (-not [bool](Get-Setting 'ShortcutAsked' $false)) {
        Set-Setting 'ShortcutAsked' $true
        $lnkPath = Join-Path (Get-DesktopDir) 'DirToy.lnk'
        if (-not (Test-Path $lnkPath)) {
            $q = "Willkommen bei DirToy!`n`nSoll eine Verknüpfung mit Icon auf dem Desktop angelegt werden?`nDamit startet DirToy künftig ohne aufblitzendes Fenster.`n`n(Später jederzeit über Hilfe → Desktop-Verknüpfung.)"
            if ((Show-Msg $q 'DirToy' 'YesNo' 'Question') -eq 'Yes') {
                $made = New-DesktopShortcut
                if (-not $made) { [void](Show-Msg 'Die Verknüpfung konnte nicht angelegt werden.' 'DirToy' 'OK' 'Warning') }
            }
        }
    }
    # Zeitplaene pruefen: gespeichert, aber im Windows-Aufgabenplaner nicht vorhanden?
    $missing = @($script:tasks | Where-Object {
        ($_.SchedName -and -not (Get-SchedInfo $_)) -or ($_.Schedule -and -not $_.SchedName -and -not ($_.AutoLnk -and (Test-Path -LiteralPath ([string]$_.AutoLnk))))
    } | ForEach-Object { [string]$_.Name })
    if ($missing.Count -gt 0) {
        $q = "Für diese Aufgaben ist ein Zeitplan gespeichert, er ist aber im Windows-Aufgabenplaner nicht vorhanden. Sie laufen daher NICHT automatisch:`n`n  " + ($missing -join "`n  ") + "`n`nBitte die Aufgabe wählen und oben rechts den Zeitplan neu aktivieren. Falls das nicht geht, zeigt DirToy dort eine Anleitung zum manuellen Anlegen."
        [void](Show-Msg $q 'DirToy - Zeitplan' 'OK' 'Warning')
    }
    if ([bool](Get-Setting 'UpdateCheck' $true)) { Start-UpdateCheck $false }
    if ($script:tasks.Count -eq 0) { New-TaskNow }
})
[void]$win.ShowDialog()
Save-Tasks
