param([switch]$NoGui, [string]$Task, [switch]$All)
# DirToy - grafisches Ordner-Synchronisationstool (Vorbild: SyncToy)
# Start: DirToy.bat (Doppelklick)

Add-Type -AssemblyName System.Windows.Forms, System.Drawing, Microsoft.VisualBasic
[System.Windows.Forms.Application]::EnableVisualStyles()
$ErrorActionPreference = 'Stop'

$script:errLog = Join-Path $PSScriptRoot 'DirToy-Daten\fehler.log'
trap {
    try {
        New-Item -ItemType Directory -Force -Path (Split-Path $script:errLog) | Out-Null
        Add-Content -Path $script:errLog -Value ("=== " + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + "`r`n" + ($_ | Out-String) + ($_.ScriptStackTrace)) -Encoding UTF8
    } catch { }
    if (-not $NoGui -and -not $Task -and -not $All) {
        [void][System.Windows.Forms.MessageBox]::Show("DirToy konnte nicht starten oder ist abgestürzt:`n`n$($_.Exception.Message)`n`nDetails stehen in:`n$($script:errLog)", 'DirToy', 'OK', 'Error')
    }
    exit 1
}
$script:version = '1.0.0'
$script:dataDir  = if ($env:DIRTOY_DATA) { $env:DIRTOY_DATA } else { Join-Path $PSScriptRoot 'DirToy-Daten' }
$script:stateDir = Join-Path $script:dataDir 'state'
$script:taskFile = Join-Path $script:dataDir 'aufgaben.json'
# Migration: Datenordner frueherer Namen -> DirToy-Daten
try {
    if (-not $env:DIRTOY_DATA -and -not (Test-Path $script:dataDir)) {
        foreach ($o in @('TwinSync-Daten', 'SyncTool-Daten')) {
            $old = Join-Path $PSScriptRoot $o
            if (Test-Path $old) { Rename-Item -Path $old -NewName 'DirToy-Daten'; break }
        }
    }
} catch { }New-Item -ItemType Directory -Force -Path $script:stateDir | Out-Null
$script:logFile = Join-Path $script:dataDir 'sync.log'
$script:logOn = $false
try { if ((Test-Path $script:logFile) -and (Get-Item $script:logFile).Length -gt 2MB) { Move-Item $script:logFile ($script:logFile + '.alt') -Force } } catch { }

$script:modes = @(
    'Synchronisieren  (A <-> B, neuere Datei gewinnt, Löschungen werden übernommen)',
    'Echo  (A -> B, B wird exakt wie A gemacht)',
    'Beitragen  (A -> B, es wird nichts gelöscht)'
)
$script:warn = New-Object System.Collections.Generic.List[string]
$script:tasks = @()
$script:cur = $null
$script:loading = $false
$script:lv = $null
$script:scriptPath = $PSCommandPath

# ---------------------------------------------------------------- Aufgaben speichern/laden
function Load-Tasks {
    $script:tasks = @()
    if (Test-Path $script:taskFile) {
        $raw = Get-Content $script:taskFile -Raw -Encoding UTF8
        try { if ($raw -and $raw.Trim()) { [void](ConvertFrom-Json $raw) } }
        catch {
            Copy-Item $script:taskFile ($script:taskFile + ".defekt-" + (Get-Date -Format yyyyMMdd-HHmmss)) -Force
            $raw = $null
        }
        if ($raw -and $raw.Trim()) { $items = ConvertFrom-Json $raw; $script:tasks = @(foreach ($it in $items) { $it })
        foreach ($t in $script:tasks) {
            foreach ($pn in @('Schedule', 'SchedName')) {
                if (-not $t.PSObject.Properties[$pn]) { Add-Member -InputObject $t -NotePropertyName $pn -NotePropertyValue $(if ($pn -eq 'SchedName') { '' } else { $null }) }
            }
        } }
    }
}
function Save-Tasks {
    $json = ConvertTo-Json -InputObject @($script:tasks) -Depth 4
    $tmp = $script:taskFile + ".tmp"
    Set-Content -Path $tmp -Value $json -Encoding UTF8
    Move-Item -Path $tmp -Destination $script:taskFile -Force
}
function New-Task([string]$name) {
    [pscustomobject]@{ Id = [guid]::NewGuid().ToString('N'); Name = $name; A = ''; B = ''; Mode = 0; Exclude = 'Thumbs.db;desktop.ini;~$*;*.tmp'; Schedule = $null; SchedName = '' }
}

# ---------------------------------------------------------------- Zustand (zum Erkennen von Löschungen)
function Get-State([string]$id) {
    $set = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $f = Join-Path $script:stateDir "$id.json"
    if (Test-Path $f) {
        $raw = Get-Content $f -Raw -Encoding UTF8
        if ($raw -and $raw.Trim()) { $items = ConvertFrom-Json $raw; foreach ($p in $items) { [void]$set.Add([string]$p) } }
    }
    return ,$set
}
function Save-State([string]$id, $keys) {
    $f = Join-Path $script:stateDir "$id.json"
    Set-Content -Path $f -Value (ConvertTo-Json -InputObject @($keys) -Depth 2) -Encoding UTF8
}

# ---------------------------------------------------------------- Scannen
function New-Dict { New-Object 'System.Collections.Generic.Dictionary[string,System.IO.FileInfo]' ([StringComparer]::OrdinalIgnoreCase) }
function Test-Excluded([string]$name, $pats) {
    foreach ($p in $pats) { if ($name -like $p) { return $true } }
    return $false
}
function Scan-Dir([System.IO.DirectoryInfo]$dir, [string]$rel, $pats, $dict) {
    try { $entries = $dir.GetFileSystemInfos() }
    catch { $script:warn.Add("$($dir.FullName): $($_.Exception.Message)"); return }
    foreach ($e in $entries) {
        if (Test-Excluded $e.Name $pats) { continue }
        if ($e -is [System.IO.DirectoryInfo]) {
            if ($e.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { continue }
            Scan-Dir $e ($rel + $e.Name + '\') $pats $dict
        } else {
            $dict[$rel + $e.Name] = $e
        }
    }
}
function Get-Patterns($t) { @(([string]$t.Exclude) -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }

# ---------------------------------------------------------------- Plan erstellen
function Build-Plan($t) {
    if (-not $t.A -or -not $t.B) { throw 'Bitte Ordner A und Ordner B angeben.' }
    $rootA = [System.IO.Path]::GetFullPath($t.A).TrimEnd('\')
    $rootB = [System.IO.Path]::GetFullPath($t.B).TrimEnd('\')
    if (-not (Test-Path -LiteralPath $rootA -PathType Container)) { throw "Ordner A existiert nicht: $rootA" }
    if (-not (Test-Path -LiteralPath $rootB -PathType Container)) { throw "Ordner B existiert nicht: $rootB" }
    if ($rootA -ieq $rootB -or $rootB.StartsWith($rootA + '\', 'OrdinalIgnoreCase') -or $rootA.StartsWith($rootB + '\', 'OrdinalIgnoreCase')) {
        throw 'Die Ordner dürfen nicht identisch sein oder ineinander liegen.'
    }
    $pats = Get-Patterns $t
    $da = New-Dict; $db = New-Dict
    Scan-Dir (New-Object System.IO.DirectoryInfo $rootA) '' $pats $da
    Scan-Dir (New-Object System.IO.DirectoryInfo $rootB) '' $pats $db
    $state = Get-State $t.Id
    $mode = [int]$t.Mode

    $keys = New-Object 'System.Collections.Generic.SortedSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($k in $da.Keys) { [void]$keys.Add($k) }
    foreach ($k in $db.Keys) { [void]$keys.Add($k) }

    $plan = New-Object System.Collections.Generic.List[object]
    function Add-Item($typ, $text, $rel, $src, $dst) {
        $plan.Add([pscustomobject]@{ Typ = $typ; Text = $text; Rel = $rel; Src = $src; Dst = $dst })
    }
    foreach ($rel in $keys) {
        $fa = $null; $fb = $null
        $inA = $da.TryGetValue($rel, [ref]$fa)
        $inB = $db.TryGetValue($rel, [ref]$fb)
        $pa = Join-Path $rootA $rel; $pb = Join-Path $rootB $rel
        if ($inA -and $inB) {
            $dt = ($fa.LastWriteTimeUtc - $fb.LastWriteTimeUtc).TotalSeconds
            $differs = ([math]::Abs($dt) -gt 2) -or ($fa.Length -ne $fb.Length)
            if (-not $differs) { continue }
            switch ($mode) {
                0 {
                    if ($dt -gt 2)       { Add-Item 'Copy' 'A -> B aktualisieren' $rel $pa $pb }
                    elseif ($dt -lt -2)  { Add-Item 'Copy' 'B -> A aktualisieren' $rel $pb $pa }
                    else                 { Add-Item 'Conflict' 'Konflikt (gleiche Zeit, andere Größe) - übersprungen' $rel $null $null }
                }
                1 { Add-Item 'Copy' 'A -> B aktualisieren' $rel $pa $pb }
                2 {
                    if ($dt -gt 2 -or ([math]::Abs($dt) -le 2 -and $fa.Length -ne $fb.Length)) { Add-Item 'Copy' 'A -> B aktualisieren' $rel $pa $pb }
                }
            }
        }
        elseif ($inA) {
            if ($mode -eq 0 -and $state.Contains($rel)) { Add-Item 'Delete' 'In A löschen (in B gelöscht)' $rel $pa $null }
            else { Add-Item 'Copy' 'A -> B kopieren' $rel $pa $pb }
        }
        else {
            switch ($mode) {
                0 { if ($state.Contains($rel)) { Add-Item 'Delete' 'In B löschen (in A gelöscht)' $rel $pb $null }
                    else { Add-Item 'Copy' 'B -> A kopieren' $rel $pb $pa } }
                1 { Add-Item 'Delete' 'In B löschen (nicht in A vorhanden)' $rel $pb $null }
                2 { }
            }
        }
    }
    return [pscustomobject]@{ Plan = $plan; A = $rootA; B = $rootB; Pats = $pats }
}

# ---------------------------------------------------------------- Plan ausführen
function Copy-One($src, $dst) {
    $dir = [System.IO.Path]::GetDirectoryName($dst)
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    if (Test-Path -LiteralPath $dst) { [System.IO.File]::SetAttributes($dst, [System.IO.FileAttributes]::Normal) }
    [System.IO.File]::Copy($src, $dst, $true)
    [System.IO.File]::SetLastWriteTimeUtc($dst, [System.IO.File]::GetLastWriteTimeUtc($src))
}
function Delete-One($path) {
    [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($path, 'OnlyErrorDialogs', 'SendToRecycleBin')
}
function Update-State($t, $r) {
    $da = New-Dict; $db = New-Dict
    Scan-Dir (New-Object System.IO.DirectoryInfo $r.A) '' $r.Pats $da
    Scan-Dir (New-Object System.IO.DirectoryInfo $r.B) '' $r.Pats $db
    $both = @($da.Keys | Where-Object { $db.ContainsKey($_) })
    Save-State $t.Id $both
}

# ---------------------------------------------------------------- Log-Ausgabe
function Write-LogLine([string]$aktion, [string]$datei, [string]$status) {
    try { Add-Content -Path $script:logFile -Value ((Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' | ' + $aktion + ' | ' + $datei + ' | ' + $status) -Encoding UTF8 } catch { }
}
function Set-Progress([double]$frac) {
    if (-not $script:progFill) { return }
    $w = [int]($script:progTrack.Width * [math]::Max(0, [math]::Min(1, $frac)))
    $script:progFill.Width = $w
}
function Add-Log([string]$aktion, [string]$datei, [string]$status) {
    if ($script:logOn -and $status -ne '...') { Write-LogLine $aktion $datei $status }
    if ($script:lv) {
        $it = New-Object System.Windows.Forms.ListViewItem($aktion)
        [void]$it.SubItems.Add($datei); [void]$it.SubItems.Add($status)
        $c = Get-StatusColor $status; if ($c) { $it.ForeColor = $c }
        [void]$script:lv.Items.Add($it)
        $it.EnsureVisible()
        return $it
    } else {
        Write-Host "$aktion | $datei | $status"
        return $null
    }
}
function Pump { if (-not $NoGui) { [System.Windows.Forms.Application]::DoEvents() } }

function Run-Task($t, [bool]$preview) {
    $script:warn.Clear()
    $script:logOn = (-not $preview)
    if (-not $preview) { Write-LogLine ("=== Aufgabe '" + $t.Name + "' (" + $(if ($script:headless) { 'automatisch' } else { 'manuell' }) + ', DirToy ' + $script:version + ')') '' '' }
    Set-Progress 0
    if ($script:lblStatus) { $script:lblStatus.Text = "Analysiere '$($t.Name)' ..." }
    Pump
    try { $r = Build-Plan $t }
    catch { [void](Add-Log "Aufgabe '$($t.Name)'" '' "FEHLER: $($_.Exception.Message)"); return $null }
    foreach ($w in $script:warn) { [void](Add-Log 'Warnung' $w 'übersprungen') }
    $plan = $r.Plan
    $dels = @($plan | Where-Object { $_.Typ -eq 'Delete' }).Count
    if ($plan.Count -eq 0) { if (-not $preview) { try { Update-State $t $r } catch { } }; [void](Add-Log "Aufgabe '$($t.Name)'" 'Bereits synchron - nichts zu tun.' ''); return @{ Copied = 0; Deleted = 0; Errors = 0 } }

    if ($preview) {
        foreach ($p in $plan) { [void](Add-Log $p.Text $p.Rel 'geplant') }
        [void](Add-Log "Aufgabe '$($t.Name)'" "Vorschau: $($plan.Count) Aktion(en), davon $dels Löschung(en)" '')
        return $null
    }
    if ($dels -gt 0 -and -not $NoGui) {
        $ans = [System.Windows.Forms.MessageBox]::Show(
            "Aufgabe '$($t.Name)': $dels Datei(en) werden gelöscht (Papierkorb, sofern möglich).`nFortfahren?",
            'Löschen bestätigen', 'YesNo', 'Warning')
        if ($ans -ne 'Yes') { [void](Add-Log "Aufgabe '$($t.Name)'" '' 'Abgebrochen.'); return $null }
    }
    $copied = 0; $deleted = 0; $errors = 0; $i = 0
    foreach ($p in $plan) {
        $i++
        if ($script:lblStatus) { $script:lblStatus.Text = "'$($t.Name)': $i / $($plan.Count)  ($([int](100 * $i / $plan.Count)) %)" }
        Set-Progress ($i / $plan.Count)
        $it = Add-Log $p.Text $p.Rel '...'
        try {
            switch ($p.Typ) {
                'Copy'     { Copy-One $p.Src $p.Dst; $copied++ }
                'Delete'   { Delete-One $p.Src; $deleted++ }
                'Conflict' { }
            }
            $st = if ($p.Typ -eq 'Conflict') { 'übersprungen' } else { 'OK' }
            if ($script:logOn) { Write-LogLine $p.Text $p.Rel $st }
            if ($it) { $it.SubItems[2].Text = $st; $it.ForeColor = (Get-StatusColor $st) }
        } catch {
            $errors++
            if ($script:logOn) { Write-LogLine $p.Text $p.Rel ("FEHLER: " + $_.Exception.Message) }
            if ($it) { $it.SubItems[2].Text = "FEHLER: $($_.Exception.Message)"; $it.ForeColor = (Get-StatusColor 'FEHLER') }
        }
        if ($i % 10 -eq 0) { Pump }
    }
    if ($errors -eq 0) { try { Update-State $t $r } catch { [void](Add-Log 'Warnung' 'Zustand konnte nicht gespeichert werden' $_.Exception.Message) } }
    Set-Progress 1
    [void](Add-Log "Aufgabe '$($t.Name)' fertig" "$copied kopiert, $deleted gelöscht, $errors Fehler" '')
    return @{ Copied = $copied; Deleted = $deleted; Errors = $errors }
}

# ---------------------------------------------------------------- Aufgabenplaner
$script:schedPath = '\DirToy\'
function Get-SchedText($s) {
    if (-not $s) { return 'Kein Zeitplan' }
    $dn = @{ Monday='Mo'; Tuesday='Di'; Wednesday='Mi'; Thursday='Do'; Friday='Fr'; Saturday='Sa'; Sunday='So' }
    switch ([int]$s.Type) {
        0 { "täglich um $($s.Time)" }
        1 { 'wöchentlich ' + ((@($s.Days) | ForEach-Object { $dn[[string]$_] }) -join ',') + " um $($s.Time)" }
        2 { "alle $($s.Minutes) Minuten" }
        3 { 'bei Anmeldung' }
    }
}
function Get-SchedInfo($t) {
    if (-not $t.SchedName) { return $null }
    try {
        $st = Get-ScheduledTask -TaskPath $script:schedPath -TaskName $t.SchedName -ErrorAction Stop
        $i = $st | Get-ScheduledTaskInfo
        return [pscustomobject]@{ State = $st.State; Next = $i.NextRunTime; Last = $i.LastRunTime; Result = $i.LastTaskResult }
    } catch { return $null }
}
function Unregister-Sched($t) {
    if ($t.SchedName) {
        Unregister-ScheduledTask -TaskPath $script:schedPath -TaskName $t.SchedName -Confirm:$false -ErrorAction SilentlyContinue
    }
    $t.SchedName = ''
}
function Register-Sched($t) {
    $s = $t.Schedule
    $name = 'DirToy - ' + (([string]$t.Name -replace '[\\/:*?"<>|]', '_').Trim())
    if ($t.SchedName -and $t.SchedName -ne $name) {
        Unregister-ScheduledTask -TaskPath $script:schedPath -TaskName $t.SchedName -Confirm:$false -ErrorAction SilentlyContinue
    }
    $user = "$env:USERDOMAIN\$env:USERNAME"
    $arg = "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$($script:scriptPath)`" -Task `"$($t.Id)`""
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arg
    $hm = ([string]$s.Time).Split(':')
    $at = [datetime]::Today.AddHours([int]$hm[0]).AddMinutes([int]$hm[1])
    switch ([int]$s.Type) {
        0 { $trg = New-ScheduledTaskTrigger -Daily -At $at }
        1 { $trg = New-ScheduledTaskTrigger -Weekly -DaysOfWeek ([string[]]@($s.Days)) -At $at }
        2 { $trg = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes ([int]$s.Minutes)) -RepetitionDuration (New-TimeSpan -Days 3650) }
        3 { $trg = New-ScheduledTaskTrigger -AtLogOn -User $user }
    }
    $set = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 12)
    $pri = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
    [void](Register-ScheduledTask -TaskName $name -TaskPath $script:schedPath -Action $action -Trigger $trg -Settings $set -Principal $pri -Description "DirToy: $($t.Name)" -Force)
    $t.SchedName = $name
}
function Send-Notify([string]$title, [string]$text, [bool]$isError) {
    try {
        Add-Type -AssemblyName System.Windows.Forms, System.Drawing
        if ($text.Length -gt 250) { $text = $text.Substring(0, 247) + '...' }
        $ni = New-Object System.Windows.Forms.NotifyIcon
        $ni.Icon = [System.Drawing.SystemIcons]::Application
        $ni.Visible = $true
        $ni.BalloonTipTitle = $title; $ni.BalloonTipText = $text
        $ni.BalloonTipIcon = $(if ($isError) { 'Error' } else { 'Info' })
        $ni.ShowBalloonTip(10000)
        $end = (Get-Date).AddSeconds(9)
        while ((Get-Date) -lt $end) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 100 }
        $ni.Visible = $false; $ni.Dispose()
    } catch { }
}
if ($Task -or $All) {
    # Headless-Modus fuer den Windows-Aufgabenplaner
    $NoGui = $true
    $script:headless = $true
    $script:logOn = $true
    Load-Tasks
    $sel = @($script:tasks | Where-Object { $All -or $_.Name -ieq $Task -or $_.Id -eq $Task })
    if ($sel.Count -eq 0) { [void](Add-Log 'FEHLER' '' "Aufgabe nicht gefunden: $Task"); exit 2 }
    $bad = 0; $msgs = New-Object System.Collections.Generic.List[string]
    foreach ($t in $sel) {
        $r = Run-Task $t $false
        $nm = if ($t.Schedule -and $null -ne $t.Schedule.Notify) { [int]$t.Schedule.Notify } else { 1 }
        if ($null -eq $r) { $bad++; if ($nm -ge 1) { $msgs.Add("$($t.Name): FEHLER (siehe Protokoll)") } }
        elseif ($r.Errors -gt 0) { $bad++; if ($nm -ge 1) { $msgs.Add("$($t.Name): $($r.Errors) Fehler, $($r.Copied) kopiert, $($r.Deleted) gelöscht") } }
        elseif ($nm -eq 1 -and ($r.Copied + $r.Deleted) -gt 0) { $msgs.Add("$($t.Name): $($r.Copied) kopiert, $($r.Deleted) gelöscht") }
    }
    if ($msgs.Count -gt 0) { Send-Notify $(if ($bad) { 'DirToy - Fehler' } else { 'DirToy - fertig' }) ($msgs -join "`n") ([bool]$bad) }
    exit $(if ($bad) { 1 } else { 0 })
}
if ($NoGui) { return }

# ================================================================ GUI
Load-Tasks

# ---- Theme (folgt dem Windows-Hell/Dunkel-Modus)
function C([string]$hex) { [System.Drawing.ColorTranslator]::FromHtml($hex) }
$isDark = $false
try { $isDark = ((Get-ItemPropertyValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name AppsUseLightTheme) -eq 0) } catch { }
if ($isDark) {
    $script:th = @{ Bg = (C '#202020'); Surface = (C '#2B2B2B'); Input = (C '#1C1C1C'); Text = (C '#F2F2F2'); Muted = (C '#A6A6A6')
        Border = (C '#454545'); Accent = (C '#4CC2FF'); AccentText = (C '#000000'); AccentHover = (C '#7AD2FF'); SelBg = (C '#3A3A3A')
        Ok = (C '#6CCB5F'); Err = (C '#FF99A4') }
} else {
    $script:th = @{ Bg = (C '#F3F3F3'); Surface = (C '#FFFFFF'); Input = (C '#FFFFFF'); Text = (C '#1B1B1B'); Muted = (C '#6B6B6B')
        Border = (C '#D6D6D6'); Accent = (C '#0067C0'); AccentText = (C '#FFFFFF'); AccentHover = (C '#1A7FD6'); SelBg = (C '#E5F1FB')
        Ok = (C '#0F7B0F'); Err = (C '#C42B1C') }
}
$th = $script:th
function Get-StatusColor([string]$st) {
    if (-not $script:th) { return $null }
    if ($st -like 'FEHLER*') { return $script:th.Err }
    if ($st -eq 'OK') { return $script:th.Ok }
    if ($st -eq 'geplant' -or $st -eq 'übersprungen') { return $script:th.Muted }
    return $script:th.Text
}

$fNormal = New-Object System.Drawing.Font('Segoe UI', 10)
$fSmall  = New-Object System.Drawing.Font('Segoe UI', 9)
$fBold   = New-Object System.Drawing.Font('Segoe UI Semibold', 10)
$fTitle  = New-Object System.Drawing.Font('Segoe UI Semibold', 18)

$form = New-Object System.Windows.Forms.Form
$form.Text = "DirToy $($script:version)"; $form.ClientSize = New-Object System.Drawing.Size(1080, 720); $form.MinimumSize = New-Object System.Drawing.Size(1090, 640)
$form.StartPosition = 'CenterScreen'; $form.Font = $fNormal; $form.BackColor = $th.Bg; $form.ForeColor = $th.Text

$AN = [System.Windows.Forms.AnchorStyles]
$A_TL = $AN::Top -bor $AN::Left; $A_TLR = $A_TL -bor $AN::Right; $A_TR = $AN::Top -bor $AN::Right
$A_TLB = $A_TL -bor $AN::Bottom; $A_BL = $AN::Bottom -bor $AN::Left; $A_BR = $AN::Bottom -bor $AN::Right; $A_BLR = $A_BL -bor $AN::Right; $A_ALL = $A_TLR -bor $AN::Bottom

function Add-To($parent, $c, $x, $y, $w, $h) {
    $c.Location = New-Object System.Drawing.Point($x, $y)
    if ($w -gt 0) { $c.Size = New-Object System.Drawing.Size($w, $h) }
    $parent.Controls.Add($c); return $c
}
function New-Label($parent, $x, $y, $w, $text, $muted) {
    $l = New-Object System.Windows.Forms.Label; $l.Text = $text; $l.AutoSize = $false; $l.Height = 20
    $l.BackColor = [System.Drawing.Color]::Transparent
    $l.Font = if ($muted) { $fSmall } else { $fNormal }
    $l.ForeColor = if ($muted) { $th.Muted } else { $th.Text }
    Add-To $parent $l $x $y $w 20
}
function New-Input($parent, $x, $y, $w) {
    $t = New-Object System.Windows.Forms.TextBox; $t.BorderStyle = 'FixedSingle'
    $t.BackColor = $th.Input; $t.ForeColor = $th.Text; $t.Font = $fNormal
    Add-To $parent $t $x $y $w 28
}
function New-Btn($parent, $x, $y, $w, $h, $text, [bool]$primary, $fill) {
    $b = New-Object System.Windows.Forms.Button; $b.Text = $text; $b.FlatStyle = 'Flat'; $b.Cursor = 'Hand'
    $b.UseVisualStyleBackColor = $false; $b.Font = $fBold
    if ($primary) {
        $b.BackColor = $th.Accent; $b.ForeColor = $th.AccentText
        $b.FlatAppearance.BorderSize = 0; $b.FlatAppearance.MouseOverBackColor = $th.AccentHover; $b.FlatAppearance.MouseDownBackColor = $th.AccentHover
    } else {
        $b.BackColor = $fill; $b.ForeColor = $th.Text
        $b.FlatAppearance.BorderSize = 1; $b.FlatAppearance.BorderColor = $th.Border
        $b.FlatAppearance.MouseOverBackColor = $th.SelBg; $b.FlatAppearance.MouseDownBackColor = $th.SelBg
    }
    Add-To $parent $b $x $y $w $h
}
function New-Card($parent, $x, $y, $w, $h) {
    $p = New-Object System.Windows.Forms.Panel; $p.BackColor = $th.Surface
    Add-To $parent $p $x $y $w $h
}

# ---- Seitenleiste
$side = New-Object System.Windows.Forms.Panel; $side.Dock = 'Left'; $side.Width = 270; $side.BackColor = $th.Surface
$form.Controls.Add($side)
$lt = New-Object System.Windows.Forms.Label; $lt.Text = 'DirToy'; $lt.Font = $fTitle; $lt.ForeColor = $th.Accent; $lt.AutoSize = $true
[void](Add-To $side $lt 18 16 0 0)
[void](New-Label $side 20 62 230 'Ordner synchron halten' $true)
[void](New-Label $side 20 80 230 "Version $($script:version)" $true)
[void](New-Label $side 20 110 230 'AUFGABEN' $true)
$lb = New-Object System.Windows.Forms.ListBox
$lb.BorderStyle = 'None'; $lb.BackColor = $th.Surface; $lb.ForeColor = $th.Text; $lb.DrawMode = 'OwnerDrawFixed'; $lb.ItemHeight = 38
[void](Add-To $side $lb 0 134 270 470); $lb.Anchor = $A_TLB
$btnNew = New-Btn $side 16 664 112 38 '+ Neu' $false $th.Surface
$btnDel = New-Btn $side 140 664 112 38 'Löschen' $false $th.Surface
$btnNew.Anchor = $A_BL; $btnDel.Anchor = $A_BL
$btnHelp = New-Btn $side 16 618 236 36 'Hilfe' $false $th.Surface; $btnHelp.Anchor = $A_BL
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
$tbEx = New-Input $card 20 272 $iw; $tbEx.Anchor = $A_TLR

$btnPrev = New-Btn $main 20 340 130 40 'Vorschau' $false $th.Bg
$btnRun  = New-Btn $main 160 340 170 40 'Synchronisieren' $true $null
$btnAll  = New-Btn $main 340 340 200 40 'Alle Aufgaben ausführen' $false $th.Bg
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
$lv.View = 'Details'; $lv.FullRowSelect = $true; $lv.BorderStyle = 'None'; $lv.HeaderStyle = 'Nonclickable'
$lv.BackColor = $th.Surface; $lv.ForeColor = $th.Text; $lv.Font = $fSmall; $lv.OwnerDraw = $true
[void]$lv.Columns.Add('Aktion', 250); [void]$lv.Columns.Add('Datei', 330); [void]$lv.Columns.Add('Status', 180)
$il = New-Object System.Windows.Forms.ImageList; $il.ImageSize = New-Object System.Drawing.Size(1, 30); $lv.SmallImageList = $il
[void](Add-To $logCard $lv 0 0 $cw 264); $lv.Dock = 'Fill'
$script:lv = $lv
$lv.Add_DrawColumnHeader({
    param($s, $e)
    $br = New-Object System.Drawing.SolidBrush($script:th.Surface); $e.Graphics.FillRectangle($br, $e.Bounds); $br.Dispose()
    $pen = New-Object System.Drawing.Pen($script:th.Border)
    $e.Graphics.DrawLine($pen, $e.Bounds.Left, $e.Bounds.Bottom - 1, $e.Bounds.Right, $e.Bounds.Bottom - 1); $pen.Dispose()
    $r = New-Object System.Drawing.Rectangle(($e.Bounds.X + 12), $e.Bounds.Y, ($e.Bounds.Width - 14), $e.Bounds.Height)
    $fl = [System.Windows.Forms.TextFormatFlags]::VerticalCenter -bor [System.Windows.Forms.TextFormatFlags]::Left
    [System.Windows.Forms.TextRenderer]::DrawText($e.Graphics, $e.Header.Text.ToUpper(), $s.Font, $r, $script:th.Muted, $fl)
})
$lv.Add_DrawItem({ param($s, $e) })
$lv.Add_DrawSubItem({
    param($s, $e)
    $bg = if ($e.Item.Selected) { $script:th.SelBg } else { $script:th.Surface }
    $br = New-Object System.Drawing.SolidBrush($bg); $e.Graphics.FillRectangle($br, $e.Bounds); $br.Dispose()
    $r = New-Object System.Drawing.Rectangle(($e.Bounds.X + 12), $e.Bounds.Y, ($e.Bounds.Width - 14), $e.Bounds.Height)
    $col = if ($e.ColumnIndex -eq 2) { $e.Item.ForeColor } else { $script:th.Text }
    $fl = [System.Windows.Forms.TextFormatFlags]::VerticalCenter -bor [System.Windows.Forms.TextFormatFlags]::EndEllipsis -bor [System.Windows.Forms.TextFormatFlags]::Left -bor [System.Windows.Forms.TextFormatFlags]::NoPrefix
    [System.Windows.Forms.TextRenderer]::DrawText($e.Graphics, $e.SubItem.Text, $s.Font, $r, $col, $fl)
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
$tip.SetToolTip($btnSched, 'Automatische Ausführung im Windows-Aufgabenplaner anlegen, ändern oder entfernen.')
$tip.SetToolTip($btnLog, 'Öffnet das Protokoll aller bisherigen Läufe (sync.log).')
$tip.SetToolTip($btnNew, 'Neue Sync-Aufgabe anlegen.')
$tip.SetToolTip($btnDel, 'Gewählte Aufgabe löschen (Dateien bleiben unverändert, ein Zeitplan wird mit entfernt).')
$tip.SetToolTip($btnHelp, 'Anleitung zum Tool.')
$tip.SetToolTip($tbEx, 'Mit ; getrennt. Platzhalter * und ? erlaubt. Gilt für Dateien und Ordnernamen in beiden Ordnern.')

# Dunkle Titelleiste
try {
    Add-Type -Namespace Win32 -Name Dwm -MemberDefinition '[System.Runtime.InteropServices.DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(System.IntPtr hwnd, int attr, ref int val, int size);'
} catch { }
$form.Add_HandleCreated({
    try { $v = if ($isDark) { 1 } else { 0 }; [void][Win32.Dwm]::DwmSetWindowAttribute($form.Handle, 20, [ref]$v, 4) } catch { }
})

# ---- Zeitplan-Dialog
function Show-ScheduleDialog($t) {
    $d = New-Object System.Windows.Forms.Form
    $d.Text = 'Zeitplan'; $d.ClientSize = New-Object System.Drawing.Size(470, 410); $d.StartPosition = 'CenterParent'
    $d.FormBorderStyle = 'FixedDialog'; $d.MaximizeBox = $false; $d.MinimizeBox = $false; $d.ShowInTaskbar = $false
    $d.BackColor = $th.Surface; $d.ForeColor = $th.Text; $d.Font = $fNormal
    $h = New-Object System.Windows.Forms.Label; $h.Text = "Zeitplan für  '$($t.Name)'"; $h.Font = $fBold; $h.AutoSize = $false; $h.TextAlign = 'MiddleLeft'
    [void](Add-To $d $h 20 14 430 28)
    [void](New-Label $d 20 52 300 'Wann ausführen?' $true)
    $script:dType = New-Object System.Windows.Forms.ComboBox; $script:dType.DropDownStyle = 'DropDownList'; $script:dType.FlatStyle = 'Flat'
    $script:dType.BackColor = $th.Input; $script:dType.ForeColor = $th.Text
    foreach ($x in @('Täglich', 'Wöchentlich', 'Wiederholt (alle X Minuten)', 'Bei Windows-Anmeldung')) { [void]$script:dType.Items.Add($x) }
    [void](Add-To $d $script:dType 20 74 430 28)
    $script:dLblTime = New-Label $d 20 114 200 'Uhrzeit' $true
    $script:dTime = New-Object System.Windows.Forms.DateTimePicker; $script:dTime.Format = 'Custom'; $script:dTime.CustomFormat = 'HH:mm'; $script:dTime.ShowUpDown = $true
    [void](Add-To $d $script:dTime 20 136 120 28)
    $script:dLblMin = New-Label $d 20 114 200 'Intervall in Minuten' $true
    $script:dMin = New-Object System.Windows.Forms.NumericUpDown; $script:dMin.Minimum = 1; $script:dMin.Maximum = 1440; $script:dMin.Value = 60
    $script:dMin.BackColor = $th.Input; $script:dMin.ForeColor = $th.Text
    [void](Add-To $d $script:dMin 20 136 120 28)
    $script:dLblDays = New-Label $d 20 178 300 'Wochentage' $true
    $script:dDays = @(); $names = @('Mo', 'Di', 'Mi', 'Do', 'Fr', 'Sa', 'So'); $en = @('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday')
    for ($k = 0; $k -lt 7; $k++) {
        $cb = New-Object System.Windows.Forms.CheckBox; $cb.Text = $names[$k]; $cb.Tag = $en[$k]; $cb.AutoSize = $false; $cb.ForeColor = $th.Text
        [void](Add-To $d $cb (20 + $k * 60) 200 58 26); $script:dDays += $cb
    }
    [void](New-Label $d 20 238 430 'Windows-Meldung nach dem Lauf' $true)
    $script:dNotify = New-Object System.Windows.Forms.ComboBox; $script:dNotify.DropDownStyle = 'DropDownList'; $script:dNotify.FlatStyle = 'Flat'
    $script:dNotify.BackColor = $th.Input; $script:dNotify.ForeColor = $th.Text
    foreach ($x in @('Keine Meldung', 'Wenn etwas synchronisiert wurde oder Fehler auftraten', 'Nur bei Fehlern')) { [void]$script:dNotify.Items.Add($x) }
    [void](Add-To $d $script:dNotify 20 260 430 28)
    $info = New-Label $d 20 304 430 'Die Aufgabe läuft im Hintergrund, solange du angemeldet bist. Verpasste Läufe werden nachgeholt.' $true
    $info.Height = 36
    $script:dSave = New-Btn $d 20 356 140 34 'Aktivieren' $true $null
    $script:dRemove = New-Btn $d 170 356 160 34 'Zeitplan entfernen' $false $th.Surface
    $script:dCancel = New-Btn $d 340 356 110 34 'Abbrechen' $false $th.Surface
    $script:dTask = $t

    # vorhandene Werte laden
    $sc = $t.Schedule
    $script:dType.SelectedIndex = if ($sc) { [int]$sc.Type } else { 0 }
    $script:dNotify.SelectedIndex = if ($sc -and $null -ne $sc.Notify) { [int]$sc.Notify } else { 1 }
    if ($sc) {
        try { $hm = ([string]$sc.Time).Split(':'); $script:dTime.Value = [datetime]::Today.AddHours([int]$hm[0]).AddMinutes([int]$hm[1]) } catch { }
        if ($sc.Minutes) { $script:dMin.Value = [int]$sc.Minutes }
        foreach ($cb in $script:dDays) { $cb.Checked = (@($sc.Days) -contains $cb.Tag) }
    } else { $script:dTime.Value = [datetime]::Today.AddHours(22); foreach ($cb in $script:dDays) { $cb.Checked = ($cb.Tag -notin @('Saturday', 'Sunday')) } }
    $script:dRemove.Enabled = [bool]$t.SchedName
    if ($t.SchedName) { $script:dSave.Text = 'Speichern' }

    $script:dType.Add_SelectedIndexChanged({
        $ty = $script:dType.SelectedIndex
        $script:dLblTime.Visible = $script:dTime.Visible = ($ty -le 1)
        $script:dLblMin.Visible = $script:dMin.Visible = ($ty -eq 2)
        $script:dLblDays.Visible = ($ty -eq 1); foreach ($cb in $script:dDays) { $cb.Visible = ($ty -eq 1) }
    })
    $script:dType.SelectedIndex = -1; $script:dType.SelectedIndex = if ($sc) { [int]$sc.Type } else { 0 }

    $script:dSave.Add_Click({
        $ty = $script:dType.SelectedIndex
        $days = @($script:dDays | Where-Object { $_.Checked } | ForEach-Object { [string]$_.Tag })
        if ($ty -eq 1 -and $days.Count -eq 0) { [void][System.Windows.Forms.MessageBox]::Show('Bitte mindestens einen Wochentag wählen.', 'Zeitplan'); return }
        $tt = $script:dTask
        $tt.Schedule = [pscustomobject]@{ Type = $ty; Time = $script:dTime.Value.ToString('HH:mm'); Days = $days; Minutes = [int]$script:dMin.Value; Notify = $script:dNotify.SelectedIndex }
        try { Register-Sched $tt; Save-Tasks; $script:dSave.FindForm().DialogResult = 'OK' }
        catch { [void][System.Windows.Forms.MessageBox]::Show("Der Zeitplan konnte nicht angelegt werden:`n$($_.Exception.Message)", 'Fehler', 'OK', 'Error') }
    })
    $script:dRemove.Add_Click({
        $tt = $script:dTask
        try { Unregister-Sched $tt; $tt.Schedule = $null; Save-Tasks; $script:dSave.FindForm().DialogResult = 'OK' }
        catch { [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Fehler', 'OK', 'Error') }
    })
    $script:dCancel.Add_Click({ $script:dSave.FindForm().DialogResult = 'Cancel' })
    $d.Add_HandleCreated({
        try { $v = if ($isDark) { 1 } else { 0 }; [void][Win32.Dwm]::DwmSetWindowAttribute($script:dSave.FindForm().Handle, 20, [ref]$v, 4) } catch { }
    })
    [void]$d.ShowDialog($form)
    $d.Dispose()
}
function Update-SchedLabel {
    if (-not $script:lblSched) { return }
    $t = $script:cur
    if (-not $t) { $script:lblSched.Text = ''; return }
    $info = Get-SchedInfo $t
    if ($info) {
        $n = if ($info.Next -and $info.Next.Year -gt 2000) { '  ·  nächster Lauf ' + $info.Next.ToString('dd.MM. HH:mm') } else { '' }
        $script:lblSched.Text = 'Zeitplan: ' + (Get-SchedText $t.Schedule) + $n
    } elseif ($t.SchedName) { $script:lblSched.Text = 'Zeitplan im Aufgabenplaner nicht mehr vorhanden' }
    else { $script:lblSched.Text = 'Kein Zeitplan' }
}
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
    HelpH 'Löschen und Sicherheit'
    HelpP 'Vor dem Löschen fragt das Tool nach. Gelöscht wird in den Papierkorb, bei Netzlaufwerken ohne Papierkorb aber endgültig. Schau dir deshalb bei "Synchronisieren" und "Echo" zuerst die Vorschau an. Ordner dürfen nicht identisch sein oder ineinander liegen. Leere Ordner werden nicht synchronisiert, nur Dateien.'
    HelpH 'Zeitplan (automatisch)'
    HelpP 'Mit "Zeitplan ..." legst du für die gewählte Aufgabe einen Eintrag im Windows-Aufgabenplaner an: täglich, wöchentlich, alle X Minuten oder bei der Anmeldung. Du kannst ihn dort jederzeit ändern oder entfernen. Das Tool muss dafür nicht laufen, aber du musst bei Windows angemeldet sein. Verpasste Läufe werden nachgeholt. Bei automatischen Läufen gibt es keine Rückfrage vor dem Löschen.'
    HelpP 'Nach einem automatischen Lauf kann eine Windows-Meldung erscheinen: nie, wenn etwas passiert ist oder Fehler auftraten, oder nur bei Fehlern.'
    HelpH 'Protokoll'
    HelpP 'Die Liste unten zeigt den aktuellen Lauf. Alle echten Läufe, manuell und automatisch, stehen zusätzlich mit Uhrzeit in DirToy-Daten\sync.log. Der Button "Protokoll" öffnet diese Datei.'
    HelpH 'Wo liegen meine Daten?'
    HelpP 'Aufgaben und Zeitpläne stehen in DirToy-Daten\aufgaben.json neben dem Programm. Verschiebst du DirToy.ps1, speichere die Zeitpläne danach einmal neu. Bei Startproblemen steht der Grund in DirToy-Daten\fehler.log.'
    $rb.SelectionStart = 0; $rb.ScrollToCaret()
    $bc = New-Btn $d 556 584 100 36 'Schließen' $true $null; $bc.Anchor = $A_BR
    $script:helpClose = $bc
    $bc.Add_Click({ $script:helpClose.FindForm().Close() })
    $d.Add_HandleCreated({
        try { $v = if ($isDark) { 1 } else { 0 }; [void][Win32.Dwm]::DwmSetWindowAttribute($script:helpClose.FindForm().Handle, 20, [ref]$v, 4) } catch { }
    })
    [void]$d.ShowDialog($form)
    $d.Dispose()
}
$editors = @($tbName, $tbA, $tbB, $cmb, $tbEx, $btnPrev, $btnRun, $btnDel, $btnSched)

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
}
function Set-Busy([bool]$busy) {
    foreach ($c in @($btnPrev, $btnRun, $btnAll, $btnNew, $btnDel, $btnSched, $lb)) { $c.Enabled = -not $busy }
    if (-not $busy) { Show-Cur }
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
    if ([System.Windows.Forms.MessageBox]::Show("Aufgabe '$($t.Name)' löschen?`n(Die Ordner und Dateien bleiben unverändert.)", 'Löschen', 'YesNo', 'Question') -ne 'Yes') { return }
    try { Unregister-Sched $t } catch { }
    $script:tasks = @($script:tasks | Where-Object { $_.Id -ne $t.Id })
    Remove-Item (Join-Path $script:stateDir "$($t.Id).json") -ErrorAction SilentlyContinue
    Save-Tasks; Refresh-List ([math]::Min($i, $script:tasks.Count - 1))
})

$btnHelp.Add_Click({ Show-Help })
$btnLog.Add_Click({
    if (Test-Path $script:logFile) { Start-Process notepad.exe -ArgumentList "`"$($script:logFile)`"" }
    else { [void][System.Windows.Forms.MessageBox]::Show('Es gibt noch kein Protokoll. Es entsteht beim ersten Sync-Lauf.', 'Protokoll') }
})
$btnSched.Add_Click({
    if (-not $script:cur) { return }
    Show-ScheduleDialog $script:cur; Update-SchedLabel
})
$btnPrev.Add_Click({
    if (-not $script:cur) { return }
    $lv.Items.Clear(); Set-Busy $true
    try { [void](Run-Task $script:cur $true) } finally { Set-Busy $false; $lbl.Text = 'Vorschau fertig.' }
})
$btnRun.Add_Click({
    if (-not $script:cur) { return }
    $lv.Items.Clear(); Set-Busy $true
    try { [void](Run-Task $script:cur $false) } finally { Set-Busy $false; $lbl.Text = 'Fertig.' }
})
$btnAll.Add_Click({
    $lv.Items.Clear(); Set-Busy $true
    try { foreach ($t in @($script:tasks)) { [void](Run-Task $t $false) } } finally { Set-Busy $false; $lbl.Text = 'Alle Aufgaben abgearbeitet.' }
})

Refresh-List 0
$form.Add_Shown({ if ($script:tasks.Count -eq 0) { $btnNew.PerformClick() } })
[void]$form.ShowDialog()
Save-Tasks
