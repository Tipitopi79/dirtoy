function Update-DirsButton {
    if (-not $script:btnDirs) { return }
    $n = if ($script:cur) { @($script:cur.ExcludeDirs | Where-Object { $_ }).Count } else { 0 }
    $script:btnDirs.Text = $(if ($n -gt 0) { "Ordner wählen ($n)" } else { 'Ordner wählen ...' })
}
$editors = @($tbName, $tbA, $tbB, $cmb, $tbEx, $btnDirs, $btnPrev, $btnRun, $btnDel, $btnSched)

function Refresh-List([int]$select) {
    $script:loading = $true
    $lb.Items.Clear()
    foreach ($t in $script:tasks) { [void]$lb.Items.Add([string]$t.Name) }
    if ($select -ge 0 -and $select -lt $lb.Items.Count) { $lb.SelectedIndex = $select }
    $script:loading = $false
    Show-Cur
}
function Show-Cur {
    $i = $lb.SelectedIndex
    $script:loading = $true
    if ($i -ge 0) {
        $script:cur = $script:tasks[$i]
        $tbName.Text = [string]$script:cur.Name; $tbA.Text = [string]$script:cur.A; $tbB.Text = [string]$script:cur.B
        $mi = [int]$script:cur.Mode; if ($mi -lt 0 -or $mi -ge $cmb.Items.Count) { $mi = 0 }; $cmb.SelectedIndex = $mi; $tbEx.Text = [string]$script:cur.Exclude
    } else {
        $script:cur = $null
        $tbName.Text = ''; $tbA.Text = ''; $tbB.Text = ''; $cmb.SelectedIndex = -1; $tbEx.Text = ''
    }
    foreach ($c in $editors) { $c.Enabled = ($i -ge 0) }
    $btnA.Enabled = $btnB.Enabled = ($i -ge 0)
    $btnAll.Enabled = ($script:tasks.Count -gt 0)
    $script:loading = $false
    Update-SchedLabel
    Update-DirsButton
}
$script:busy = $false
$script:closeRequested = $false
function Set-Busy([bool]$busy) {
    $script:busy = $busy
    if ($busy) { $script:cancel = $false }
    foreach ($c in @($btnPrev, $btnRun, $btnAll, $btnNew, $btnDel, $btnSched, $btnDirs, $lb)) { $c.Enabled = -not $busy }
    $btnRun.Visible = -not $busy
    $btnCancel.Visible = $busy; $btnCancel.Enabled = $busy; $btnCancel.Text = 'Abbrechen'
    if (-not $busy) {
        Show-Cur
        if ($script:closeRequested) { $form.Close() }
    }
}

$lb.Add_SelectedIndexChanged({ if (-not $script:loading) { Show-Cur } })
$tbName.Add_TextChanged({
    if ($script:loading -or -not $script:cur) { return }
    $script:cur.Name = $tbName.Text
    $i = $lb.SelectedIndex
    $script:loading = $true; $lb.Items[$i] = $tbName.Text; $lb.SelectedIndex = $i; $script:loading = $false
    Save-Tasks
})
$tbA.Add_TextChanged({ if (-not $script:loading -and $script:cur) { $script:cur.A = $tbA.Text; Save-Tasks } })
$tbB.Add_TextChanged({ if (-not $script:loading -and $script:cur) { $script:cur.B = $tbB.Text; Save-Tasks } })
$tbEx.Add_TextChanged({ if (-not $script:loading -and $script:cur) { $script:cur.Exclude = $tbEx.Text; Save-Tasks } })
$cmb.Add_SelectedIndexChanged({ if (-not $script:loading -and $script:cur -and $cmb.SelectedIndex -ge 0) { $script:cur.Mode = $cmb.SelectedIndex; Save-Tasks } })

function Pick-Folder($tb) {
    $d = New-Object System.Windows.Forms.FolderBrowserDialog
    if ($tb.Text -and (Test-Path -LiteralPath $tb.Text)) { $d.SelectedPath = $tb.Text }
    if ($d.ShowDialog() -eq 'OK') { $tb.Text = $d.SelectedPath }
}
$btnA.Add_Click({ Pick-Folder $tbA })
$btnB.Add_Click({ Pick-Folder $tbB })

$btnNew.Add_Click({
    $t = New-Task ('Aufgabe ' + ($script:tasks.Count + 1))
    $script:tasks = @($script:tasks) + $t
    Save-Tasks; Refresh-List ($script:tasks.Count - 1); $tbName.Focus(); $tbName.SelectAll()
})
$btnDel.Add_Click({
    $i = $lb.SelectedIndex; if ($i -lt 0) { return }
    $t = $script:tasks[$i]
    if ((Show-Msg "Aufgabe '$($t.Name)' löschen?`n(Die Ordner und Dateien bleiben unverändert.)" 'Löschen' 'YesNo' 'Question') -ne 'Yes') { return }
    try { Unregister-Sched $t } catch { }
    $script:tasks = @($script:tasks | Where-Object { $_.Id -ne $t.Id })
    Remove-Item (Join-Path $script:stateDir "$($t.Id).json"), (Join-Path $script:stateDir "$($t.Id).state") -ErrorAction SilentlyContinue
    Save-Tasks; Refresh-List ([math]::Min($i, $script:tasks.Count - 1))
})

$btnHelp.Add_Click({ Show-Help })
$lblVer.Add_Click({ Start-UpdateCheck $true })
$btnUpd.Add_Click({ if ($script:updInfo) { Do-UpdateAction $script:updInfo (Show-UpdateDialog $script:updInfo 'new') } })
$btnTheme.Add_Click({
    if ($script:busy) { return }
    $next = @{ auto = 'hell'; hell = 'dunkel'; dunkel = 'auto' }[$script:themeSetting]
    Set-ThemeSetting $next
    Save-Tasks
    # Design wird beim Aufbau des Fensters gesetzt: Programm kurz neu starten
    Restart-DirToy

    $form.Close()
})
$btnLog.Add_Click({
    if (Test-Path $script:logFile) { Start-Process notepad.exe -ArgumentList "`"$($script:logFile)`"" }
    else { [void](Show-Msg 'Es gibt noch kein Protokoll. Es entsteht beim ersten Sync-Lauf.' 'Protokoll') }
})
$btnDirs.Add_Click({
    if (-not $script:cur) { return }
    Show-FolderDialog $script:cur; Update-DirsButton
})
$btnSched.Add_Click({
    if (-not $script:cur) { return }
    Show-ScheduleDialog $script:cur; Update-SchedLabel
})
# Lauf starten; schlaegt schon der Start fehl, wird das Fenster wieder freigegeben
function Invoke-Run($tasks, [bool]$preview, [string]$doneText, [bool]$showResult) {
    if ($script:busy) { return }
    Clear-Log; Set-Busy $true
    try { Start-SyncJob $tasks $preview $doneText $showResult }
    catch { $m = $_.Exception.Message; $script:job = $null; $script:brg = $null; Set-Busy $false; [void](Show-Msg "Der Lauf konnte nicht gestartet werden:`n`n$m" 'DirToy' 'OK' 'Error') }
}
$btnPrev.Add_Click({ if ($script:cur) { Invoke-Run @($script:cur) $true 'Vorschau fertig.' $false } })
$btnRun.Add_Click({ if ($script:cur) { Invoke-Run @($script:cur) $false 'Fertig.' $true } })
$btnAll.Add_Click({ Invoke-Run @($script:tasks) $false 'Alle Aufgaben abgearbeitet.' $true })
$btnCancel.Add_Click({
    Request-Cancel; $btnCancel.Enabled = $false; $btnCancel.Text = 'Bricht ab ...'
    $lbl.Text = 'Wird nach der aktuellen Datei abgebrochen ...'
})
$form.Add_FormClosing({
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
$form.Add_Shown({
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
        $q = "Für diese Aufgaben ist ein Zeitplan gespeichert, er ist aber im Windows-Aufgabenplaner nicht vorhanden. Sie laufen daher NICHT automatisch:`n`n  " + ($missing -join "`n  ") + "`n`nBitte die Aufgabe wählen und unter `"Zeitplan ...`" neu aktivieren. Falls das nicht geht, zeigt DirToy dort eine Anleitung zum manuellen Anlegen."
        [void](Show-Msg $q 'DirToy - Zeitplan' 'OK' 'Warning')
    }
    if ([bool](Get-Setting 'UpdateCheck' $true)) { Start-UpdateCheck $false }
    if ($script:tasks.Count -eq 0) { $btnNew.PerformClick() }
})
[void]$form.ShowDialog()
Save-Tasks
