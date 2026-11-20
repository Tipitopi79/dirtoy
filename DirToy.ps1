param([switch]$NoGui, [string]$Task, [switch]$All)
# DirToy - grafisches Ordner-Synchronisationstool (Vorbild: SyncToy)
# Start: DirToy.cmd (Doppelklick)

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
$script:version = '1.7.2'
$script:bulk = $false
$script:tmpSuffix = '.dirtoy-tmp'
$script:pumpMs = 150
$script:cancel = $false
$script:inPlan = $false
$script:scanCount = 0
$script:tmpFiles = $null
$script:copyBuf = $null
# Datenordner: DirToy-Daten neben dem Programm; ist dort nicht schreibbar (z. B. C:\Program Files ohne Admin-Rechte),
# dann %APPDATA%\DirToy. Beim ersten Wechsel werden Aufgaben, Einstellungen und Zustand aus dem alten Ordner uebernommen.
function Test-DirWritable([string]$dir) {
    try {
        if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Force -Path $dir) }
        $f = Join-Path $dir ('.schreibtest-' + [guid]::NewGuid().ToString('N'))
        [System.IO.File]::WriteAllText($f, 'x'); [System.IO.File]::Delete($f)
        return $true
    } catch { return $false }
}
$script:localData = Join-Path $PSScriptRoot 'DirToy-Daten'
$script:dataFallback = $false
if ($env:DIRTOY_DATA) { $script:dataDir = $env:DIRTOY_DATA }
else {
    # Migration: Datenordner frueherer Namen -> DirToy-Daten
    try {
        if (-not (Test-Path $script:localData)) {
            foreach ($o in @('TwinSync-Daten', 'SyncTool-Daten')) {
                $old = Join-Path $PSScriptRoot $o
                if (Test-Path $old) { Rename-Item -Path $old -NewName 'DirToy-Daten'; break }
            }
        }
    } catch { }
    if (Test-DirWritable $script:localData) { $script:dataDir = $script:localData }
    else {
        $script:dataFallback = $true
        $script:dataDir = Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'DirToy'
        try {
            if (-not (Test-Path (Join-Path $script:dataDir 'aufgaben.json')) -and (Test-Path -LiteralPath $script:localData)) {
                [void](New-Item -ItemType Directory -Force -Path $script:dataDir)
                foreach ($n in 'aufgaben.json', 'einstellungen.json') {
                    $src = Join-Path $script:localData $n
                    if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src -Destination $script:dataDir -Force }
                }
                $sd = Join-Path $script:localData 'state'
                if (Test-Path -LiteralPath $sd) { Copy-Item -LiteralPath $sd -Destination $script:dataDir -Recurse -Force }
            }
        } catch { }
    }
}
$script:errLog = Join-Path $script:dataDir 'fehler.log'
$script:stateDir = Join-Path $script:dataDir 'state'
$script:taskFile = Join-Path $script:dataDir 'aufgaben.json'
New-Item -ItemType Directory -Force -Path $script:stateDir | Out-Null
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
$script:results = New-Object System.Collections.Generic.List[object]   # Ergebnisse der Laeufe fuers Ergebnis-Fenster
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
            foreach ($pn in @('Schedule', 'SchedName', 'AutoLnk')) {
                if (-not $t.PSObject.Properties[$pn]) { Add-Member -InputObject $t -NotePropertyName $pn -NotePropertyValue $(if ($pn -ne 'Schedule') { '' } else { $null }) }
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
    [pscustomobject]@{ Id = [guid]::NewGuid().ToString('N'); Name = $name; A = ''; B = ''; Mode = 0; Exclude = 'Thumbs.db;desktop.ini;~$*;*.tmp'; ExcludeDirs = [string[]]@(); Schedule = $null; SchedName = ''; AutoLnk = '' }
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
    # Was beim Einlesen auf beiden Seiten lag - Grundlage fuer den neuen Zustand nach dem Lauf
    $both = New-DirSet
    foreach ($k in $da.Keys) { if ($db.ContainsKey($k)) { [void]$both.Add($k) } }
    foreach ($k in $dsA) { if ($dsB.Contains($k)) { [void]$both.Add($k) } }
    return [pscustomobject]@{ Plan = $final; A = $rootA; B = $rootB; Pats = $pats; ExDirs = $exDirs; Both = $both; State = $state }
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
# Neuer Zustand aus dem Ergebnis des Laufs (kein erneutes Einlesen: ein anderer PC, der waehrenddessen
# im selben Ordner loescht, wuerde sonst die Liste verfaelschen und Geloeschtes kaeme zurueck).
# Erfolgreich kopiert/angelegt -> jetzt auf beiden Seiten. Fehlgeschlagen, uebersprungen oder durch Abbruch
# nicht mehr ausgefuehrt -> bleibt auf dem alten Stand, damit der naechste Lauf es richtig wiederholt.
function Save-RunState($t, $r, [bool[]]$ok) {
    $set = New-DirSet
    $set.UnionWith($r.Both)
    $plan = $r.Plan
    for ($j = 0; $j -lt $plan.Count; $j++) {
        $p = $plan[$j]
        if ($ok -and $ok[$j]) {
            switch ($p.Typ) {
                'Copy'  {
                    [void]$set.Add($p.Rel)
                    $parts = $p.Rel.Split('\'); $acc = ''
                    for ($k = 0; $k -lt $parts.Length - 1; $k++) { $acc += $parts[$k] + '\'; [void]$set.Add($acc) }
                }
                'MkDir' { [void]$set.Add($p.Rel) }
                default { [void]$set.Remove($p.Rel) }   # Delete/RmDir: jetzt auf keiner Seite mehr
            }
        } elseif ($r.State.Contains($p.Rel)) { [void]$set.Add($p.Rel) }
    }
    Save-State $t.Id $set
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

# Vollstaendige Vorschau als CSV (Semikolon, UTF-8 mit BOM: oeffnet in Excel mit richtigen Umlauten und Spalten); Rueckgabe: Pfad oder $null
function Write-PreviewFile($t, $plan) {
    try {
        $path = Join-Path $script:dataDir 'vorschau.csv'
        Remove-Item (Join-Path $script:dataDir 'vorschau.txt') -Force -ErrorAction SilentlyContinue
        $sw = New-Object System.IO.StreamWriter($path, $false, (New-Object System.Text.UTF8Encoding($true)))
        try {
            $sw.WriteLine('Aktion;Ordner;Datei;Relativer Pfad')
            foreach ($p in $plan) {
                $rel = $p.Rel
                $isDir = $rel.EndsWith('\')
                $x = $rel.TrimEnd('\'); $i = $x.LastIndexOf('\')
                $dir = if ($i -ge 0) { $x.Substring(0, $i) } else { '' }
                $name = if ($isDir) { '' } elseif ($i -ge 0) { $x.Substring($i + 1) } else { $x }
                if ($isDir) { $dir = $x }
                $cells = foreach ($c in @($p.Text, $dir, $name, $rel)) {
                    $c = [string]$c
                    if ($c.Length -gt 0 -and '=+-@'.Contains($c[0])) { $c = "'" + $c }   # Excel soll Pfade nie als Formel lesen
                    '"' + $c.Replace('"', '""') + '"'
                }
                $sw.WriteLine($cells -join ';')
            }
        } finally { $sw.Dispose() }
        return $path
    } catch { return $null }
}
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
    if ($plan.Count -eq 0) { if (-not $preview) { try { Save-RunState $t $r $null } catch { } }; [void](Add-Log "Aufgabe '$($t.Name)'" 'Bereits synchron - nichts zu tun.' ''); return @{ Copied = 0; Deleted = 0; Errors = 0 } }

    $uiMax = 2000   # mehr Zeilen machen die Liste langsam; vollstaendig steht alles im Protokoll
    if ($preview) {
        $script:bulk = $true
        if ($script:lv) { $script:lv.BeginUpdate() }
        try {
            $n = 0
            foreach ($p in $plan) { $n++; if ($n -gt $uiMax) { break }; [void](Add-Log $p.Text $p.Rel 'geplant') }
        } finally { $script:bulk = $false; if ($script:lv) { $script:lv.EndUpdate() } }
        if ($plan.Count -gt $uiMax) {
            $pf = Write-PreviewFile $t $plan
            $cnt = [ordered]@{}; foreach ($p in $plan) { if ($cnt.Contains($p.Text)) { $cnt[$p.Text]++ } else { $cnt[$p.Text] = 1 } }
            foreach ($k in $cnt.Keys) { [void](Add-Log "Insgesamt: $k" ('{0:N0} Aktion(en)' -f $cnt[$k]) '') }
            $it = Add-Log "... und $($plan.Count - $uiMax) weitere Aktionen" $(if ($pf) { '(Doppelklick: komplette Liste als CSV öffnen)' } else { "(Anzeige auf die ersten $uiMax begrenzt)" }) ''
            if ($it -and $pf) { $it.Tag = $pf }
        }
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
    $errList = New-Object System.Collections.Generic.List[string]; $script:bulk = $true
    $resItems = New-Object System.Collections.Generic.List[object]; $sum = [ordered]@{}; $bytes = [long]0; $skipped = 0; $t0 = Get-Date
    $ok = New-Object bool[] $plan.Count   # welche Aktionen erfolgreich waren (fuer den Zustand)
    foreach ($p in $plan) {
        if ($script:cancel) { $cancelled = $true; break }
        $i++
        if (([Environment]::TickCount - $lastPump) -gt 100) {
            $lastPump = [Environment]::TickCount
            if ($script:lblStatus) { $script:lblStatus.Text = "'$($t.Name)': $i / $($plan.Count)  ($([int](100 * $i / $plan.Count)) %)" }
            Set-Progress ($i / $plan.Count)
            if ($script:lv -and $script:lv.Items.Count -gt 0) {
                # Laufendes Fenster: aelteste Zeilen fliegen raus, es bleiben die letzten $uiMax (alles steht im Protokoll)
                $ex = $script:lv.Items.Count - $uiMax
                if ($ex -gt 0) { $script:lv.BeginUpdate(); try { for ($k = 0; $k -lt $ex; $k++) { $script:lv.Items.RemoveAt(0) } } finally { $script:lv.EndUpdate() } }
                $script:lv.EnsureVisible($script:lv.Items.Count - 1)
            }
            Pump
        }
        $it = $null
        $it = Add-Log $p.Text $p.Rel '...'
        try {
            $st = 'OK'
            switch ($p.Typ) {
                'Copy'     { $len = 0; try { $len = (New-Object System.IO.FileInfo $p.Src).Length } catch { }; Copy-One $p.Src $p.Dst; $copied++; $bytes += $len }
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
            if ($st -eq 'OK') { $ok[$i - 1] = $true }
            if ($st -eq 'OK') { if ($sum.Contains($p.Text)) { $sum[$p.Text]++ } else { $sum[$p.Text] = 1 } } elseif ($st -like 'übersprungen*') { $skipped++ }
            if (-not $script:headless) { $resItems.Add(@($p.Text, $p.Rel, $st)) }
            if ($it) { $it.SubItems[2].Text = $st; $it.ForeColor = (Get-StatusColor $st) }
        } catch {
            if ($_.Exception.Message -eq 'DIRTOY_CANCEL') {
                $cancelled = $true
                if ($script:logOn) { Write-LogLine $p.Text $p.Rel 'abgebrochen (Zieldatei unverändert)' }
                if (-not $script:headless) { $resItems.Add(@($p.Text, $p.Rel, 'abgebrochen')) }
                if ($it) { $it.SubItems[2].Text = 'abgebrochen'; $it.ForeColor = (Get-StatusColor 'abgebrochen') }
                break
            }
            $errors++
            $emsg = 'FEHLER: ' + $_.Exception.Message
            if ($errList.Count -lt 50) { $errList.Add($p.Text + ' | ' + $p.Rel + ' | ' + $emsg) }
            if (-not $script:headless) { $resItems.Add(@($p.Text, $p.Rel, $emsg)) }
            if ($it) {
                if ($script:logOn) { Write-LogLine $p.Text $p.Rel $emsg }
                $it.SubItems[2].Text = $emsg; $it.ForeColor = (Get-StatusColor 'FEHLER')
            } else { [void](Add-Log $p.Text $p.Rel $emsg) }   # Fehler immer anzeigen (Add-Log schreibt auch ins Protokoll)
        }
    }
    $script:bulk = $false
    $script:results.Add([pscustomobject]@{ Name = [string]$t.Name; Items = $resItems; Sum = $sum; Copied = $copied; Deleted = $deleted; Errors = $errors; Skipped = $skipped; Bytes = $bytes; Seconds = ((Get-Date) - $t0).TotalSeconds; Cancelled = $cancelled })
    if ($plan.Count -gt $uiMax) {
        if ($script:lv) { $script:lv.BeginUpdate(); try { while ($script:lv.Items.Count -gt $uiMax) { $script:lv.Items.RemoveAt(0) } } finally { $script:lv.EndUpdate() } }
        [void](Add-Log "Anzeige zeigt nur die letzten $uiMax Aktionen" 'Alle Aktionen stehen im Protokoll (sync.log)' '')
        if ($errList.Count -gt 0) { [void](Add-Log "Fehler dieses Laufs ($errors, höchstens 50 hier gelistet)" '' ''); foreach ($e in $errList) { [void](Add-Log $e '' '') } }
    }
    try { Save-RunState $t $r $ok } catch { [void](Add-Log 'Warnung' 'Zustand konnte nicht gespeichert werden' $_.Exception.Message) }
    if ($cancelled) {
        [void](Add-Log "Aufgabe '$($t.Name)' abgebrochen" "$copied kopiert, $deleted gelöscht, $errors Fehler - Lauf unvollständig, keine halben Dateien" '')
        return @{ Copied = $copied; Deleted = $deleted; Errors = $errors; Cancelled = $true }
    }
    Set-Progress 1
    [void](Add-Log "Aufgabe '$($t.Name)' fertig" "$copied kopiert, $deleted gelöscht, $errors Fehler" '')
    return @{ Copied = $copied; Deleted = $deleted; Errors = $errors }
}

# ---------------------------------------------------------------- Aufgabenplaner
$script:schedPath = '\DirToy\'
function Get-SchedText($s) {
    if (-not $s) { return 'Kein Zeitplan' }
    $dn = @{ Monday='Mo'; Tuesday='Di'; Wednesday='Mi'; Thursday='Do'; Friday='Fr'; Saturday='Sa'; Sunday='So' }
    $rep = if ([bool]$s.Repeat -and [int]$s.Type -le 1) { ", dann alle $($s.RepMinutes) Min. für $($s.RepHours) Std." } else { '' }
    switch ([int]$s.Type) {
        0 { "täglich um $($s.Time)$rep" }
        1 { 'wöchentlich ' + ((@($s.Days) | ForEach-Object { $dn[[string]$_] }) -join ',') + " um $($s.Time)$rep" }
        2 { "alle $($s.Minutes) Minuten" + $(if ([bool]$s.Start2) { " ab $($s.Time)" } else { '' }) }
        3 { 'bei Anmeldung' }
    }
}
# Autostart-Verknuepfung (Notloesung ohne Aufgabenplaner) entfernen
function Remove-AutoLnk($t) {
    if ($t.AutoLnk) { Remove-Item -LiteralPath ([string]$t.AutoLnk) -Force -ErrorAction SilentlyContinue }
    $t.AutoLnk = ''
}
# Liest die Aufgabe nach dem Anlegen zurueck und prueft sie; liefert $null (alles in Ordnung) oder einen Fehlertext
function Test-SchedRegistered([string]$name, [string]$id, [bool]$rep) {
    try { $st = Get-ScheduledTask -TaskPath $script:schedPath -TaskName $name -ErrorAction Stop }
    catch { return 'Die Aufgabe ist nach dem Anlegen im Windows-Aufgabenplaner nicht zu finden.' }
    $a = @($st.Actions)
    if ($a.Count -eq 0 -or ([string]$a[0].Arguments) -notlike "*$id*") { return 'Die angelegte Aufgabe enthält nicht den erwarteten Startbefehl.' }
    $tr = @($st.Triggers)
    if ($tr.Count -eq 0) { return 'Die angelegte Aufgabe hat keinen Auslöser (Zeitpunkt).' }
    if ($rep -and -not [string]$tr[0].Repetition.Interval) { return 'Die Wiederholung wurde nicht übernommen.' }
    return $null
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
    Remove-AutoLnk $t
}
# Legt den Zeitplan $s fuer die Aufgabe an, liest ihn zurueck und prueft ihn. Bei Fehlern wird eine Ausnahme geworfen
# und die Aufgabe ($t) bleibt unveraendert; nur bei Erfolg werden Schedule/SchedName gesetzt.
function Register-Sched($t, $s) {
    $name = 'DirToy - ' + (([string]$t.Name -replace '[\\/:*?"<>|]', '_').Trim())
    $user = "$env:USERDOMAIN\$env:USERNAME"
    $arg = "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$($script:scriptPath)`" -Task `"$($t.Id)`""
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arg
    $hm = ([string]$s.Time).Split(':')
    $at = [datetime]::Today.AddHours([int]$hm[0]).AddMinutes([int]$hm[1])
    $rep = ([bool]$s.Repeat -and [int]$s.Type -le 1)
    switch ([int]$s.Type) {
        0 { $trg = New-ScheduledTaskTrigger -Daily -At $at }
        1 { $trg = New-ScheduledTaskTrigger -Weekly -DaysOfWeek ([string[]]@($s.Days)) -At $at }
        2 { $at2 = if ([bool]$s.Start2) { $at } else { (Get-Date).AddMinutes(1) }
            $trg = New-ScheduledTaskTrigger -Once -At $at2 -RepetitionInterval (New-TimeSpan -Minutes ([int]$s.Minutes)) -RepetitionDuration (New-TimeSpan -Days 3650) }
        3 { $trg = New-ScheduledTaskTrigger -AtLogOn -User $user }
    }
    if ($rep) {
        # Tages-/Wochen-Trigger kennt in PowerShell 5.1 keine Wiederholung: sie wird von einem Einmal-Trigger uebernommen
        $r = New-ScheduledTaskTrigger -Once -At $at -RepetitionInterval (New-TimeSpan -Minutes ([int]$s.RepMinutes)) -RepetitionDuration (New-TimeSpan -Hours ([int]$s.RepHours))
        $trg.Repetition = $r.Repetition
    }
    # Wiederholungen/Intervalle werden nicht nachgeholt; Zeitplaene mit fester Uhrzeit und Anmeldung schon
    $noCatchUp = ($rep -or [int]$s.Type -eq 2)
    $sp = @{ AllowStartIfOnBatteries = $true; DontStopIfGoingOnBatteries = $true; MultipleInstances = 'IgnoreNew'; ExecutionTimeLimit = (New-TimeSpan -Hours 12) }
    if (-not $noCatchUp) { $sp.StartWhenAvailable = $true }
    $set = New-ScheduledTaskSettingsSet @sp
    $pri = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
    [void](Register-ScheduledTask -TaskName $name -TaskPath $script:schedPath -Action $action -Trigger $trg -Settings $set -Principal $pri -Description "DirToy: $($t.Name)" -Force -ErrorAction Stop)
    $bad = Test-SchedRegistered $name ([string]$t.Id) $rep
    if ($bad) {
        Unregister-ScheduledTask -TaskPath $script:schedPath -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue
        throw $bad
    }
    if ($t.SchedName -and $t.SchedName -ne $name) {
        Unregister-ScheduledTask -TaskPath $script:schedPath -TaskName $t.SchedName -Confirm:$false -ErrorAction SilentlyContinue
    }
    $t.SchedName = $name
    $t.Schedule = $s
    Remove-AutoLnk $t
}
# Fertiger schtasks-Befehl (fuer die Eingabeaufforderung) zum manuellen Anlegen
function Get-SchtasksCommand($t, $s) {
    $name = 'DirToy - ' + (([string]$t.Name -replace '[\\/:*?"<>|]', '_').Trim())
    $tr = "powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File \`"$($script:scriptPath)\`" -Task $($t.Id)"
    $c = "schtasks /Create /TN `"$name`" /TR `"$tr`" /F"
    $dm = @{ Monday='MON'; Tuesday='TUE'; Wednesday='WED'; Thursday='THU'; Friday='FRI'; Saturday='SAT'; Sunday='SUN' }
    switch ([int]$s.Type) {
        0 { $c += " /SC DAILY /ST $($s.Time)" }
        1 { $c += " /SC WEEKLY /D " + ((@($s.Days) | ForEach-Object { $dm[[string]$_] }) -join ',') + " /ST $($s.Time)" }
        2 { $c += " /SC MINUTE /MO $([int]$s.Minutes)" + $(if ([bool]$s.Start2) { " /ST $($s.Time)" } else { '' }) }
        3 { $c += ' /SC ONLOGON' }
    }
    if ([bool]$s.Repeat -and [int]$s.Type -le 1) { $c += " /RI $([int]$s.RepMinutes) /DU {0:00}:00" -f [int]$s.RepHours }
    return $c
}
# Programm-Icon (64 px, PNG als Base64; die Mehrgroessen-Datei DirToy.ico liegt fuer Verknuepfungen daneben)
$script:iconB64 = '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'
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

# ---- Listen: Sortieren per Klick auf die Spaltenkoepfe, Markieren und Kopieren (Strg+C, Rechtsklick)
if (-not ('DirToyLvSorter' -as [type])) {
    Add-Type -ReferencedAssemblies System.Windows.Forms -TypeDefinition @'
using System;
using System.Collections;
using System.Windows.Forms;
public class DirToyLvSorter : IComparer {
    public int Col; public bool Asc;
    public int Compare(object a, object b) {
        string x = ((ListViewItem)a).SubItems[Col].Text, y = ((ListViewItem)b).SubItems[Col].Text;
        int r = string.Compare(x, y, StringComparison.CurrentCultureIgnoreCase);
        return Asc ? r : -r;
    }
}
'@
}
function Copy-ListRows($lv, [bool]$all) {
    $items = if ($all) { @($lv.Items) } else { @($lv.SelectedItems) }
    if ($items.Count -eq 0) { return }
    $sb = New-Object System.Text.StringBuilder
    foreach ($it in $items) { [void]$sb.AppendLine((@($it.SubItems | ForEach-Object { $_.Text }) -join "`t")) }
    try { [System.Windows.Forms.Clipboard]::SetText($sb.ToString()) } catch { }
}
function Select-AllRows($lv) { $lv.BeginUpdate(); try { foreach ($i in $lv.Items) { $i.Selected = $true } } finally { $lv.EndUpdate() } }
function Set-ListBehavior($lv, [bool]$sortable, [int]$rowH) {
    $lv.View = 'Details'; $lv.FullRowSelect = $true; $lv.BorderStyle = 'None'; $lv.OwnerDraw = $true; $lv.Font = $fSmall
    $lv.BackColor = $th.Surface; $lv.ForeColor = $th.Text
    $lv.HeaderStyle = $(if ($sortable) { 'Clickable' } else { 'Nonclickable' })
    $il = New-Object System.Windows.Forms.ImageList; $il.ImageSize = New-Object System.Drawing.Size(1, $rowH); $lv.SmallImageList = $il
    $lv.Tag = @{ Col = -1; Asc = $true }
    $lv.Add_DrawColumnHeader({
        param($s, $e)
        $br = New-Object System.Drawing.SolidBrush($script:th.Surface); $e.Graphics.FillRectangle($br, $e.Bounds); $br.Dispose()
        $pen = New-Object System.Drawing.Pen($script:th.Border)
        $e.Graphics.DrawLine($pen, $e.Bounds.Left, $e.Bounds.Bottom - 1, $e.Bounds.Right, $e.Bounds.Bottom - 1); $pen.Dispose()
        $r = New-Object System.Drawing.Rectangle(($e.Bounds.X + 12), $e.Bounds.Y, ($e.Bounds.Width - 14), $e.Bounds.Height)
        $fl = [System.Windows.Forms.TextFormatFlags]::VerticalCenter -bor [System.Windows.Forms.TextFormatFlags]::Left
        $txt = $e.Header.Text.ToUpper()
        $st = $s.Tag
        if ($st -and $st.Col -eq $e.ColumnIndex) { $txt += $(if ($st.Asc) { ' ' + [char]0x25B2 } else { ' ' + [char]0x25BC }) }
        [System.Windows.Forms.TextRenderer]::DrawText($e.Graphics, $txt, $s.Font, $r, $script:th.Muted, $fl)
    })
    $lv.Add_DrawItem({ param($s, $e) })
    $lv.Add_DrawSubItem({
        param($s, $e)
        $bg = if ($e.Item.Selected) { $script:th.SelBg } else { $script:th.Surface }
        $br = New-Object System.Drawing.SolidBrush($bg); $e.Graphics.FillRectangle($br, $e.Bounds); $br.Dispose()
        $r = New-Object System.Drawing.Rectangle(($e.Bounds.X + 12), $e.Bounds.Y, ($e.Bounds.Width - 14), $e.Bounds.Height)
        $col = if ($e.ColumnIndex -eq ($s.Columns.Count - 1)) { $e.Item.ForeColor } else { $script:th.Text }
        $fl = [System.Windows.Forms.TextFormatFlags]::VerticalCenter -bor [System.Windows.Forms.TextFormatFlags]::EndEllipsis -bor [System.Windows.Forms.TextFormatFlags]::Left -bor [System.Windows.Forms.TextFormatFlags]::NoPrefix
        [System.Windows.Forms.TextRenderer]::DrawText($e.Graphics, $e.SubItem.Text, $s.Font, $r, $col, $fl)
    })
    if ($sortable) {
        $lv.Add_ColumnClick({
            param($s, $e)
            if ($script:busy) { return }
            $st = $s.Tag
            if ($st.Col -eq $e.Column) { $st.Asc = -not $st.Asc } else { $st.Col = $e.Column; $st.Asc = $true }
            $so = New-Object DirToyLvSorter; $so.Col = $e.Column; $so.Asc = $st.Asc
            $s.ListViewItemSorter = $so
            $s.Invalidate()
        })
    }
    $lv.Add_KeyDown({
        param($s, $e)
        if ($e.Control -and $e.KeyCode -eq 'C') { Copy-ListRows $s $false; $e.SuppressKeyPress = $true }
        elseif ($e.Control -and $e.KeyCode -eq 'A') { Select-AllRows $s; $e.SuppressKeyPress = $true }
    })
    $cm = New-Object System.Windows.Forms.ContextMenuStrip
    $m1 = $cm.Items.Add('Markierte Zeilen kopieren (Strg+C)'); $m2 = $cm.Items.Add('Alle Zeilen kopieren'); $m3 = $cm.Items.Add('Alles markieren (Strg+A)')
    $m1.Add_Click({ Copy-ListRows $this.Owner.SourceControl $false })
    $m2.Add_Click({ Copy-ListRows $this.Owner.SourceControl $true })
    $m3.Add_Click({ Select-AllRows $this.Owner.SourceControl })
    $lv.ContextMenuStrip = $cm
}
# Liste leeren und Sortierung zuruecksetzen (neue Zeilen kommen sonst an sortierter Stelle statt am Ende)
function Clear-Log {
    $script:lv.ListViewItemSorter = $null
    if ($script:lv.Tag) { $script:lv.Tag.Col = -1 }
    $script:lv.Items.Clear(); $script:lv.Invalidate()
}

# ---- Ergebnis-Fenster nach einem Lauf (Zusammenfassung wie bei SyncToy, Details sortier- und kopierbar)
function Format-Bytes([long]$b) {
    if ($b -ge 1GB) { return ('{0:N1} GB' -f ($b / 1GB)) }
    if ($b -ge 1MB) { return ('{0:N1} MB' -f ($b / 1MB)) }
    if ($b -ge 1KB) { return ('{0:N0} KB' -f ($b / 1KB)) }
    return "$b Bytes"
}
function Write-ResultFile($results) {
    try {
        $path = Join-Path $script:dataDir 'ergebnis.csv'
        $sw = New-Object System.IO.StreamWriter($path, $false, (New-Object System.Text.UTF8Encoding($true)))
        try {
            $sw.WriteLine('Aufgabe;Aktion;Ordner;Datei;Relativer Pfad;Status')
            foreach ($r in $results) {
                foreach ($it in $r.Items) {
                    $rel = [string]$it[1]; $isDir = $rel.EndsWith('\')
                    $x = $rel.TrimEnd('\'); $i = $x.LastIndexOf('\')
                    $dir = if ($i -ge 0) { $x.Substring(0, $i) } else { '' }
                    $name = if ($isDir) { '' } elseif ($i -ge 0) { $x.Substring($i + 1) } else { $x }
                    if ($isDir) { $dir = $x }
                    $cells = foreach ($c in @($r.Name, $it[0], $dir, $name, $rel, $it[2])) {
                        $c = [string]$c
                        if ($c.Length -gt 0 -and '=+-@'.Contains($c[0])) { $c = "'" + $c }
                        '"' + $c.Replace('"', '""') + '"'
                    }
                    $sw.WriteLine($cells -join ';')
                }
            }
        } finally { $sw.Dispose() }
        return $path
    } catch { return $null }
}
function Show-ResultDialog($results) {
    $multi = (@($results).Count -gt 1)
    $d = New-Object System.Windows.Forms.Form
    $d.Text = 'DirToy - Ergebnis'; $d.ClientSize = New-Object System.Drawing.Size(840, 620); $d.MinimumSize = New-Object System.Drawing.Size(620, 460)
    $d.StartPosition = 'CenterParent'; $d.ShowInTaskbar = $false; $d.BackColor = $th.Surface; $d.ForeColor = $th.Text; $d.Font = $fNormal
    $h = New-Object System.Windows.Forms.Label; $h.Font = $fBold; $h.AutoSize = $false; $h.TextAlign = 'MiddleLeft'; $h.BackColor = [System.Drawing.Color]::Transparent
    $h.Text = if ($multi) { "Ergebnis - $(@($results).Count) Aufgaben" } else { "Ergebnis - '$(@($results)[0].Name)'" }
    [void](Add-To $d $h 20 12 800 28)

    # Zusammenfassung
    $sv = New-Object System.Windows.Forms.ListView
    [void]$sv.Columns.Add('Zusammenfassung', 600); [void]$sv.Columns.Add('Anzahl', 180)
    Set-ListBehavior $sv $false 26
    $addRow = { param($a, $b, $col, $bold)
        $i = New-Object System.Windows.Forms.ListViewItem($a); [void]$i.SubItems.Add($b); $i.ForeColor = $col
        if ($bold) { $i.Font = $fBold }
        [void]$sv.Items.Add($i)
    }
    $tot = [pscustomobject]@{ Err = 0; Cancel = $false }
    foreach ($r in $results) {
        if ($multi) { & $addRow $r.Name '' $th.Text $true }
        foreach ($k in $r.Sum.Keys) { & $addRow ('   ' + $k) ('{0:N0}' -f $r.Sum[$k]) $th.Text $false }
        if ($r.Skipped -gt 0) { & $addRow '   Übersprungen' ('{0:N0}' -f $r.Skipped) $th.Muted $false }
        if ($r.Errors -gt 0) { & $addRow '   Fehler' ('{0:N0}' -f $r.Errors) $th.Err $false; $tot.Err += $r.Errors }
        $ts = [timespan]::FromSeconds([math]::Round($r.Seconds))
        & $addRow ('   Dauer ' + $ts.ToString('hh\:mm\:ss') + ', kopierte Datenmenge ' + (Format-Bytes $r.Bytes)) '' $th.Muted $false
        if ($r.Cancelled) { & $addRow '   Der Lauf wurde abgebrochen (unvollständig, keine halben Dateien)' '' $th.Err $false; $tot.Cancel = $true }
    }
    [void](Add-To $d $sv 20 46 800 170); $sv.Anchor = $A_TLR

    $l2 = New-Label $d 20 226 800 'Einzelne Aktionen (Fehler zuerst). Spaltenkopf anklicken zum Sortieren, Strg+C kopiert die markierten Zeilen.' $true
    $l2.Anchor = $A_TLR
    # Details (Fehler zuerst, hoechstens 2000 Zeilen)
    $dv = New-Object System.Windows.Forms.ListView
    if ($multi) { [void]$dv.Columns.Add('Aufgabe', 140) }
    [void]$dv.Columns.Add('Aktion', 210); [void]$dv.Columns.Add('Datei', 300); [void]$dv.Columns.Add('Status', 170)
    Set-ListBehavior $dv $true 26
    $max = 2000; $n = 0; $total = 0
    foreach ($r in $results) { $total += $r.Items.Count }
    $dv.BeginUpdate()
    foreach ($pass in 1, 2) {
        foreach ($r in $results) {
            foreach ($it in $r.Items) {
                $isErr = ([string]$it[2] -like 'FEHLER*')
                if (($pass -eq 1) -ne $isErr) { continue }
                if ($n -ge $max) { break }
                $cells = [string[]]$(if ($multi) { @($r.Name, $it[0], $it[1], $it[2]) } else { @($it[0], $it[1], $it[2]) })
                $li = New-Object System.Windows.Forms.ListViewItem($cells[0])
                for ($c = 1; $c -lt $cells.Count; $c++) { [void]$li.SubItems.Add($cells[$c]) }
                $li.ForeColor = Get-StatusColor ([string]$it[2])
                [void]$dv.Items.Add($li); $n++
            }
        }
    }
    $dv.EndUpdate()
    if ($total -gt $n) {
        $cells = [string[]]$(if ($multi) { @('', "... und $($total - $n) weitere Aktionen", '(komplette Liste: Button "Details als CSV öffnen")', '') } else { @("... und $($total - $n) weitere Aktionen", '(komplette Liste: Button "Details als CSV öffnen")', '') })
        $li = New-Object System.Windows.Forms.ListViewItem($cells[0]); for ($c = 1; $c -lt $cells.Count; $c++) { [void]$li.SubItems.Add($cells[$c]) }
        $li.ForeColor = $th.Muted; [void]$dv.Items.Add($li)
    }
    [void](Add-To $d $dv 20 250 800 300); $dv.Anchor = $A_ALL
    $dv.Add_Resize({
        $f = $this; $w = $f.ClientSize.Width; $last = $f.Columns.Count - 1
        $others = 0; for ($i = 0; $i -lt $f.Columns.Count; $i++) { if ($i -ne $last - 1) { $others += $f.Columns[$i].Width } }
        $nw = $w - $others; if ($nw -gt 150) { $f.Columns[$last - 1].Width = $nw }
    })

    $script:resList = $results
    $b1 = New-Btn $d 20 566 210 38 'Details als CSV öffnen' $false $th.Surface; $b1.Anchor = $A_BL
    $b2 = New-Btn $d 720 566 100 38 'Schließen' $true $null; $b2.Anchor = $A_BR
    $b1.Add_Click({
        $f = Write-ResultFile $script:resList
        if ($f) { try { Start-Process -FilePath $f -ErrorAction Stop } catch { Start-Process notepad.exe -ArgumentList "`"$f`"" } }
        else { [void][System.Windows.Forms.MessageBox]::Show('Die CSV-Datei konnte nicht geschrieben werden.', 'DirToy', 'OK', 'Warning') }
    })
    $script:resClose = $b2
    $b2.Add_Click({ $script:resClose.FindForm().Close() })
    $d.CancelButton = $b2
    $d.Add_HandleCreated({
        try { $v = if ($isDark) { 1 } else { 0 }; [void][Win32.Dwm]::DwmSetWindowAttribute($script:resClose.FindForm().Handle, 20, [ref]$v, 4) } catch { }
    })
    [void]$d.ShowDialog($form)
    $d.Dispose()
}
function Show-ResultsIfNeeded {
    if ($script:closeRequested -or -not [bool](Get-Setting 'ShowResult' $true)) { return }
    $list = @($script:results | Where-Object { ($_.Copied + $_.Deleted + $_.Errors + $_.Skipped) -gt 0 -or $_.Cancelled })
    if ($list.Count -eq 0) { return }
    Show-ResultDialog $list
}

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

# ---- Anleitung, wenn der Zeitplan nicht angelegt werden konnte (z. B. ohne Admin-Rechte)
function Show-ManualSchedDialog($t, $s, [string]$err, $owner) {
    $cmd = Get-SchtasksCommand $t $s
    $name = 'DirToy - ' + (([string]$t.Name -replace '[\\/:*?"<>|]', '_').Trim())
    $psArgs = "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$($script:scriptPath)`" -Task `"$($t.Id)`""
    $wann = Get-SchedText $s
    $txt = @(
        'Der Zeitplan konnte NICHT im Windows-Aufgabenplaner angelegt werden. DirToy hat daher nichts eingetragen.',
        '',
        "Grund: $err",
        '',
        'Meist fehlen auf diesem Rechner die nötigen Rechte. So geht es trotzdem von Hand:',
        '',
        'Möglichkeit 1 - Befehl (am einfachsten)',
        '  1. Windows-Taste drücken, "cmd" tippen, Enter (Eingabeaufforderung).',
        '  2. Button "Befehl kopieren" klicken, im Fenster mit Rechtsklick einfügen, Enter.',
        '',
        'Möglichkeit 2 - Aufgabenplaner-Fenster (Button "Aufgabenplaner öffnen")',
        ('  1. Rechts "Aufgabe erstellen ..." wählen. Name: ' + $name),
        ('  2. Reiter "Trigger" > Neu: ' + $wann),
        '  3. Reiter "Aktionen" > Neu > Programm starten:',
        '       Programm:  powershell.exe',
        ('       Argumente: ' + $psArgs),
        '       (Button "Argumente kopieren")',
        '  4. Mit OK speichern.',
        '',
        'Möglichkeit 3 - Notlösung ohne Aufgabenplaner',
        '  Button "Beim Anmelden starten": DirToy führt die Aufgabe dann bei jeder Windows-Anmeldung einmal aus (Autostart-Ordner).',
        '  Ein zeitlicher Plan oder ein Intervall ist damit nicht möglich.'
    ) -join "`r`n"
    $f = New-Object System.Windows.Forms.Form
    $f.Text = 'Zeitplan von Hand anlegen'; $f.ClientSize = New-Object System.Drawing.Size(640, 520); $f.StartPosition = 'CenterParent'
    $f.FormBorderStyle = 'FixedDialog'; $f.MaximizeBox = $false; $f.MinimizeBox = $false; $f.ShowInTaskbar = $false
    $f.BackColor = $th.Surface; $f.ForeColor = $th.Text; $f.Font = $fNormal
    $tb = New-Object System.Windows.Forms.TextBox; $tb.Multiline = $true; $tb.ReadOnly = $true; $tb.ScrollBars = 'Vertical'; $tb.BorderStyle = 'FixedSingle'
    $tb.BackColor = $th.Input; $tb.ForeColor = $th.Text; $tb.Font = $fNormal; $tb.Text = $txt
    [void](Add-To $f $tb 16 14 608 396)
    $tb.Select(0, 0)
    $b1 = New-Btn $f 16 424 140 34 'Befehl kopieren' $true $null
    $b2 = New-Btn $f 164 424 160 34 'Argumente kopieren' $false $th.Surface
    $b3 = New-Btn $f 332 424 190 34 'Aufgabenplaner öffnen' $false $th.Surface
    $b4 = New-Btn $f 530 424 94 34 'Schließen' $false $th.Surface
    $b5 = New-Btn $f 16 468 250 34 'Beim Anmelden starten' $false $th.Surface
    $script:mCmd = $cmd; $script:mArgs = $psArgs; $script:mTask = $t
    $b1.Add_Click({ try { [System.Windows.Forms.Clipboard]::SetText($script:mCmd); [void][System.Windows.Forms.MessageBox]::Show('Der Befehl liegt in der Zwischenablage.', 'DirToy') } catch { } })
    $b2.Add_Click({ try { [System.Windows.Forms.Clipboard]::SetText($script:mArgs); [void][System.Windows.Forms.MessageBox]::Show('Die Argumente liegen in der Zwischenablage.', 'DirToy') } catch { } })
    $b3.Add_Click({ try { Start-Process 'taskschd.msc' } catch { [void][System.Windows.Forms.MessageBox]::Show('Der Aufgabenplaner ließ sich nicht öffnen (Windows-Taste, "Aufgabenplanung" tippen).', 'DirToy') } })
    $b4.Add_Click({ $b4.FindForm().Close() })
    $b5.Add_Click({
        $lnk = New-AutostartLink $script:mTask
        if ($lnk) { Save-Tasks; [void][System.Windows.Forms.MessageBox]::Show("Eingerichtet. DirToy führt die Aufgabe ab jetzt bei jeder Windows-Anmeldung aus.`n`n$lnk", 'DirToy') }
        else { [void][System.Windows.Forms.MessageBox]::Show('Der Eintrag im Autostart-Ordner ließ sich nicht anlegen.', 'DirToy', 'OK', 'Warning') }
    })
    $f.Add_HandleCreated({ try { $v = if ($isDark) { 1 } else { 0 }; [void][Win32.Dwm]::DwmSetWindowAttribute($this.Handle, 20, [ref]$v, 4) } catch { } })
    [void]$f.ShowDialog($owner)
    $f.Dispose()
}
# ---- Zeitplan-Dialog
function Show-ScheduleDialog($t) {
    $d = New-Object System.Windows.Forms.Form
    $d.Text = 'Zeitplan'; $d.ClientSize = New-Object System.Drawing.Size(470, 448); $d.StartPosition = 'CenterParent'
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
    $script:dLblMin = New-Label $d 20 114 140 'Intervall in Minuten' $true
    $script:dMin = New-Object System.Windows.Forms.NumericUpDown; $script:dMin.Minimum = 1; $script:dMin.Maximum = 1440; $script:dMin.Value = 60
    $script:dMin.BackColor = $th.Input; $script:dMin.ForeColor = $th.Text
    [void](Add-To $d $script:dMin 20 136 120 28)
    # Wiederholung (nur bei Taeglich/Woechentlich): danach alle X Minuten fuer Y Stunden
    $script:dRep = New-Object System.Windows.Forms.CheckBox; $script:dRep.Text = 'Danach wiederholen alle'; $script:dRep.AutoSize = $false; $script:dRep.ForeColor = $th.Text
    [void](Add-To $d $script:dRep 20 176 168 28)
    $script:dRepMin = New-Object System.Windows.Forms.NumericUpDown; $script:dRepMin.Minimum = 1; $script:dRepMin.Maximum = 1440; $script:dRepMin.Value = 20
    $script:dRepMin.BackColor = $th.Input; $script:dRepMin.ForeColor = $th.Text
    [void](Add-To $d $script:dRepMin 192 176 62 28)
    $script:dRepL1 = New-Label $d 260 181 62 'Min. für' $false
    $script:dRepHr = New-Object System.Windows.Forms.NumericUpDown; $script:dRepHr.Minimum = 1; $script:dRepHr.Maximum = 24; $script:dRepHr.Value = 10
    $script:dRepHr.BackColor = $th.Input; $script:dRepHr.ForeColor = $th.Text
    [void](Add-To $d $script:dRepHr 326 176 56 28)
    $script:dRepL2 = New-Label $d 388 181 60 'Std.' $false
    $script:dLblDays = New-Label $d 20 216 300 'Wochentage' $true
    $script:dDays = @(); $names = @('Mo', 'Di', 'Mi', 'Do', 'Fr', 'Sa', 'So'); $en = @('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday')
    for ($k = 0; $k -lt 7; $k++) {
        $cb = New-Object System.Windows.Forms.CheckBox; $cb.Text = $names[$k]; $cb.Tag = $en[$k]; $cb.AutoSize = $false; $cb.ForeColor = $th.Text
        [void](Add-To $d $cb (20 + $k * 60) 238 58 26); $script:dDays += $cb
    }
    [void](New-Label $d 20 276 430 'Windows-Meldung nach dem Lauf' $true)
    $script:dNotify = New-Object System.Windows.Forms.ComboBox; $script:dNotify.DropDownStyle = 'DropDownList'; $script:dNotify.FlatStyle = 'Flat'
    $script:dNotify.BackColor = $th.Input; $script:dNotify.ForeColor = $th.Text
    foreach ($x in @('Keine Meldung', 'Wenn etwas synchronisiert wurde oder Fehler auftraten', 'Nur bei Fehlern')) { [void]$script:dNotify.Items.Add($x) }
    [void](Add-To $d $script:dNotify 20 298 430 28)
    $script:dInfo = New-Label $d 20 342 430 '' $true
    $script:dInfo.Height = 36
    $script:dSave = New-Btn $d 20 394 140 34 'Aktivieren' $true $null
    $script:dRemove = New-Btn $d 170 394 160 34 'Zeitplan entfernen' $false $th.Surface
    $script:dCancel = New-Btn $d 340 394 110 34 'Abbrechen' $false $th.Surface
    $script:dTask = $t

    # vorhandene Werte laden
    $sc = $t.Schedule
    # Startzeit beim Intervall: bei neuen Zeitplaenen und Altbestand ohne Startzeit ist der Vorschlag "jetzt"
    $script:dNowSet = [bool]($sc -and [int]$sc.Type -eq 2 -and [bool]$sc.Start2)
    $script:dType.SelectedIndex = if ($sc) { [int]$sc.Type } else { 0 }
    $script:dNotify.SelectedIndex = if ($sc -and $null -ne $sc.Notify) { [int]$sc.Notify } else { 1 }
    if ($sc) {
        try { $hm = ([string]$sc.Time).Split(':'); $script:dTime.Value = [datetime]::Today.AddHours([int]$hm[0]).AddMinutes([int]$hm[1]) } catch { }
        if ($sc.Minutes) { $script:dMin.Value = [int]$sc.Minutes }
        foreach ($cb in $script:dDays) { $cb.Checked = (@($sc.Days) -contains $cb.Tag) }
        if ([bool]$sc.Repeat) {
            $script:dRep.Checked = $true
            if ($sc.RepMinutes) { $script:dRepMin.Value = [int]$sc.RepMinutes }
            if ($sc.RepHours) { $script:dRepHr.Value = [int]$sc.RepHours }
        }
    } else { $script:dTime.Value = [datetime]::Today.AddHours(22); foreach ($cb in $script:dDays) { $cb.Checked = ($cb.Tag -notin @('Saturday', 'Sunday')) } }
    $script:dRemove.Enabled = [bool]$t.SchedName
    if ($t.SchedName) { $script:dSave.Text = 'Speichern' }

    $upd = {
        $ty = $script:dType.SelectedIndex
        $script:dLblTime.Visible = $script:dTime.Visible = ($ty -ge 0 -and $ty -le 2)
        # Beim Intervall steht die Startzeit rechts neben dem Intervall, sonst an der Stelle der Uhrzeit
        $tx = if ($ty -eq 2) { 170 } else { 20 }
        $script:dLblTime.Location = New-Object System.Drawing.Point($tx, 114); $script:dTime.Location = New-Object System.Drawing.Point($tx, 136)
        $script:dLblTime.Text = if ($ty -eq 2) { 'Startzeit (erster Lauf)' } else { 'Uhrzeit' }
        $script:dLblMin.Visible = $script:dMin.Visible = ($ty -eq 2)
        if ($ty -eq 2 -and -not $script:dNowSet) { $script:dNowSet = $true; $script:dTime.Value = [datetime]::Now }
        $vis = ($ty -ge 0 -and $ty -le 1)
        $on = ($vis -and $script:dRep.Checked)
        $script:dRep.Visible = $script:dRepMin.Visible = $script:dRepHr.Visible = $script:dRepL1.Visible = $script:dRepL2.Visible = $vis
        $script:dRepMin.Enabled = $script:dRepHr.Enabled = $on
        $script:dLblDays.Visible = ($ty -eq 1); foreach ($cb in $script:dDays) { $cb.Visible = ($ty -eq 1) }
        $script:dInfo.Text = if ($ty -eq 2 -or $on) { 'Die Aufgabe läuft im Hintergrund, solange du angemeldet bist. Verpasste Läufe werden bei Intervallen nicht nachgeholt.' }
                             else { 'Die Aufgabe läuft im Hintergrund, solange du angemeldet bist. Verpasste Läufe werden nachgeholt.' }
    }
    $script:dType.Add_SelectedIndexChanged($upd)
    $script:dRep.Add_CheckedChanged($upd)
    $script:dType.SelectedIndex = -1; $script:dType.SelectedIndex = if ($sc) { [int]$sc.Type } else { 0 }

    $script:dSave.Add_Click({
        $ty = $script:dType.SelectedIndex
        $days = @($script:dDays | Where-Object { $_.Checked } | ForEach-Object { [string]$_.Tag })
        if ($ty -eq 1 -and $days.Count -eq 0) { [void][System.Windows.Forms.MessageBox]::Show('Bitte mindestens einen Wochentag wählen.', 'Zeitplan'); return }
        $rp = ($ty -le 1 -and $script:dRep.Checked)
        if ($rp -and [int]$script:dRepMin.Value -gt [int]$script:dRepHr.Value * 60) { [void][System.Windows.Forms.MessageBox]::Show('Das Intervall darf nicht länger sein als der Zeitraum.', 'Zeitplan'); return }
        $tt = $script:dTask
        $new = [pscustomobject]@{ Type = $ty; Time = $script:dTime.Value.ToString('HH:mm'); Days = $days; Minutes = [int]$script:dMin.Value; Start2 = ($ty -eq 2); Repeat = $rp; RepMinutes = [int]$script:dRepMin.Value; RepHours = [int]$script:dRepHr.Value; Notify = $script:dNotify.SelectedIndex }
        try { Register-Sched $tt $new; Save-Tasks; $script:dSave.FindForm().DialogResult = 'OK' }
        catch { Show-ManualSchedDialog $tt $new $_.Exception.Message $script:dSave.FindForm() }
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
    } elseif ($t.SchedName) { $script:lblSched.Text = 'ACHTUNG: Zeitplan im Aufgabenplaner nicht vorhanden - bitte "Zeitplan ..." neu aktivieren' }
    elseif ($t.AutoLnk -and (Test-Path -LiteralPath ([string]$t.AutoLnk))) { $script:lblSched.Text = 'Läuft bei jeder Windows-Anmeldung (Autostart-Ordner)' }
    elseif ($t.Schedule) { $script:lblSched.Text = 'ACHTUNG: Zeitplan ist nicht angelegt - bitte "Zeitplan ..." neu aktivieren' }
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
        if ($p) { [void][System.Windows.Forms.MessageBox]::Show("Die Verknüpfung wurde auf dem Desktop angelegt:`n$p", 'DirToy', 'OK', 'Information') }
        else { [void][System.Windows.Forms.MessageBox]::Show('Die Verknüpfung konnte nicht angelegt werden.', 'DirToy', 'OK', 'Warning') }
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
# Startet DirToy neu (Design-Wechsel, Update); der Aufrufer schliesst danach das Fenster
function Restart-DirToy {
    $c = Get-LaunchCommand
    Start-Process -FilePath $c.File -ArgumentList $c.Args
}
# Startbefehl ohne aufblitzendes Konsolenfenster: conhost.exe --headless (Windows 10 ab 2004 / 11), sonst PowerShell direkt
function Get-LaunchCommand {
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $psArgs = "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$($script:scriptPath)`""
    $ch = Join-Path $env:SystemRoot 'System32\conhost.exe'
    if ((Test-Path $ch) -and [Environment]::OSVersion.Version.Build -ge 19041) {
        return @{ File = $ch; Args = "--headless `"$ps`" $psArgs" }
    }
    return @{ File = $ps; Args = $psArgs }
}
# Legt eine Verknuepfung auf dem Desktop an (startet DirToy ohne Konsolenfenster-Dauerzustand)
function Get-DesktopDir { if ($env:DIRTOY_DESKTOP) { return $env:DIRTOY_DESKTOP } else { return [Environment]::GetFolderPath('Desktop') } }
function New-DesktopShortcut {
    try {
        $dir = Split-Path $script:scriptPath
        $lnk = Join-Path (Get-DesktopDir) 'DirToy.lnk'
        $ws = New-Object -ComObject WScript.Shell
        $sc = $ws.CreateShortcut($lnk)
        $c = Get-LaunchCommand
        $sc.TargetPath = $c.File
        $sc.Arguments = $c.Args
        $sc.WorkingDirectory = $dir
        $sc.WindowStyle = 7
        $sc.Description = 'DirToy - Ordner synchron halten'
        $ico = Join-Path $dir 'DirToy.ico'
        if (Test-Path $ico) { $sc.IconLocation = $ico }
        $sc.Save()
        return $lnk
    } catch { return $null }
}
# Notloesung ohne Aufgabenplaner: Verknuepfung im Autostart-Ordner startet die Aufgabe bei jeder Anmeldung
function New-AutostartLink($t) {
    try {
        $dir = if ($env:DIRTOY_STARTUP) { $env:DIRTOY_STARTUP } else { [Environment]::GetFolderPath('Startup') }
        $lnk = Join-Path $dir (('DirToy - ' + ([string]$t.Name -replace '[\\/:*?"<>|]', '_').Trim()) + '.lnk')
        $ws = New-Object -ComObject WScript.Shell
        $sc = $ws.CreateShortcut($lnk)
        $c = Get-LaunchCommand
        $sc.TargetPath = $c.File
        $sc.Arguments = $c.Args + " -Task `"$($t.Id)`""
        $sc.WorkingDirectory = Split-Path $script:scriptPath
        $sc.WindowStyle = 7
        $sc.Description = "DirToy: $($t.Name)"
        $sc.Save()
        $t.AutoLnk = $lnk
        return $lnk
    } catch { return $null }
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
    Restart-DirToy

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
    Restart-DirToy

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
    Clear-Log; Set-Busy $true
    try { [void](Run-Task $script:cur $true) } finally { $was = $script:cancel; Set-Busy $false; $lbl.Text = $(if ($was) { 'Abgebrochen.' } else { 'Vorschau fertig.' }) }
})
$btnRun.Add_Click({
    if (-not $script:cur) { return }
    Clear-Log; $script:results.Clear(); Set-Busy $true
    try { [void](Run-Task $script:cur $false) } finally { $was = $script:cancel; Set-Busy $false; $lbl.Text = $(if ($was) { 'Abgebrochen.' } else { 'Fertig.' }) }
    Show-ResultsIfNeeded
})
$btnAll.Add_Click({
    Clear-Log; $script:results.Clear(); Set-Busy $true
    try { foreach ($t in @($script:tasks)) { [void](Run-Task $t $false); if ($script:cancel) { break } } }
    finally { $was = $script:cancel; Set-Busy $false; $lbl.Text = $(if ($was) { 'Abgebrochen.' } else { 'Alle Aufgaben abgearbeitet.' }) }
    Show-ResultsIfNeeded
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
    # Beim allerersten Start einmal anbieten, eine Desktop-Verknuepfung anzulegen (startet ohne aufblitzendes Fenster)
    if (-not [bool](Get-Setting 'ShortcutAsked' $false)) {
        Set-Setting 'ShortcutAsked' $true
        $lnkPath = Join-Path (Get-DesktopDir) 'DirToy.lnk'
        if (-not (Test-Path $lnkPath)) {
            $q = "Willkommen bei DirToy!`n`nSoll eine Verknüpfung mit Icon auf dem Desktop angelegt werden?`nDamit startet DirToy künftig ohne aufblitzendes Fenster.`n`n(Später jederzeit über Hilfe → Desktop-Verknüpfung.)"
            if ([System.Windows.Forms.MessageBox]::Show($q, 'DirToy', 'YesNo', 'Question') -eq 'Yes') {
                $made = New-DesktopShortcut
                if (-not $made) { [void][System.Windows.Forms.MessageBox]::Show('Die Verknüpfung konnte nicht angelegt werden.', 'DirToy', 'OK', 'Warning') }
            }
        }
    }
    # Zeitplaene pruefen: gespeichert, aber im Windows-Aufgabenplaner nicht vorhanden?
    $missing = @($script:tasks | Where-Object {
        ($_.SchedName -and -not (Get-SchedInfo $_)) -or ($_.Schedule -and -not $_.SchedName -and -not ($_.AutoLnk -and (Test-Path -LiteralPath ([string]$_.AutoLnk))))
    } | ForEach-Object { [string]$_.Name })
    if ($missing.Count -gt 0) {
        $q = "Für diese Aufgaben ist ein Zeitplan gespeichert, er ist aber im Windows-Aufgabenplaner nicht vorhanden. Sie laufen daher NICHT automatisch:`n`n  " + ($missing -join "`n  ") + "`n`nBitte die Aufgabe wählen und unter `"Zeitplan ...`" neu aktivieren. Falls das nicht geht, zeigt DirToy dort eine Anleitung zum manuellen Anlegen."
        [void][System.Windows.Forms.MessageBox]::Show($q, 'DirToy - Zeitplan', 'OK', 'Warning')
    }
    if ([bool](Get-Setting 'UpdateCheck' $true)) { Start-UpdateCheck $false }
    if ($script:tasks.Count -eq 0) { $btnNew.PerformClick() }
})
[void]$form.ShowDialog()
Save-Tasks
