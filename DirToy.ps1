param([switch]$NoGui, [string]$Task, [switch]$All)
# DirToy - grafisches Ordner-Synchronisationstool (Vorbild: SyncToy)
# Start: DirToy.bat (Doppelklick)

Add-Type -AssemblyName System.Windows.Forms, System.Drawing, Microsoft.VisualBasic, System.Net.Http
[System.Windows.Forms.Application]::EnableVisualStyles()
$ErrorActionPreference = 'Stop'

$script:errLog = Join-Path $PSScriptRoot 'DirToy-Daten\fehler.log'
# Logdatei ueber 2 MB -> wird zu <name>.alt (aelteres .alt wird ersetzt)
function Limit-Log([string]$path) {
    try { if ((Test-Path $path) -and (Get-Item $path).Length -gt 2MB) { Move-Item $path ($path + '.alt') -Force } } catch { }
}
trap {
    try {
        Limit-Log $script:errLog
        New-Item -ItemType Directory -Force -Path (Split-Path $script:errLog) | Out-Null
        Add-Content -Path $script:errLog -Value ("=== " + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + "`r`n" + ($_ | Out-String) + ($_.ScriptStackTrace)) -Encoding UTF8
    } catch { }
    if (-not $NoGui -and -not $Task -and -not $All) {
        [void][System.Windows.Forms.MessageBox]::Show("DirToy konnte nicht starten oder ist abgestürzt:`n`n$($_.Exception.Message)`n`nDetails stehen in:`n$($script:errLog)", 'DirToy', 'OK', 'Error')
    }
    exit 1
}
$script:version = '1.5.1'
$script:bulk = $false
$script:tmpSuffix = '.dirtoy-tmp'
$script:pumpMs = 150
$script:cancel = $false
$script:inPlan = $false
$script:scanCount = 0
$script:tmpFiles = $null
$script:copyBuf = $null
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
Limit-Log $script:logFile
Limit-Log $script:errLog

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
            if (-not $t.PSObject.Properties['ExcludeDirs']) { Add-Member -InputObject $t -NotePropertyName 'ExcludeDirs' -NotePropertyValue ([string[]]@()) }
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
    [pscustomobject]@{ Id = [guid]::NewGuid().ToString('N'); Name = $name; A = ''; B = ''; Mode = 0; Exclude = 'Thumbs.db;desktop.ini;~$*;*.tmp'; ExcludeDirs = [string[]]@(); Schedule = $null; SchedName = '' }
}

# ---------------------------------------------------------------- Zustand (zum Erkennen von Löschungen)
function Get-State([string]$id) {
    $set = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    # Neues Format: eine Zeile pro Eintrag (schnell, auch bei hunderttausenden Dateien)
    $f = Join-Path $script:stateDir "$id.state"
    if (Test-Path $f) {
        foreach ($line in [System.IO.File]::ReadLines($f, [System.Text.Encoding]::UTF8)) { if ($line) { [void]$set.Add($line) } }
    } else {
        # altes JSON-Format (nur kleine Staende)
        $fj = Join-Path $script:stateDir "$id.json"
        if (Test-Path $fj) {
            try {
                $raw = Get-Content $fj -Raw -Encoding UTF8
                if ($raw -and $raw.Trim()) { $items = ConvertFrom-Json $raw; foreach ($p in $items) { [void]$set.Add([string]$p) } }
            } catch { }
        }
    }
    return ,$set
}
function Save-State([string]$id, $keys) {
    $f = Join-Path $script:stateDir "$id.state"
    $tmp = $f + '.tmp'
    [System.IO.File]::WriteAllLines($tmp, [string[]]@($keys), (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -Path $tmp -Destination $f -Force
    Remove-Item (Join-Path $script:stateDir "$id.json") -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------- Scannen
function New-Dict { New-Object 'System.Collections.Generic.Dictionary[string,System.IO.FileInfo]' ([StringComparer]::OrdinalIgnoreCase) }
function Test-Excluded([string]$name, $pats) {
    foreach ($p in $pats) { if ($name -like $p) { return $true } }
    return $false
}
function New-DirSet { New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase) }
function Scan-Dir([System.IO.DirectoryInfo]$dir, [string]$rel, $pats, $dict, $dirs) {
    try { $entries = $dir.GetFileSystemInfos() }
    catch { $script:warn.Add("$($dir.FullName): $($_.Exception.Message)"); return }
    foreach ($e in $entries) {
        $script:scanCount++
        if (($script:scanCount % 300) -eq 0) {
            if ($script:lblStatus) { $script:lblStatus.Text = "Lese Ordner ein ... ($($script:scanCount) Einträge)" }
            Pump
            if ($script:cancel -and $script:inPlan) { throw 'DIRTOY_CANCEL' }
        }
        if ($e -isnot [System.IO.DirectoryInfo] -and $e.Name.EndsWith($script:tmpSuffix, [StringComparison]::OrdinalIgnoreCase)) {
            if ($null -ne $script:tmpFiles) { $script:tmpFiles.Add($e.FullName) }
            continue
        }
        if (Test-Excluded $e.Name $pats) { continue }
        if ($e -is [System.IO.DirectoryInfo]) {
            if ($e.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { continue }
            if ($script:exDirs -and $script:exDirs.Contains($rel + $e.Name + '\')) { continue }   # im Ordnerbaum abgewaehlt
            if ($dirs) { [void]$dirs.Add($rel + $e.Name + '\') }
            Scan-Dir $e ($rel + $e.Name + '\') $pats $dict $dirs
        } else {
            $dict[$rel + $e.Name] = $e
        }
    }
}
function Get-ExcludeDirs($t) {
    $set = New-DirSet
    foreach ($x in @($t.ExcludeDirs)) { if ($x) { [void]$set.Add(([string]$x).TrimEnd('\') + '\') } }
    return ,$set
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
    $da = New-Dict; $db = New-Dict; $dsA = New-DirSet; $dsB = New-DirSet
    $script:tmpFiles = New-Object System.Collections.Generic.List[string]
    $exDirs = Get-ExcludeDirs $t; $script:exDirs = $exDirs
    $script:scanCount = 0; $script:inPlan = $true
    try {
        Scan-Dir (New-Object System.IO.DirectoryInfo $rootA) '' $pats $da $dsA
        Scan-Dir (New-Object System.IO.DirectoryInfo $rootB) '' $pats $db $dsB
    } finally { $script:inPlan = $false }
    $state = Get-State $t.Id
    $mode = [int]$t.Mode

    $keys = New-Object 'System.Collections.Generic.SortedSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($k in $da.Keys) { [void]$keys.Add($k) }
    foreach ($k in $db.Keys) { [void]$keys.Add($k) }

    $plan = New-Object System.Collections.Generic.List[object]
    function Add-Item($typ, $text, $rel, $src, $dst) {
        $plan.Add([pscustomobject]@{ Typ = $typ; Text = $text; Rel = $rel; Src = $src; Dst = $dst })
    }
    $idx = 0; $total = $keys.Count
    foreach ($rel in $keys) {
        $idx++
        if (($idx -band 2047) -eq 0) {
            if ($script:lblStatus) { $script:lblStatus.Text = "Vergleiche ... $idx / $total" }
            Pump
            if ($script:cancel) { throw 'DIRTOY_CANCEL' }
        }
        $fa = $null; $fb = $null
        $inA = $da.TryGetValue($rel, [ref]$fa)
        $inB = $db.TryGetValue($rel, [ref]$fb)
        $pa = $rootA + '\' + $rel; $pb = $rootB + '\' + $rel
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

    # ---- Ordner (auch leere): anlegen vor den Dateien, loeschen nach den Dateien (tiefste zuerst)
    $implicit = New-DirSet   # Ordner, die durch kopierte Dateien ohnehin entstehen bzw. noch gebraucht werden
    foreach ($p in $plan) {
        if ($p.Typ -ne 'Copy') { continue }
        $parts = $p.Rel.Split('\'); $acc = ''
        for ($k = 0; $k -lt $parts.Length - 1; $k++) { $acc += $parts[$k] + '\'; [void]$implicit.Add($acc) }
    }
    $dkeys = New-Object 'System.Collections.Generic.SortedSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($k in $dsA) { [void]$dkeys.Add($k) }
    foreach ($k in $dsB) { [void]$dkeys.Add($k) }
    $mk = New-Object System.Collections.Generic.List[object]
    $rm = New-Object System.Collections.Generic.List[object]
    foreach ($dk in $dkeys) {
        $inA = $dsA.Contains($dk); $inB = $dsB.Contains($dk)
        if ($inA -and $inB) { continue }
        if ($implicit.Contains($dk)) { continue }
        $pa = Join-Path $rootA $dk; $pb = Join-Path $rootB $dk
        if ($inA) {
            if ($mode -eq 0 -and $state.Contains($dk)) { $rm.Add([pscustomobject]@{ Typ = 'RmDir'; Text = 'In A Ordner löschen (in B gelöscht)'; Rel = $dk; Src = $pa; Dst = $null }) }
            else { $mk.Add([pscustomobject]@{ Typ = 'MkDir'; Text = 'A -> B Ordner anlegen'; Rel = $dk; Src = $null; Dst = $pb }) }
        } else {
            switch ($mode) {
                0 { if ($state.Contains($dk)) { $rm.Add([pscustomobject]@{ Typ = 'RmDir'; Text = 'In B Ordner löschen (in A gelöscht)'; Rel = $dk; Src = $pb; Dst = $null }) }
                    else { $mk.Add([pscustomobject]@{ Typ = 'MkDir'; Text = 'B -> A Ordner anlegen'; Rel = $dk; Src = $null; Dst = $pa }) } }
                1 { $rm.Add([pscustomobject]@{ Typ = 'RmDir'; Text = 'In B Ordner löschen (nicht in A vorhanden)'; Rel = $dk; Src = $pb; Dst = $null }) }
                2 { }
            }
        }
    }
    $final = New-Object System.Collections.Generic.List[object]
    $final.AddRange($mk)
    $final.AddRange($plan)
    foreach ($x in ($rm | Sort-Object { $_.Rel.Length } -Descending)) { $final.Add($x) }
    return [pscustomobject]@{ Plan = $final; A = $rootA; B = $rootB; Pats = $pats; ExDirs = $exDirs }
}

# ---------------------------------------------------------------- Plan ausführen
function Copy-One($src, $dst) {
    $dir = [System.IO.Path]::GetDirectoryName($dst)
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    # Sicher kopieren: erst in eine Zwischendatei schreiben, erst wenn sie komplett ist an die Stelle des Ziels setzen.
    # Bei Abbruch/Absturz bleibt das Original im Ziel unveraendert.
    $tmp = $dst + $script:tmpSuffix
    $in = $null; $out = $null; $ok = $false
    try {
        $in = New-Object System.IO.FileStream($src, 'Open', 'Read', 'ReadWrite')
        $out = New-Object System.IO.FileStream($tmp, 'Create', 'Write', 'None')
        if (-not $script:copyBuf) { $script:copyBuf = New-Object byte[] (4MB) }
        $total = $in.Length; $done = 0; $last = [Environment]::TickCount
        while (($n = $in.Read($script:copyBuf, 0, $script:copyBuf.Length)) -gt 0) {
            $out.Write($script:copyBuf, 0, $n); $done += $n
            if ($script:cancel) { throw 'DIRTOY_CANCEL' }
            if (([Environment]::TickCount - $last) -ge $script:pumpMs) {
                $last = [Environment]::TickCount
                if ($script:lblStatus -and $total -gt 8MB) { $script:lblStatus.Text = "Kopiere $([System.IO.Path]::GetFileName($src)): $([int](100 * $done / $total)) %" }
                Pump
            }
        }
        $out.Dispose(); $out = $null; $in.Dispose(); $in = $null
        $attr = [System.IO.File]::GetAttributes($src)
        $utc = [System.IO.File]::GetLastWriteTimeUtc($src)
        [System.IO.File]::SetLastWriteTimeUtc($tmp, $utc)
        if (Test-Path -LiteralPath $dst) {
            [System.IO.File]::SetAttributes($dst, [System.IO.FileAttributes]::Normal)
            try { [System.IO.File]::Replace($tmp, $dst, $null) }
            catch { [System.IO.File]::Delete($dst); [System.IO.File]::Move($tmp, $dst) }
        } else {
            [System.IO.File]::Move($tmp, $dst)
        }
        $ok = $true
        try { [System.IO.File]::SetLastWriteTimeUtc($dst, $utc); [System.IO.File]::SetAttributes($dst, $attr) } catch { }
    } finally {
        if ($out) { $out.Dispose() }
        if ($in) { $in.Dispose() }
        if (-not $ok) { try { if (Test-Path -LiteralPath $tmp) { [System.IO.File]::Delete($tmp) } } catch { } }
    }
}
function Delete-One($path) {
    [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($path, 'OnlyErrorDialogs', 'SendToRecycleBin')
}
function Update-State($t, $r) {
    $da = New-Dict; $db = New-Dict; $dsA = New-DirSet; $dsB = New-DirSet
    $script:exDirs = $r.ExDirs
    Scan-Dir (New-Object System.IO.DirectoryInfo $r.A) '' $r.Pats $da $dsA
    Scan-Dir (New-Object System.IO.DirectoryInfo $r.B) '' $r.Pats $db $dsB
    $both = New-Object System.Collections.Generic.List[string]
    foreach ($k in $da.Keys) { if ($db.ContainsKey($k)) { $both.Add($k) } }
    foreach ($k in $dsA) { if ($dsB.Contains($k)) { $both.Add($k) } }
    Save-State $t.Id $both
}

# ---------------------------------------------------------------- Log-Ausgabe
function Write-LogLine([string]$aktion, [string]$datei, [string]$status) {
    try { [System.IO.File]::AppendAllText($script:logFile, ((Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' | ' + $aktion + ' | ' + $datei + ' | ' + $status + "`r`n"), [System.Text.Encoding]::UTF8) } catch { }
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
        if (-not $script:bulk) { $it.EnsureVisible() }
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
    if (-not $preview) { Limit-Log $script:logFile; Write-LogLine ("=== Aufgabe '" + $t.Name + "' (" + $(if ($script:headless) { 'automatisch' } else { 'manuell' }) + ', DirToy ' + $script:version + ')') '' '' }
    Set-Progress 0
    if ($script:lblStatus) { $script:lblStatus.Text = "Analysiere '$($t.Name)' ..." }
    Pump
    try { $r = Build-Plan $t }
    catch {
        if ($_.Exception.Message -eq 'DIRTOY_CANCEL') { [void](Add-Log "Aufgabe '$($t.Name)'" 'Abgebrochen (nichts wurde verändert).' ''); return @{ Copied = 0; Deleted = 0; Errors = 0; Cancelled = $true } }
        [void](Add-Log "Aufgabe '$($t.Name)'" '' "FEHLER: $($_.Exception.Message)"); return $null
    }
    foreach ($w in $script:warn) { [void](Add-Log 'Warnung' $w 'übersprungen') }
    if (-not $preview) {
        # liegengebliebene Zwischendateien frueherer, abgebrochener Laeufe aufraeumen
        foreach ($tf in @($script:tmpFiles)) {
            try {
                $fi = Get-Item -LiteralPath $tf -Force
                if (((Get-Date) - $fi.LastWriteTime).TotalMinutes -gt 5) { Remove-Item -LiteralPath $tf -Force; [void](Add-Log 'Aufgeräumt' $tf 'Zwischendatei gelöscht') }
            } catch { }
        }
    }
    $plan = $r.Plan
    $dels = @($plan | Where-Object { $_.Typ -eq 'Delete' -or $_.Typ -eq 'RmDir' }).Count
    if ($plan.Count -eq 0) { if (-not $preview) { try { Update-State $t $r } catch { } }; [void](Add-Log "Aufgabe '$($t.Name)'" 'Bereits synchron - nichts zu tun.' ''); return @{ Copied = 0; Deleted = 0; Errors = 0 } }

    $uiMax = 2000   # mehr Zeilen machen die Liste langsam; vollstaendig steht alles im Protokoll
    if ($preview) {
        $script:bulk = $true
        if ($script:lv) { $script:lv.BeginUpdate() }
        try {
            $n = 0
            foreach ($p in $plan) { $n++; if ($n -gt $uiMax) { break }; [void](Add-Log $p.Text $p.Rel 'geplant') }
        } finally { $script:bulk = $false; if ($script:lv) { $script:lv.EndUpdate() } }
        if ($plan.Count -gt $uiMax) { [void](Add-Log "... und $($plan.Count - $uiMax) weitere Aktionen" "(Anzeige auf die ersten $uiMax begrenzt)" '') }
        [void](Add-Log "Aufgabe '$($t.Name)'" "Vorschau: $($plan.Count) Aktion(en), davon $dels Löschung(en)" '')
        return $null
    }
    if ($dels -gt 0 -and -not $NoGui) {
        $ans = [System.Windows.Forms.MessageBox]::Show(
            "Aufgabe '$($t.Name)': $dels Datei(en)/Ordner werden gelöscht (Papierkorb, sofern möglich).`nFortfahren?",
            'Löschen bestätigen', 'YesNo', 'Warning')
        if ($ans -ne 'Yes') { [void](Add-Log "Aufgabe '$($t.Name)'" '' 'Abgebrochen.'); return $null }
    }
    $copied = 0; $deleted = 0; $errors = 0; $i = 0; $cancelled = $false; $lastPump = [Environment]::TickCount - 1000
    $shown = 0; $script:bulk = $true
    foreach ($p in $plan) {
        if ($script:cancel) { $cancelled = $true; break }
        $i++
        if (([Environment]::TickCount - $lastPump) -gt 100) {
            $lastPump = [Environment]::TickCount
            if ($script:lblStatus) { $script:lblStatus.Text = "'$($t.Name)': $i / $($plan.Count)  ($([int](100 * $i / $plan.Count)) %)" }
            Set-Progress ($i / $plan.Count)
            if ($script:lv -and $script:lv.Items.Count -gt 0) { $script:lv.EnsureVisible($script:lv.Items.Count - 1) }
            Pump
        }
        $it = $null
        if ($shown -lt $uiMax) { $it = Add-Log $p.Text $p.Rel '...'; $shown++ }
        try {
            $st = 'OK'
            switch ($p.Typ) {
                'Copy'     { Copy-One $p.Src $p.Dst; $copied++ }
                'Delete'   { Delete-One $p.Src; $deleted++ }
                'MkDir'    { [void][System.IO.Directory]::CreateDirectory($p.Dst); $copied++ }
                'RmDir'    {
                    if (-not (Test-Path -LiteralPath $p.Src -PathType Container)) { $st = 'OK' }
                    else {
                        $en = [System.IO.Directory]::EnumerateFileSystemEntries($p.Src).GetEnumerator()
                        $hasAny = $en.MoveNext(); $en.Dispose()
                        if ($hasAny) { $st = 'übersprungen (nicht leer)' }
                        else { [System.IO.Directory]::Delete($p.Src); $deleted++ }
                    }
                }
                'Conflict' { $st = 'übersprungen' }
            }
            if ($script:logOn) { Write-LogLine $p.Text $p.Rel $st }
            if ($it) { $it.SubItems[2].Text = $st; $it.ForeColor = (Get-StatusColor $st) }
        } catch {
            if ($_.Exception.Message -eq 'DIRTOY_CANCEL') {
                $cancelled = $true
                if ($script:logOn) { Write-LogLine $p.Text $p.Rel 'abgebrochen (Zieldatei unverändert)' }
                if ($it) { $it.SubItems[2].Text = 'abgebrochen'; $it.ForeColor = (Get-StatusColor 'abgebrochen') }
                break
            }
            $errors++
            $emsg = 'FEHLER: ' + $_.Exception.Message
            if ($it) {
                if ($script:logOn) { Write-LogLine $p.Text $p.Rel $emsg }
                $it.SubItems[2].Text = $emsg; $it.ForeColor = (Get-StatusColor 'FEHLER')
            } else { [void](Add-Log $p.Text $p.Rel $emsg) }   # Fehler immer anzeigen (Add-Log schreibt auch ins Protokoll)
        }
    }
    $script:bulk = $false
    if ($plan.Count -gt $uiMax) { [void](Add-Log "Anzeige auf die ersten $uiMax Aktionen begrenzt" 'Alle Aktionen stehen im Protokoll (sync.log)' '') }
    if ($cancelled) {
        [void](Add-Log "Aufgabe '$($t.Name)' abgebrochen" "$copied kopiert, $deleted gelöscht, $errors Fehler - Lauf unvollständig, keine halben Dateien" '')
        return @{ Copied = $copied; Deleted = $deleted; Errors = $errors; Cancelled = $true }
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
# Programm-Icon (64 px, PNG als Base64; die Mehrgroessen-Datei DirToy.ico liegt fuer Verknuepfungen daneben)
$script:iconB64 = 'iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAYAAACqaXHeAAAAAXNSR0IArs4c6QAAAARnQU1BAACxjwv8YQUAAAAJcEhZcwAADsMAAA7DAcdvqGQAAA5xSURBVHhe7ZlpUFRnl8czeTMEwYV93wUjLlFBNIoYo8a8MTP1fpoPU1OVqvfDTNVMJl5cMMq+C7I1IJsBjEHjvsREEU0yiZNXFGSRnV7Zmh0iNNAgyn/qubdv9+3bF+ipmnL40KfqV1B+8PI75zz3Oc9z33rLFKYwhSlMYQpTmMIU+vHh1Qmng4/m/vmTX14d2v9gmqIpZ9hLM0ntvatjD+EHgopm9w8qau+DudCQm6N/4f/fSz72lU9/9unvrwf/oRr47Clw8AnDp5XAp4+BPxP+BnzyO8OB/wYOPAI+JvwG7P8V2PcrsP8R8NFDIOTW2E7+M5ZsfFI+4Xzg4UvVwcfAxxUzNPvvT9PsK1fT7L03RfPR3Sl89OMk9hB+mMCHdxh2f6/C7tsqhNwax56KOey6rZIE3lFa8J+1JOPA/ZnPP6sC9hPxCo34fVackV9Q/HsVQm6P0/K7bo0j+MYY9vwM7Lw2WsR/1pKMjyumD5N2F6w6Eb87ycgTcY28kPium2MIJtx4geCb4wgpn8MHl4f+kf+8JRfkJUfWuqG4ruqs+Id3WHFGni++8zrDjmt/IPjODHbcGO8PvKi04z9zSQV5u5MXnDHtzoozVWfFx7BTI0/ECR9cHcUHV0aw6z6w7fLQDf4zl1SQLY282fXFJxdc53TVb3CqrhVn5LdfIYxg25VR7LwHbL3Y91f+c5dMkP2cbGvMOte1+7ziAu3OijPyI9h2mSHo0jC2X1ch6NqYaseFXk/+s5dEkCGG7Oe6dl9knQu1u6bqrPi2y8O0/NbvhrD14iC2355BwIWBqoALg4cCyvopwuZvWJQMpUpqI0sxSze1vkgf/6JOyr9Ax3uEPA0F3dTas8Of+2aLV/M95w2SgP2/QX8/56xztt0XEtdVnREPujSkkR9C4MVBBJT1Y+tVFbbdnkXQrVkE3XxJs/XGS2y9PoPA6zMIuDaNgKvT2HJVjS1X1Nh8eQqbL01h06VJvP8dw8aLEzQbLkxgQ5kK68tUWPctYRz+5xnWnldhzdmBKd9s8b/zXQVj920Vte+/INzuHPGd140R11T9O0Y88MIgqTwCygYQ8O0Atnzbjy3n+7H5mz6aTecIvXi/tBfvlyixkVDcgw1fM6w/202zrqiLxr+wC2sLOmney2dYk9dB43emA365CvjmyuFX2Ae/wn6szpQE8H0NgiRg7y8QbnfuOteTH9HKzydOyxPxMo74eUZ8s6C4Ehs08kLihvIc8TNEXAHfHDlWE7Jl8Csdh1emNJHvaxC7b45RH/2Mxbc1XtVZcbbdAzXtLiSuX3WNeKmSkRcUZ+QXFKflFUzVteJy+GTL4COSwffrUXhnSXP4vgYRfHOM2vMT5hHnbWtC7S4gLtzuvdjEE9e1u07cfxFxpuoa8VyFVpxUnYh7Z0lpVheNwDNDIuL7GkTw9THqw4fQW+ds1RcUF2p3QXGhdtcX57a7e04HfPM64S+4znXi3HYn4lr5TCm8MiXwKRyGZ1r74gnYcX2U2l0BQXF+u+uJL9buguJC7c6IrynowvbSHoievsD6wk64ihSLrnM98SxG3CtDAs8MMbwLhoxMwJVRKuQ+BNe5dj/nbWsLii/S7vOtc9+8Dmw624WXr+bQMDCDXd90wzZNxqm6nJHnrHO+OC2fLqbxyh+Ex2kjErD9yjC1qxyC4gZV52xrtLhBu7Pihu2+ntfu/HW++kwH3i/qhFI1CxKjU6/x1+/7YZUqhZeIkWfFfUSsOKfqGnGPtHYiDq+8QbidbjMuAcH3yKFlgXZfZFtbeJ1rqs6rOP8l55OrwMbCTvSqXtEJYCPj8Sgc0iRwTpdgNW+dc8U903Ty7qlt8DwzALcUYxJwaZjaeZckgC9u2O4B3/Zjw7k+rP66Fz5FSngTCnvgVcDgmd8NjzxCF9zPdME9txNuhJxOuOZ0wCW7Ay6iDjiLFHDOUsCJkCmHY6YcNmkyuIvk6BlnOoAbFdIJrDsjg1VyO7z57c4TJ7iltMEjpx8uyUYkYOulYWrHj1hwnZO3O5FfW9KHkO8G8MXDURz+ZRShP48i9CfCCCjCwxEcejiMQw8YvqwgDOE/CfdZBvFFOcN/3GMZwL/92I9D5YMYVet3ABsdf7zEZ2VdsIxvhUeafrtr5VOIfCtcT7XCPbsPLsktRiTg4iD1wQ9zguucu635l/Tiz9cGoeS16JuMl6/ncLyiH6sSWuGWyq96K9xOMfKuyS1wE/XBJdHIBGy/85o5tAiIs+vcvaAHpQ0q/t/0/xKXG17AIbkVrpqKc8VdCEnNcM3qhVNi0+IJCCgbpLZ//8rgBcffzz0KepBS+YL/t7zxeKF+jS/uKOGQpJHmiTsnMrhkKOGUYFQC+ilyTBWe4nTb2rpiZk+/0TZJv6n7J4yjj6BimeX9rqNXNYt+1SxezfGVdVGjnEJQvhTLops0VWfFW+CskXdKaKJxTu+BY1zD4gkglxJBt14aNb6uPdsN7/wubCnpQWBJDwJKurGlWMe6wk5sLOqiBxqypxPI1raxoAMbCPkKrCfkKbDujJzGP1cG/xwZfEVSbMqToVdgFyBxvvYPOCe3YmVcMyOvEddWXSPuGE9ohFN6D+yNTQC5mDB2fCUTHBlb/Qo64ZfPQGZ3+ww5AosZec8cBbwJ2XJ4EURyeIpk8MiSwSNTCndChgRu6QyuaWI4prTDJ0NssA3OvJrDkbu9sIhugn1iC9y0Vde1O1ec4BDXAMe0btjHGJUAJUVuZRY8pnJOa3rDTEEn1uR3wjZdjn+51Y/OF7M4cKGH3s/nO6bqja+ZzNxOtjSX1Hb4ZYmh5CRAPjKDA6VymEU2wjm5RVP1ZoN214k3wj62gcYhtQu2MfVGJKBUSQVem9aJL3Ba405wRN4rt4MeYuIejWj/6JBz3XDLkmnndv4xdb7x1SWlDb4Z7RiYYLbZu23jWJ3WBsvoJm27LyROqs7IP4ddzHPYp3bCNsqIBJBLyICraqPEueMrmeTIae1m24RWfvrVHELOdcE1U2Z4WhMQ505xzqdasTZLjNGpV8j8fQgrY5tgE9esqzrd7ouLE2yj62GX0gHrqDojElCspMgl5HzHVL440/IyfHyhB61DM1p5NgE7SzrhnC6FV5YUnpkECTwyJPBIJ4jhniaG++l2uBFS2+i9nOCU3Aq/jHZ8ek4Bi6hG2Cc0wymxGY4JhCY40Gtcf52z8lxxgk1UHWyTFbCOMCIB64u7qU2XpuZd56w4wSe3g5b/8v4gJl6+1pNnE7DtbAdsU8Rw1bzcXE4zOKe2wzmF0AanU4ywIyGpFQ5JLXBIbIFtfDMtbxffBLu4JtjGNcImlsEqugFmJ+thE2MobhfDijPy1pF1sElSYJVRCSjqpsiVM/+0xj2prc1nLig8shU4WzPG99bG3BzQMjiN2l416vsEIP/eq0adIFOoU+pTq4H8XtU9iZzfB8neDuto/XZnxW0i62AdUQuriFpYJ8qxKrxm8QT4F3VT5K59PnlyI0O2tH1lPXjcreY7v/FI+7Ufb4fV6LU7Lc7KhxNqYJUgw8oT1UYkoKCTIh8aDMS111EKOGfKUFI3f+XfZPwkGcfbYc8YcU27s1Un4qtOaoiXGp8A8oWFFRe6ffXJkdNv9vjfhvl/zxuPzy8p8E7Ys3nFV554xhArwfLjRiSAfFsjn5cMbl85l5AEL5EMK5LF+KcrPfTsLhSzr+cg+tswoh4OIO5nhljCT4R+xDzk8KAP0SwVfYiq6GW434tIGiVDOUP4vR4cLBbD7HgNrCNrNe1eQ9a5nviKr6qx4ng1VsRIsPzYUyMSkNdJkW9qxty++mRJsSq5HZvy5HjUMcn3h3p2Du9lifF2RCMsYpro8XVZVCONeWQD3o1gMAt/DrOTz/H3J+vxzol6vPNVHf5EOF6LtwlhNfi7sBq8dawGbx19xnCkmqm8pupa8ZOsuE5+eVgVVkSLjU2AnPL/ZkxAXHh8JVdS9qfa4ZDSjrwnugmQxPTsHLblS2GX2DLvMdVwitNta+wwo3vB6ba1edudK368ipZffqwKy6PaYXHUiAT45sqptefG9K6djRlfyexuEduMf72lhGqGmQlIAoLypPR+Pt8xdaEpzlazn9sKitcarHNtu2uqTsQtjz2F5dGnsIxsg8XhJ0YkIFsa+l7pC712Z8UXG1/JVRQ5mwcXytAyME0nIeiMBDZxTQLjKyMvJM4OMuy2Rotr1zmn3ecTD+OIH30KiyNPYBHeBvPQJ9l8X4PwEcmpNSUvFvzKIiTO3r66p7RiRUwTvFJbUVY7iuACCWxim+Y9prKnNaHxlZHXibPtzq5zvXbnimvkafEjT7DscCWWhbfCjKpc/OOoj0h60K94FN4aeQNxzu2r+2lGnHv7StY5wTa+CVaxjXBLMrLd/w/WuaD44UqYhz6GeYQEZtTjUL6vQfhmi9/1yhBX+ZZOwju7A15ZCnhlyeGZyeCRIYNHOkEK9zSCBG6nJXBNFcM1RQwXwql2GqekNjgmtcEpqRWOiQwOCS009vHNsCOQGT+W0AibmEbYRDfCOroB1lENsIp8TrMqglCPleH1WHmyDisIJ2qx/CtCDSyP18AyjPAMFscI1Vh2tBrLjlTBnBDeDrPQSuXyL2vt+b6C4S2SOXqLuq54iTpGPdIk0x5p7Wr30200bqmtareUVrUr4VSL2iWZ0Kx2TiI0qZ0Sm9ROCU1qx4RGtWN8o9ohvkHtENegtifEPlfbEaLr1baEqHq1TVSd2iayTm0dUUtjFV6rtjpZo151ska98sQzhq+eqVccr6ZZHlZFY3nsqdryKIPFkSc0yw5X0piHVqrNqcfqd6nH0+8eqR4zO1rzwOzLR+v4nouGS26PrY9I5uGSLnHXI4FL46JYc4lYiCrOT33Myc8jVe7m/xsOPfOwPFTpyPcyhSlMYQpTmMIUpiDxP7nWGcg8Lt1hAAAAAElFTkSuQmCC'
function Get-AppIcon {
    try {
        $ms = New-Object System.IO.MemoryStream (,[Convert]::FromBase64String($script:iconB64))
        $bmp = New-Object System.Drawing.Bitmap $ms
        $h = $bmp.GetHicon(); $ic = [System.Drawing.Icon]::FromHandle($h).Clone()
        [void][Win32Icon.U]::DestroyIcon($h); $bmp.Dispose(); $ms.Dispose()
        return $ic
    } catch { return $null }
}
if (-not ('Win32Icon.U' -as [type])) { Add-Type -Namespace Win32Icon -Name U -MemberDefinition '[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool DestroyIcon(System.IntPtr h);' }
function Send-Notify([string]$title, [string]$text, [bool]$isError) {
    try {
        Add-Type -AssemblyName System.Windows.Forms, System.Drawing
        if ($text.Length -gt 250) { $text = $text.Substring(0, 247) + '...' }
        $ni = New-Object System.Windows.Forms.NotifyIcon
        $ni.Icon = $(if ($script:iconB64 -and (Get-AppIcon)) { Get-AppIcon } else { [System.Drawing.SystemIcons]::Application })
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
# ---------------------------------------------------------------- Einstellungen + Update-Pruefung (GitHub)
$script:settingsFile = Join-Path $script:dataDir 'einstellungen.json'
$script:repo = 'Tipitopi79/dirtoy'
function Get-Setting([string]$name, $default) {
    try {
        if (Test-Path $script:settingsFile) {
            $s = Get-Content $script:settingsFile -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($s.PSObject.Properties[$name] -and $null -ne $s.$name) { return $s.$name }
        }
    } catch { }
    return $default
}
function Set-Setting([string]$name, $value) {
    try {
        $h = [ordered]@{}
        if (Test-Path $script:settingsFile) {
            $s = Get-Content $script:settingsFile -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($p in $s.PSObject.Properties) { $h[$p.Name] = $p.Value }
        }
        $h[$name] = $value
        Set-Content -Path $script:settingsFile -Value (ConvertTo-Json -InputObject $h) -Encoding UTF8
    } catch { }
}
# Antwort von GET /releases/latest -> @{ Version; Tag; Url; Notes } oder $null (kein gueltiger Release)
function Read-Release([string]$json) {
    try {
        $j = ConvertFrom-Json $json
        $tag = [string]$j.tag_name
        if ($tag -notmatch '^v?(\d+\.\d+\.\d+)$') { return $null }
        $url = [string]$j.html_url
        if ($url -notlike "https://github.com/$($script:repo)/*") { $url = "https://github.com/$($script:repo)/releases/tag/$tag" }
        return [pscustomobject]@{ Version = [version]$Matches[1]; Tag = $tag; Url = $url; Notes = [string]$j.body }
    } catch { return $null }
}
function Test-NewerVersion($info) { return ($null -ne $info -and $info.Version -gt [version]$script:version) }
# Laedt DirToy.ps1 des Release-Tags, prueft sie und ersetzt die laufende Datei (Sicherung bleibt als .bak-<alte Version>)
function Install-Update($info, [string]$target, [string]$sourceUrl) {
    if ($info.Tag -notmatch '^v?\d+\.\d+\.\d+$') { throw 'Ungültiger Versions-Tag.' }
    if (-not $sourceUrl) { $sourceUrl = "https://raw.githubusercontent.com/$($script:repo)/$($info.Tag)/DirToy.ps1" }
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $wc = New-Object System.Net.WebClient
    $wc.Headers['User-Agent'] = 'DirToy'
    try { $bytes = $wc.DownloadData($sourceUrl) } finally { $wc.Dispose() }
    $neu = $target + '.neu'
    [System.IO.File]::WriteAllBytes($neu, $bytes)
    try {
        if ($bytes.Length -lt 50KB) { throw 'Die heruntergeladene Datei ist zu klein.' }
        $errs = $null; $toks = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($neu, [ref]$toks, [ref]$errs)
        if ($errs -and $errs.Count -gt 0) { throw 'Die heruntergeladene Datei ist kein gültiges Skript.' }
        $txt = [System.Text.Encoding]::UTF8.GetString($bytes)
        if ($txt -notmatch "\`$script:version\s*=\s*'$([regex]::Escape([string]$info.Version))'") { throw "Die Datei enthält nicht die Version $($info.Version)." }
        $bak = $target + '.bak-' + $script:version
        Copy-Item $target $bak -Force
        Move-Item $neu $target -Force
    } finally { if (Test-Path $neu) { Remove-Item $neu -Force -ErrorAction SilentlyContinue } }
}
if ($NoGui) { return }

# ================================================================ GUI
Load-Tasks

# ---- Theme (folgt dem Windows-Hell/Dunkel-Modus)
function C([string]$hex) { [System.Drawing.ColorTranslator]::FromHtml($hex) }
function Get-ThemeSetting {
    $v = [string](Get-Setting 'Theme' 'auto')
    if ($v -in @('auto', 'hell', 'dunkel')) { return $v } else { return 'auto' }
}
function Set-ThemeSetting([string]$v) { Set-Setting 'Theme' $v }
$script:themeSetting = Get-ThemeSetting
$isDark = $false
if ($script:themeSetting -eq 'dunkel') { $isDark = $true }
elseif ($script:themeSetting -eq 'auto') {
    try { $isDark = ((Get-ItemPropertyValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name AppsUseLightTheme) -eq 0) } catch { }
}
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
    if ($st -eq 'geplant' -or $st -like 'übersprungen*' -or $st -like 'abgebrochen*') { return $script:th.Muted }
    return $script:th.Text
}

$fNormal = New-Object System.Drawing.Font('Segoe UI', 10)
$fSmall  = New-Object System.Drawing.Font('Segoe UI', 9)
$fBold   = New-Object System.Drawing.Font('Segoe UI Semibold', 10)
$fTitle  = New-Object System.Drawing.Font('Segoe UI Semibold', 18)

$form = New-Object System.Windows.Forms.Form
$form.Text = "DirToy $($script:version)"; $form.ClientSize = New-Object System.Drawing.Size(1080, 720); $form.MinimumSize = New-Object System.Drawing.Size(1090, 640)
$form.StartPosition = 'CenterScreen'; $form.Font = $fNormal; $ico = Get-AppIcon; if ($ico) { $form.Icon = $ico }; $form.BackColor = $th.Bg; $form.ForeColor = $th.Text

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
    HelpH 'Ordner abwählen'
    HelpP 'Mit "Ordner wählen ..." siehst du beide Ordner als Baum nebeneinander. Entfernst du bei einem Ordner den Haken, wird er samt allen Unterordnern nicht synchronisiert (auf keiner Seite kopiert oder gelöscht). Der Haken gilt für beide Seiten. Neue Ordner, die später dazukommen, sind immer dabei, gespeichert werden nur die abgewählten. Ein abgewählter Ordner bleibt auch dann abgewählt, wenn er gelöscht und später neu angelegt wird; solche Einträge erscheinen grau mit "(nicht vorhanden)" und lassen sich durch Anhaken entfernen. "Alle wieder einschließen" setzt alle Haken zurück.'
    HelpH 'Löschen und Sicherheit'
    HelpP 'Dateien werden zuerst unter einem Zwischennamen (.dirtoy-tmp) kopiert und erst am Ende umbenannt. Bricht ein Lauf ab oder schließt du das Fenster, bleibt die alte Datei im Ziel unverändert; übrig gebliebene Zwischendateien räumt DirToy beim nächsten Lauf auf. Mit "Abbrechen" stoppst du einen Lauf nach der aktuellen Datei.'
    HelpP 'Vor dem Löschen fragt das Tool nach. Gelöscht wird in den Papierkorb, bei Netzlaufwerken ohne Papierkorb aber endgültig. Schau dir deshalb bei "Synchronisieren" und "Echo" zuerst die Vorschau an. Ordner dürfen nicht identisch sein oder ineinander liegen. Ordner werden komplett mit allen Unterordnern gespiegelt, auch leere. Ein Ordner wird nur gelöscht, wenn er danach wirklich leer ist (ausgeschlossene Dateien darin verhindern das Löschen).'
    HelpH 'Zeitplan (automatisch)'
    HelpP 'Mit "Zeitplan ..." legst du für die gewählte Aufgabe einen Eintrag im Windows-Aufgabenplaner an: täglich, wöchentlich, alle X Minuten oder bei der Anmeldung. Du kannst ihn dort jederzeit ändern oder entfernen. Das Tool muss dafür nicht laufen, aber du musst bei Windows angemeldet sein. Verpasste Läufe werden nachgeholt. Bei automatischen Läufen gibt es keine Rückfrage vor dem Löschen.'
    HelpP 'Nach einem automatischen Lauf kann eine Windows-Meldung erscheinen: nie, wenn etwas passiert ist oder Fehler auftraten, oder nur bei Fehlern.'
    HelpH 'Protokoll'
    HelpP 'Die Liste unten zeigt den aktuellen Lauf. Alle echten Läufe, manuell und automatisch, stehen zusätzlich mit Uhrzeit in DirToy-Daten\sync.log. Der Button "Protokoll" öffnet diese Datei.'
    HelpH 'Design'
    HelpP 'Der Button "Design" unten links wechselt zwischen Automatisch (wie Windows), Hell und Dunkel. DirToy startet dabei kurz neu, die Einstellung steht in DirToy-Daten\einstellungen.json.'
    HelpH 'Updates'
    HelpP 'Beim Start fragt DirToy im Hintergrund bei GitHub nach einer neueren Version (nur die Versionsnummer wird abgefragt, es werden keine Daten von dir gesendet). Gibt es eine, erscheint links der Button "Update verfügbar". Dort kannst du "Jetzt aktualisieren" wählen (lädt DirToy.ps1 aus dem Release, prüft sie, sichert die alte Datei als DirToy.ps1.bak-<Version> und startet neu) oder die Release-Seite im Browser öffnen. Ein Klick auf "Updates prüfen" unter dem Titel sucht von Hand; dort lässt sich die automatische Suche auch abschalten. Aufgaben im Aufgabenplaner suchen nie nach Updates.'
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
# ---- Update-Fenster (mode: new = neue Version da, current = aktuell, error = Pruefung fehlgeschlagen)
function Show-UpdateDialog($info, [string]$mode) {
    $d = New-Object System.Windows.Forms.Form
    $d.Text = 'DirToy - Update'; $d.ClientSize = New-Object System.Drawing.Size(560, 420)
    $d.FormBorderStyle = 'FixedDialog'; $d.MaximizeBox = $false; $d.MinimizeBox = $false
    $d.StartPosition = 'CenterParent'; $d.ShowInTaskbar = $false; $d.BackColor = $th.Surface; $d.ForeColor = $th.Text; $d.Font = $fNormal
    $head = switch ($mode) {
        'new' { "Neue Version verfügbar: $($info.Version)" }
        'current' { 'DirToy ist aktuell' }
        default { 'Update-Prüfung nicht möglich' }
    }
    $sub = switch ($mode) {
        'new' { "Installiert ist Version $($script:version)." }
        'current' { "Du hast die neueste Version ($($script:version))." }
        default { 'Es konnte keine Verbindung zu GitHub hergestellt werden (oder es gibt noch keinen Release).' }
    }
    $l1 = New-Label $d 24 18 512 $head $false; $l1.Font = $fBold; $l1.ForeColor = $th.Accent
    $l2 = New-Label $d 24 44 512 $sub $true
    $btnY = 366
    if ($mode -eq 'new') {
        [void](New-Label $d 24 76 512 'Änderungen' $true)
        $rb = New-Object System.Windows.Forms.RichTextBox
        $rb.ReadOnly = $true; $rb.BorderStyle = 'None'; $rb.BackColor = $th.Input; $rb.ForeColor = $th.Text; $rb.Font = $fSmall; $rb.DetectUrls = $false
        $rb.Location = New-Object System.Drawing.Point(24, 100); $rb.Size = New-Object System.Drawing.Size(512, 190)
        $notes = [string]$info.Notes; if ($notes.Length -gt 3000) { $notes = $notes.Substring(0, 3000) + ' ...' }
        $rb.Text = $(if ($notes.Trim()) { $notes } else { '(keine Beschreibung)' })
        $d.Controls.Add($rb)
    }
    $cb = New-Object System.Windows.Forms.CheckBox
    $cb.Text = 'Beim Start automatisch nach Updates suchen'; $cb.AutoSize = $true; $cb.BackColor = [System.Drawing.Color]::Transparent
    $cb.Checked = [bool](Get-Setting 'UpdateCheck' $true)
    $cb.Location = New-Object System.Drawing.Point(24, 308); $d.Controls.Add($cb)
    $script:updAction = ''
    $script:updForm = $d
    if ($mode -eq 'new') {
        $bu = New-Btn $d 24 $btnY 170 38 'Jetzt aktualisieren' $true $null
        $bw = New-Btn $d 204 $btnY 170 38 'Release-Seite' $false $th.Surface
        $bl = New-Btn $d 384 $btnY 152 38 'Später' $false $th.Surface
        $bu.Add_Click({ $script:updAction = 'install'; $script:updForm.Close() })
        $bw.Add_Click({ $script:updAction = 'web'; $script:updForm.Close() })
        $bl.Add_Click({ $script:updForm.Close() })
        $d.CancelButton = $bl
    } else {
        $bl = New-Btn $d 384 $btnY 152 38 'Schließen' $true $null
        $bl.Add_Click({ $script:updForm.Close() })
        $d.CancelButton = $bl
    }
    $d.Add_HandleCreated({
        try { $v = if ($isDark) { 1 } else { 0 }; [void][Win32.Dwm]::DwmSetWindowAttribute($script:updForm.Handle, 20, [ref]$v, 4) } catch { }
    })
    [void]$d.ShowDialog($form)
    Set-Setting 'UpdateCheck' $cb.Checked
    $d.Dispose()
    return $script:updAction
}
function Do-UpdateAction($info, [string]$action) {
    if ($action -eq 'web') { Start-Process $info.Url; return }
    if ($action -ne 'install') { return }
    if ($script:busy) { [void][System.Windows.Forms.MessageBox]::Show('Bitte erst den laufenden Vorgang beenden oder abbrechen.', 'DirToy', 'OK', 'Information'); return }
    $q = "DirToy $($info.Version) herunterladen und installieren?`n`nDie aktuelle Datei wird als DirToy.ps1.bak-$($script:version) gesichert. Danach startet DirToy neu."
    if ([System.Windows.Forms.MessageBox]::Show($q, 'DirToy - Update', 'YesNo', 'Question') -ne 'Yes') { return }
    try {
        $form.Cursor = 'WaitCursor'
        Install-Update $info $script:scriptPath ''
    } catch {
        $form.Cursor = 'Default'
        [void][System.Windows.Forms.MessageBox]::Show("Das Update ist fehlgeschlagen. Die bisherige Version bleibt unverändert.`n`n$($_.Exception.Message)", 'DirToy - Update', 'OK', 'Error')
        return
    }
    $form.Cursor = 'Default'
    Save-Tasks
    $vbs = Join-Path $PSScriptRoot 'DirToy.vbs'
    if (Test-Path $vbs) { Start-Process wscript.exe -ArgumentList "`"$vbs`"" }
    else { Start-Process powershell.exe -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-WindowStyle', 'Hidden', '-File', "`"$($script:scriptPath)`"" }
    $form.Close()
}
# Hintergrund-Pruefung: HttpClient-Task, ein Timer fragt das Ergebnis ab (Fenster bleibt bedienbar)
$script:updInfo = $null; $script:updTask = $null; $script:updManual = $false
function Start-UpdateCheck([bool]$manual) {
    if ($script:updTask -and -not $script:updTask.IsCompleted) { return }
    $script:updManual = $manual
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $c = New-Object System.Net.Http.HttpClient
        $c.Timeout = [TimeSpan]::FromSeconds(10)
        $c.DefaultRequestHeaders.UserAgent.ParseAdd('DirToy')
        $script:updTask = $c.GetStringAsync("https://api.github.com/repos/$($script:repo)/releases/latest")
        $script:updTimer.Start()
    } catch { $script:updTask = $null; if ($manual) { [void](Show-UpdateDialog $null 'error') } }
}
function Finish-UpdateCheck {
    $script:updTimer.Stop()
    $info = $null
    if ($script:updTask -and -not $script:updTask.IsFaulted -and -not $script:updTask.IsCanceled) { $info = Read-Release $script:updTask.Result }
    $script:updTask = $null
    $script:updInfo = $info
    $show = Test-NewerVersion $info
    $btnUpd.Visible = $show
    $lb.Height = $(if ($show) { 386 } else { 430 })
    if ($show) { $btnUpd.Text = "Update verfügbar: $($info.Version)" }
    if ($script:updManual) {
        $act = if ($show) { Show-UpdateDialog $info 'new' } elseif ($info) { Show-UpdateDialog $info 'current' } else { Show-UpdateDialog $null 'error' }
        Do-UpdateAction $info $act
    }
}
# ---- Ordnerbaum-Fenster: Ordner abwaehlen, die nicht synchronisiert werden sollen
function Get-ParentPath([string]$p) {
    $x = $p.TrimEnd('\'); $i = $x.LastIndexOf('\')
    if ($i -lt 0) { return '' } else { return $x.Substring(0, $i + 1) }
}
function Test-ExistsAny([string]$rel) {
    return ([System.IO.Directory]::Exists((Join-Path $script:fdRootA $rel)) -or [System.IO.Directory]::Exists((Join-Path $script:fdRootB $rel)))
}
function Test-EffExcluded([string]$path) {
    foreach ($x in $script:fdSet) { if ($path.StartsWith($x, [StringComparison]::OrdinalIgnoreCase)) { return $true } }
    return $false
}
function Test-AncExcluded([string]$path) {
    foreach ($x in $script:fdSet) { if ($path.Length -gt $x.Length -and $path.StartsWith($x, [StringComparison]::OrdinalIgnoreCase)) { return $true } }
    return $false
}
function New-TreeNodeFor([string]$text, [string]$path, [string]$kind, [string]$root) {
    $n = New-Object System.Windows.Forms.TreeNode($text)
    $n.Tag = @{ Path = $path; Kind = $kind; Root = $root; Loaded = ($kind -ne 'normal') }
    if ($kind -eq 'normal') { [void]$n.Nodes.Add((New-Object System.Windows.Forms.TreeNode('...'))) }   # Platzhalter fuer Pfeil
    return $n
}
function Fill-Nodes($coll, [string]$parentPath, [string]$root) {
    $coll.Clear()
    $abs = Join-Path $root $parentPath
    try { $dirs = @((New-Object System.IO.DirectoryInfo $abs).GetDirectories() | Sort-Object Name) } catch { $dirs = @() }
    foreach ($d in $dirs) {
        if ($d.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { continue }
        $p = $parentPath + $d.Name + '\'
        if (Test-Excluded $d.Name $script:fdPats) { [void]$coll.Add((New-TreeNodeFor ($d.Name + '   (durch Muster ausgeschlossen)') $p 'pattern' $root)) }
        else { [void]$coll.Add((New-TreeNodeFor $d.Name $p 'normal' $root)) }
    }
    # abgewaehlte Ordner, die es nirgends mehr gibt
    foreach ($x in @($script:fdSet | Sort-Object)) {
        if (Test-ExistsAny $x) { continue }
        $par = Get-ParentPath $x
        $orphan = ($par -ne '') -and -not (Test-ExistsAny $par)
        if ($parentPath -eq '' -and $orphan) { [void]$coll.Add((New-TreeNodeFor ($x.TrimEnd('\') + '   (nicht vorhanden)') $x 'missing' $root)) }
        elseif ($par -eq $parentPath -and -not $orphan) {
            $name = $x.TrimEnd('\').Substring($par.Length)
            [void]$coll.Add((New-TreeNodeFor ($name + '   (nicht vorhanden)') $x 'missing' $root))
        }
    }
}
function Update-TreeChecks($nodes) {
    foreach ($n in $nodes) {
        $tag = $n.Tag
        if ($null -eq $tag) { continue }
        $excl = ($tag.Kind -ne 'normal') -or (Test-EffExcluded $tag.Path)
        $n.Checked = -not $excl
        $n.ForeColor = $(if ($excl) { $th.Muted } else { $th.Text })
        if ($tag.Loaded -and $n.Nodes.Count -gt 0) { Update-TreeChecks $n.Nodes }
    }
}
function Refresh-Trees {
    $script:fdUpdating = $true
    try { foreach ($tv in @($script:fdTvA, $script:fdTvB)) { Update-TreeChecks $tv.Nodes } }
    finally { $script:fdUpdating = $false }
    $script:fdCount.Text = "$($script:fdSet.Count) Ordner abgewählt"
}
function Remove-MissingIn($coll, [string]$path) {
    for ($i = $coll.Count - 1; $i -ge 0; $i--) {
        $n = $coll[$i]; $tag = $n.Tag
        if ($null -eq $tag) { continue }
        if ($tag.Kind -eq 'missing' -and $tag.Path -ieq $path) { $coll.RemoveAt($i) }
        elseif ($tag.Loaded -and $n.Nodes.Count -gt 0) { Remove-MissingIn $n.Nodes $path }
    }
}
function Show-FolderDialog($t) {
    try {
        $script:fdRootA = [System.IO.Path]::GetFullPath([string]$t.A).TrimEnd('\')
        $script:fdRootB = [System.IO.Path]::GetFullPath([string]$t.B).TrimEnd('\')
    } catch { $script:fdRootA = ''; $script:fdRootB = '' }
    if (-not $t.A -or -not $t.B -or -not (Test-Path -LiteralPath $script:fdRootA -PathType Container) -or -not (Test-Path -LiteralPath $script:fdRootB -PathType Container)) {
        [void][System.Windows.Forms.MessageBox]::Show('Bitte zuerst Ordner A und Ordner B angeben (beide müssen existieren).', 'Ordner wählen')
        return
    }
    $script:fdTask = $t
    $script:fdPats = Get-Patterns $t
    $script:fdSet = Get-ExcludeDirs $t
    $script:fdUpdating = $false

    $d = New-Object System.Windows.Forms.Form
    $script:fdForm = $d
    $d.Text = 'Ordner auswählen'; $d.ClientSize = New-Object System.Drawing.Size(1000, 680); $d.StartPosition = 'CenterParent'
    $d.FormBorderStyle = 'FixedDialog'; $d.MaximizeBox = $false; $d.MinimizeBox = $false; $d.ShowInTaskbar = $false
    $d.BackColor = $th.Surface; $d.ForeColor = $th.Text; $d.Font = $fNormal
    $h = New-Object System.Windows.Forms.Label; $h.Text = 'Ordner auswählen'; $h.Font = $fBold; $h.AutoSize = $false; $h.TextAlign = 'MiddleLeft'
    [void](Add-To $d $h 20 12 700 28)
    [void](New-Label $d 20 40 960 'Haken entfernen = Ordner samt Unterordnern wird nicht synchronisiert. Neue Ordner sind standardmäßig dabei (Haken gesetzt).' $true)
    [void](New-Label $d 20 76 470 ('A:  ' + $script:fdRootA) $true)
    [void](New-Label $d 510 76 470 ('B:  ' + $script:fdRootB) $true)
    $mk = {
        param($x)
        $tv = New-Object System.Windows.Forms.TreeView
        $tv.CheckBoxes = $true; $tv.BorderStyle = 'FixedSingle'; $tv.BackColor = $th.Input; $tv.ForeColor = $th.Text; $tv.Font = $fNormal
        $tv.ShowLines = $true; $tv.ItemHeight = 24; $tv.HideSelection = $false
        [void](Add-To $d $tv $x 100 470 470)
        return $tv
    }
    $script:fdTvA = & $mk 20
    $script:fdTvB = & $mk 510
    $script:fdHint = New-Label $d 20 580 960 '' $true
    $script:fdCount = New-Label $d 20 604 500 '' $true
    $bAll = New-Btn $d 20 634 210 34 'Alle wieder einschließen' $false $th.Surface
    $bOk = New-Btn $d 770 634 100 34 'OK' $true $null
    $bCancel = New-Btn $d 880 634 100 34 'Abbrechen' $false $th.Surface

    $expand = {
        param($s, $e)
        $tag = $e.Node.Tag
        if ($null -ne $tag -and -not $tag.Loaded) {
            $tag.Loaded = $true
            Fill-Nodes $e.Node.Nodes $tag.Path $tag.Root
            Refresh-Trees
        }
    }
    $script:fdTvA.Add_BeforeExpand($expand); $script:fdTvB.Add_BeforeExpand($expand)
    $checked = {
        param($s, $e)
        if ($script:fdUpdating) { return }
        $n = $e.Node; $tag = $n.Tag
        if ($null -eq $tag) { return }
        $script:fdHint.Text = ''
        $revert = $false
        if ($tag.Kind -eq 'pattern') { $revert = $true; $script:fdHint.Text = 'Dieser Ordner ist durch ein Muster im Ausschlussfeld ausgeschlossen.' }
        elseif ($n.Checked -and (Test-AncExcluded $tag.Path)) { $revert = $true; $script:fdHint.Text = 'Ein übergeordneter Ordner ist abgewählt. Dort zuerst den Haken wieder setzen.' }
        if ($revert) { $script:fdUpdating = $true; $n.Checked = -not $n.Checked; $script:fdUpdating = $false; return }
        if ($n.Checked) {
            [void]$script:fdSet.Remove($tag.Path)
            if ($tag.Kind -eq 'missing') { Remove-MissingIn $script:fdTvA.Nodes $tag.Path; Remove-MissingIn $script:fdTvB.Nodes $tag.Path }
        } else { [void]$script:fdSet.Add($tag.Path) }
        Refresh-Trees
    }
    $script:fdTvA.Add_AfterCheck($checked); $script:fdTvB.Add_AfterCheck($checked)
    $bAll.Add_Click({
        $script:fdSet.Clear()
        Fill-Nodes $script:fdTvA.Nodes '' $script:fdRootA; Fill-Nodes $script:fdTvB.Nodes '' $script:fdRootB
        Refresh-Trees
    })
    $bOk.Add_Click({
        $script:fdTask.ExcludeDirs = [string[]]@($script:fdSet | Sort-Object)
        Save-Tasks
        $script:fdForm.DialogResult = 'OK'
    })
    $bCancel.Add_Click({ $script:fdForm.DialogResult = 'Cancel' })
    $d.Add_HandleCreated({
        try { $v = if ($isDark) { 1 } else { 0 }; [void][Win32.Dwm]::DwmSetWindowAttribute($script:fdForm.Handle, 20, [ref]$v, 4) } catch { }
    })

    Fill-Nodes $script:fdTvA.Nodes '' $script:fdRootA
    Fill-Nodes $script:fdTvB.Nodes '' $script:fdRootB
    Refresh-Trees
    [void]$d.ShowDialog($form)
    $d.Dispose()
}
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
    if ([System.Windows.Forms.MessageBox]::Show("Aufgabe '$($t.Name)' löschen?`n(Die Ordner und Dateien bleiben unverändert.)", 'Löschen', 'YesNo', 'Question') -ne 'Yes') { return }
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
    $vbs = Join-Path $PSScriptRoot 'DirToy.vbs'
    if (Test-Path $vbs) { Start-Process wscript.exe -ArgumentList "`"$vbs`"" }
    else { Start-Process powershell.exe -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-WindowStyle', 'Hidden', '-File', "`"$($script:scriptPath)`"" }
    $form.Close()
})
$btnLog.Add_Click({
    if (Test-Path $script:logFile) { Start-Process notepad.exe -ArgumentList "`"$($script:logFile)`"" }
    else { [void][System.Windows.Forms.MessageBox]::Show('Es gibt noch kein Protokoll. Es entsteht beim ersten Sync-Lauf.', 'Protokoll') }
})
$btnDirs.Add_Click({
    if (-not $script:cur) { return }
    Show-FolderDialog $script:cur; Update-DirsButton
})
$btnSched.Add_Click({
    if (-not $script:cur) { return }
    Show-ScheduleDialog $script:cur; Update-SchedLabel
})
$btnPrev.Add_Click({
    if (-not $script:cur) { return }
    $lv.Items.Clear(); Set-Busy $true
    try { [void](Run-Task $script:cur $true) } finally { $was = $script:cancel; Set-Busy $false; $lbl.Text = $(if ($was) { 'Abgebrochen.' } else { 'Vorschau fertig.' }) }
})
$btnRun.Add_Click({
    if (-not $script:cur) { return }
    $lv.Items.Clear(); Set-Busy $true
    try { [void](Run-Task $script:cur $false) } finally { $was = $script:cancel; Set-Busy $false; $lbl.Text = $(if ($was) { 'Abgebrochen.' } else { 'Fertig.' }) }
})
$btnAll.Add_Click({
    $lv.Items.Clear(); Set-Busy $true
    try { foreach ($t in @($script:tasks)) { [void](Run-Task $t $false); if ($script:cancel) { break } } }
    finally { $was = $script:cancel; Set-Busy $false; $lbl.Text = $(if ($was) { 'Abgebrochen.' } else { 'Alle Aufgaben abgearbeitet.' }) }
})
$btnCancel.Add_Click({
    $script:cancel = $true; $btnCancel.Enabled = $false; $btnCancel.Text = 'Bricht ab ...'
    $lbl.Text = 'Wird nach der aktuellen Datei abgebrochen ...'
})
$form.Add_FormClosing({
    param($s, $e)
    if ($script:busy) {
        $q = "Es läuft noch ein Vorgang.`nJetzt abbrechen und beenden?`n`nDas Programm beendet sich nach der aktuellen Datei. Es bleiben keine halben Dateien zurück."
        if ([System.Windows.Forms.MessageBox]::Show($q, 'DirToy', 'YesNo', 'Question') -eq 'Yes') { $script:cancel = $true; $script:closeRequested = $true }
        $e.Cancel = $true
    }
})

Refresh-List 0
$form.Add_Shown({
    if ([bool](Get-Setting 'UpdateCheck' $true)) { Start-UpdateCheck $false }
    if ($script:tasks.Count -eq 0) { $btnNew.PerformClick() }
})
[void]$form.ShowDialog()
Save-Tasks
