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
$script:version = '1.7.6'
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
    catch {
        # Nicht lesbar heisst nicht "leer": sonst wuerde der Inhalt auf der anderen Seite geloescht
        if ($rel -eq '') { throw "Ordner nicht lesbar, es wurde nichts verändert: $($dir.FullName) ($($_.Exception.Message))" }
        [void]$script:unread.Add($rel)
        $script:warn.Add("$($dir.FullName): nicht lesbar, auf beiden Seiten wird hier nichts verändert ($($_.Exception.Message))"); return
    }
    foreach ($e in $entries) {
        $script:scanCount++
        if (($script:scanCount % 300) -eq 0) {
            Out-Status "Lese Ordner ein ... ($($script:scanCount) Einträge)"
            Pump
            if ($script:inPlan -and (Test-Cancel)) { throw 'DIRTOY_CANCEL' }
        }
        if ($e -isnot [System.IO.DirectoryInfo] -and $e.Name.EndsWith($script:tmpSuffix, [StringComparison]::OrdinalIgnoreCase)) {
            if ($null -ne $script:tmpFiles) { $script:tmpFiles.Add($e.FullName) }
            continue
        }
        if (Test-Excluded $e.Name $pats) { continue }
        if ($e -is [System.IO.DirectoryInfo]) {
            if ($e.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { [void]$script:unread.Add($rel + $e.Name + '\'); continue }   # Verknuepfung: nicht eingelesen, also auch nichts ableiten
            if ($script:exDirs -and $script:exDirs.Contains($rel + $e.Name + '\')) { continue }   # im Ordnerbaum abgewaehlt
            if ($dirs) { [void]$dirs.Add($rel + $e.Name + '\') }
            Scan-Dir $e ($rel + $e.Name + '\') $pats $dict $dirs
        } else {
            $dict[$rel + $e.Name] = $e
        }
    }
}
# Liegt der Eintrag in (oder ist er selbst) ein Ordner, der auf einer Seite nicht eingelesen werden konnte?
function Test-Unread([string]$rel, $unread) {
    foreach ($u in $unread) { if ($rel.StartsWith($u, [StringComparison]::OrdinalIgnoreCase)) { return $true } }
    return $false
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
    $unread = New-DirSet; $script:unread = $unread
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
            Out-Status "Vergleiche ... $idx / $total"
            Pump
            if (Test-Cancel) { throw 'DIRTOY_CANCEL' }
        }
        if ($unread.Count -and (Test-Unread $rel $unread)) { continue }
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
        if ($unread.Count -and (Test-Unread $dk $unread)) { continue }
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
    # Nicht eingelesene Bereiche behalten ihren alten Stand
    if ($unread.Count) { foreach ($k in $state) { if (Test-Unread $k $unread) { [void]$both.Add($k) } } }
    # Auffaellig viele Loeschungen: eine Seite ist ganz leer, oder mehr als die Haelfte (ab 10 Dateien) soll weg
    $mass = ''
    foreach ($s in @(@('A', $rootA, $da.Count, 'B', $db.Count), @('B', $rootB, $db.Count, 'A', $da.Count))) {
        $pre = $s[1] + '\'; $nd = 0
        foreach ($p in $plan) { if ($p.Typ -eq 'Delete' -and $p.Src.StartsWith($pre, [StringComparison]::OrdinalIgnoreCase)) { $nd++ } }
        if ($nd -gt 0 -and $s[4] -eq 0) { $mass = "Ordner $($s[3]) enthält keine Dateien, in Ordner $($s[0]) würden $nd von $($s[2]) Dateien gelöscht." }
        elseif ($nd -ge 10 -and 2 * $nd -gt $s[2]) { $mass = "In Ordner $($s[0]) würden $nd von $($s[2]) Dateien gelöscht." }
    }
    return [pscustomobject]@{ Mass = $mass; Plan = $final; A = $rootA; B = $rootB; Pats = $pats; ExDirs = $exDirs; Both = $both; State = $state }
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
            if (Test-Cancel) { throw 'DIRTOY_CANCEL' }
            if (([Environment]::TickCount - $last) -ge $script:pumpMs) {
                $last = [Environment]::TickCount
                if ($total -gt 8MB) { Out-Status "Kopiere $([System.IO.Path]::GetFileName($src)): $([int](100 * $done / $total)) %" }
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
function Add-Log([string]$aktion, [string]$datei, [string]$status) {
    if ($script:logOn -and $status -ne '...') { Write-LogLine $aktion $datei $status }
    return (Out-Row $aktion $datei $status)
}

# ---- Meldestellen: Nur hierueber spricht der Kern mit der Aussenwelt. Das hier ist die Fassung ohne Fenster;
# gui\06c-sync-thread.ps1 ersetzt diese Funktionen im Sync-Thread durch die Fassung mit Fenster.
function Out-Status([string]$text) { }                                # Statuszeile
function Set-Progress([double]$frac) { }                              # Fortschritt 0..1
function Out-Row([string]$aktion, [string]$datei, [string]$status) {  # neue Zeile; Rueckgabe: Zeile oder $null
    Write-Host "$aktion | $datei | $status"
    return $null
}
function Set-RowStatus($row, [string]$status) { }                     # Status einer Zeile aendern
function Set-RowFile($row, [string]$path) { }                         # Datei, die ein Doppelklick auf die Zeile oeffnet
function Start-Bulk { }                                               # viele Zeilen am Stueck: Anfang ...
function Stop-Bulk { }                                                # ... und Ende
function Limit-Rows([int]$max, [bool]$scroll) { }                     # hoechstens $max Zeilen behalten, aelteste zuerst weg
function Test-Cancel { return $script:cancel }                         # Abbruch gewuenscht?
function Pump { }                                                     # Oberflaeche zwischendurch bedienen
function Ask-User([string]$text, [string]$title, [bool]$defaultNo) { return $false }   # Rueckfrage; ohne Fenster immer Nein
# Breite des Fortschrittsbalkens (0.0/1.0: mit 0/1 rundet PowerShell auf ganze Zahlen)
function Get-BarWidth([int]$width, [double]$frac) { return [int]($width * [math]::Max(0.0, [math]::Min(1.0, $frac))) }

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
    Out-Status "Analysiere '$($t.Name)' ..."
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
        if ($r.Mass) { [void](Add-Log 'Warnung' "Auffällig viele Löschungen: $($r.Mass)" 'bitte prüfen') }
        $script:bulk = $true
        Start-Bulk
        try {
            $n = 0
            foreach ($p in $plan) { $n++; if ($n -gt $uiMax) { break }; [void](Add-Log $p.Text $p.Rel 'geplant') }
        } finally { $script:bulk = $false; Stop-Bulk }
        if ($plan.Count -gt $uiMax) {
            $pf = Write-PreviewFile $t $plan
            $cnt = [ordered]@{}; foreach ($p in $plan) { if ($cnt.Contains($p.Text)) { $cnt[$p.Text]++ } else { $cnt[$p.Text] = 1 } }
            foreach ($k in $cnt.Keys) { [void](Add-Log "Insgesamt: $k" ('{0:N0} Aktion(en)' -f $cnt[$k]) '') }
            $it = Add-Log "... und $($plan.Count - $uiMax) weitere Aktionen" $(if ($pf) { '(Doppelklick: komplette Liste als CSV öffnen)' } else { "(Anzeige auf die ersten $uiMax begrenzt)" }) ''
            if ($it -and $pf) { Set-RowFile $it $pf }
        }
        [void](Add-Log "Aufgabe '$($t.Name)'" "Vorschau: $($plan.Count) Aktion(en), davon $dels Löschung(en)" '')
        return $null
    }
    if ($r.Mass -and $NoGui) {
        # Zeitplan: niemand kann nachfragen, also nichts veraendern
        [void](Add-Log "Aufgabe '$($t.Name)'" "Abgebrochen, nichts wurde verändert. $($r.Mass) Wenn das gewollt ist, die Aufgabe einmal von Hand starten." 'FEHLER: Auffällig viele Löschungen')
        return $null
    }
    if ($r.Mass) {
        $ans = (Ask-User "Aufgabe '$($t.Name)': Auffällig viele Löschungen!`n`n$($r.Mass)`n`nIst das richtige Laufwerk verbunden und der richtige Ordner gewählt?`nTrotzdem löschen? (Papierkorb, sofern möglich)" 'Auffällig viele Löschungen' $true)
        if (-not $ans) { [void](Add-Log "Aufgabe '$($t.Name)'" '' 'Abgebrochen.'); return $null }
    }
    elseif ($dels -gt 0 -and -not $NoGui) {
        $ans = (Ask-User "Aufgabe '$($t.Name)': $dels Datei(en)/Ordner werden gelöscht (Papierkorb, sofern möglich).`nFortfahren?" 'Löschen bestätigen' $false)
        if (-not $ans) { [void](Add-Log "Aufgabe '$($t.Name)'" '' 'Abgebrochen.'); return $null }
    }
    $copied = 0; $deleted = 0; $errors = 0; $i = 0; $cancelled = $false; $lastPump = [Environment]::TickCount - 1000
    $errList = New-Object System.Collections.Generic.List[string]; $script:bulk = $true
    $resItems = New-Object System.Collections.Generic.List[object]; $sum = [ordered]@{}; $bytes = [long]0; $skipped = 0; $t0 = Get-Date
    $ok = New-Object bool[] $plan.Count   # welche Aktionen erfolgreich waren (fuer den Zustand)
    foreach ($p in $plan) {
        if (Test-Cancel) { $cancelled = $true; break }
        $i++
        if (([Environment]::TickCount - $lastPump) -gt 100) {
            $lastPump = [Environment]::TickCount
            Out-Status "'$($t.Name)': $i / $($plan.Count)  ($([int](100 * $i / $plan.Count)) %)"
            Set-Progress ($i / $plan.Count)
            Limit-Rows $uiMax $true   # laufendes Fenster: es bleiben die letzten $uiMax (alles steht im Protokoll)
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
            if ($it) { Set-RowStatus $it $st }
        } catch {
            if ($_.Exception.Message -eq 'DIRTOY_CANCEL') {
                $cancelled = $true
                if ($script:logOn) { Write-LogLine $p.Text $p.Rel 'abgebrochen (Zieldatei unverändert)' }
                if (-not $script:headless) { $resItems.Add(@($p.Text, $p.Rel, 'abgebrochen')) }
                if ($it) { Set-RowStatus $it 'abgebrochen' }
                break
            }
            $errors++
            $emsg = 'FEHLER: ' + $_.Exception.Message
            if ($errList.Count -lt 50) { $errList.Add($p.Text + ' | ' + $p.Rel + ' | ' + $emsg) }
            if (-not $script:headless) { $resItems.Add(@($p.Text, $p.Rel, $emsg)) }
            if ($it) {
                if ($script:logOn) { Write-LogLine $p.Text $p.Rel $emsg }
                Set-RowStatus $it $emsg
            } else { [void](Add-Log $p.Text $p.Rel $emsg) }   # Fehler immer anzeigen (Add-Log schreibt auch ins Protokoll)
        }
    }
    $script:bulk = $false
    $script:results.Add([pscustomobject]@{ Name = [string]$t.Name; Items = $resItems; Sum = $sum; Copied = $copied; Deleted = $deleted; Errors = $errors; Skipped = $skipped; Bytes = $bytes; Seconds = ((Get-Date) - $t0).TotalSeconds; Cancelled = $cancelled })
    if ($plan.Count -gt $uiMax) {
        Limit-Rows $uiMax $false
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
# Pruefung der Update-Signatur. Der Schluessel ($script:signingCert, Datei 16-signierschluessel.ps1) ist fest eingebaut;
# der private Teil liegt nur beim Entwickler (siehe tools\neuer-schluessel.ps1), nicht bei GitHub.

# Zeilenenden vereinheitlichen (CRLF -> LF), damit die Signatur unabhaengig von Git-Zeilenenden gilt.
# Latin1 bildet jedes Byte 1:1 auf ein Zeichen ab, es geht also nichts verloren.
function Convert-ForSignature([byte[]]$bytes) {
    $enc = [System.Text.Encoding]::GetEncoding(28591)
    return ,$enc.GetBytes($enc.GetString($bytes).Replace("`r`n", "`n"))
}

# $true nur, wenn $sigB64 (Base64, RSA-SHA256/PKCS1) eine gueltige Signatur von $data mit dem eingebauten Schluessel ist.
function Test-UpdateSignature([byte[]]$data, [string]$sigB64) {
    if (-not $script:signingCert) { throw 'Es ist kein Signaturschluessel eingebaut, Updates koennen nicht geprueft werden.' }
    try { $sig = [Convert]::FromBase64String(([string]$sigB64).Trim()) } catch { return $false }
    $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 (,[Convert]::FromBase64String($script:signingCert))
    $rsa = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPublicKey($cert)
    try {
        return [bool]$rsa.VerifyData((Convert-ForSignature $data), $sig, [System.Security.Cryptography.HashAlgorithmName]::SHA256, [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
    } catch { return $false } finally { $rsa.Dispose() }
}
if ($NoGui) { return }
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml
# Kern-Funktionen merken (Name und Text): der Sync-Thread bekommt genau diese, nicht die Datei auf der Platte
# (die koennte inzwischen durch ein Update ersetzt sein)
$script:coreFns = @(Get-ChildItem function: | Where-Object { $_.ScriptBlock.File -eq $PSCommandPath } | ForEach-Object { , @($_.Name, $_.Definition) })

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
    $script:th = @{ Bg = (C '#2D2D30'); Surface = (C '#3A3A3D'); Input = (C '#28282B'); Text = (C '#F2F2F2'); Muted = (C '#B4B4B4')
        Border = (C '#5A5A5E'); Accent = (C '#4CC2FF'); AccentText = (C '#000000'); AccentHover = (C '#7AD2FF'); SelBg = (C '#4A4A4F')
        Ok = (C '#6CCB5F'); Err = (C '#FF99A4') }
} else {
    $script:th = @{ Bg = (C '#F3F3F3'); Surface = (C '#FFFFFF'); Input = (C '#FFFFFF'); Text = (C '#1B1B1B'); Muted = (C '#6B6B6B')
        Border = (C '#D6D6D6'); Accent = (C '#0067C0'); AccentText = (C '#FFFFFF'); AccentHover = (C '#1A7FD6'); SelBg = (C '#E5F1FB')
        Ok = (C '#0F7B0F'); Err = (C '#C42B1C') }
}
$th = $script:th
# ---- Klassen, Stile und Dialog-Grundlage (WPF)
if (-not ('DirToyRow' -as [type])) {
    Add-Type -ReferencedAssemblies PresentationCore, PresentationFramework, WindowsBase, System.Xaml, System.Windows.Forms -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Windows.Media;
public class DirToyItem : INotifyPropertyChanged {
    public event PropertyChangedEventHandler PropertyChanged;
    protected void Raise(string n) { if (PropertyChanged != null) PropertyChanged(this, new PropertyChangedEventArgs(n)); }
}
public class DirToyRow : DirToyItem {
    string st; Brush br;
    public string Icon { get; set; } public Brush IconBrush { get; set; }
    public string Aktion { get; set; } public string Datei { get; set; } public string Task { get; set; } public string File { get; set; }
    public string Status { get { return st; } set { st = value; Raise("Status"); } }
    public Brush StatusBrush { get { return br; } set { br = value; Raise("StatusBrush"); } }
}
public class DirToyTask : DirToyItem {
    string n, s; Brush d;
    public string Id { get; set; }
    public string Name { get { return n; } set { n = value; Raise("Name"); } }
    public string Sub { get { return s; } set { s = value; Raise("Sub"); } }
    public Brush Dot { get { return d; } set { d = value; Raise("Dot"); } }
    public override string ToString() { return n; }
}
public class DirToyNode : DirToyItem {
    bool c; Brush b;
    public DirToyNode() { Nodes = new System.Collections.ObjectModel.ObservableCollection<DirToyNode>(); }
    public string Text { get; set; } public string Path { get; set; } public string Kind { get; set; } public string Root { get; set; } public bool Loaded { get; set; }
    public System.Collections.ObjectModel.ObservableCollection<DirToyNode> Nodes { get; set; }
    public bool Checked { get { return c; } set { c = value; Raise("Checked"); } }
    public Brush Brush { get { return b; } set { b = value; Raise("Brush"); } }
}
public class DirToyOwner : System.Windows.Forms.IWin32Window {
    public IntPtr H; public IntPtr Handle { get { return H; } }
}
'@
}
$script:styles = @'
    <sys:Double x:Key="{x:Static SystemParameters.VerticalScrollBarButtonHeightKey}">72</sys:Double>
    <Style x:Key="Icon" TargetType="TextBlock">
      <Setter Property="FontFamily" Value="Segoe MDL2 Assets"/><Setter Property="VerticalAlignment" Value="Center"/><Setter Property="FontSize" Value="15"/><Setter Property="TextOptions.TextRenderingMode" Value="Grayscale"/>
    </Style>
    <Style x:Key="MutedText" TargetType="TextBlock"><Setter Property="Foreground" Value="{DynamicResource Muted}"/><Setter Property="FontSize" Value="12"/></Style>
    <Style TargetType="Button">
      <Setter Property="Foreground" Value="{DynamicResource Text}"/><Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderBrush" Value="{DynamicResource Border}"/><Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="16,0"/><Setter Property="Height" Value="38"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
        <Grid>
          <Border x:Name="b" CornerRadius="8" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}"/>
          <Border x:Name="h" CornerRadius="8" Background="{DynamicResource Text}" Opacity="0"/>
          <ContentPresenter Margin="{TemplateBinding Padding}" HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}" VerticalAlignment="Center" RecognizesAccessKey="False"/>
        </Grid>
        <ControlTemplate.Triggers>
          <Trigger Property="IsMouseOver" Value="True">
            <Trigger.EnterActions><BeginStoryboard><Storyboard><DoubleAnimation Storyboard.TargetName="h" Storyboard.TargetProperty="Opacity" To="0.10" Duration="0:0:0.12"/></Storyboard></BeginStoryboard></Trigger.EnterActions>
            <Trigger.ExitActions><BeginStoryboard><Storyboard><DoubleAnimation Storyboard.TargetName="h" Storyboard.TargetProperty="Opacity" To="0" Duration="0:0:0.2"/></Storyboard></BeginStoryboard></Trigger.ExitActions>
          </Trigger>
          <Trigger Property="IsPressed" Value="True"><Setter TargetName="b" Property="Opacity" Value="0.75"/></Trigger>
          <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.45"/><Setter Property="Cursor" Value="Arrow"/></Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style x:Key="Primary" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
      <Setter Property="Background" Value="{DynamicResource Accent}"/><Setter Property="Foreground" Value="{DynamicResource AccentText}"/>
      <Setter Property="BorderThickness" Value="0"/><Setter Property="FontWeight" Value="SemiBold"/>
    </Style>
    <Style x:Key="Ghost" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
      <Setter Property="BorderThickness" Value="0"/><Setter Property="Padding" Value="10,0"/><Setter Property="HorizontalContentAlignment" Value="Left"/>
    </Style>
    <Style TargetType="TextBox">
      <Setter Property="Background" Value="{DynamicResource Input}"/><Setter Property="Foreground" Value="{DynamicResource Text}"/><Setter Property="CaretBrush" Value="{DynamicResource Text}"/>
      <Setter Property="BorderBrush" Value="{DynamicResource Border}"/><Setter Property="Height" Value="34"/><Setter Property="SelectionBrush" Value="{DynamicResource Accent}"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/><Setter Property="Padding" Value="4,0"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="TextBox">
        <Border x:Name="b" CornerRadius="8" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1">
          <ScrollViewer x:Name="PART_ContentHost" Margin="{TemplateBinding Padding}" VerticalAlignment="Center"/></Border>
        <ControlTemplate.Triggers>
          <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="b" Property="BorderBrush" Value="{DynamicResource Accent}"/></Trigger>
          <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.5"/></Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style x:Key="Seg" TargetType="RadioButton">
      <Setter Property="Foreground" Value="{DynamicResource Text}"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="RadioButton">
        <Border x:Name="b" CornerRadius="6" Background="Transparent" Padding="14,0" Height="30" Margin="3">
          <ContentPresenter VerticalAlignment="Center" HorizontalAlignment="Center"/></Border>
        <ControlTemplate.Triggers>
          <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="{DynamicResource SelBg}"/></Trigger>
          <Trigger Property="IsChecked" Value="True"><Setter TargetName="b" Property="Background" Value="{DynamicResource Accent}"/><Setter Property="Foreground" Value="{DynamicResource AccentText}"/></Trigger>
          <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.5"/></Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style TargetType="ScrollBar">
      <Setter Property="Background" Value="Transparent"/><Setter Property="Width" Value="10"/><Setter Property="MinWidth" Value="10"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ScrollBar">
        <Track x:Name="PART_Track" Orientation="Vertical" IsDirectionReversed="True"><Track.Thumb><Thumb MinHeight="36"><Thumb.Template><ControlTemplate TargetType="Thumb">
          <Border CornerRadius="4" Margin="2" Background="{DynamicResource Border}"/></ControlTemplate></Thumb.Template></Thumb></Track.Thumb></Track>
      </ControlTemplate></Setter.Value></Setter>
      <Style.Triggers><Trigger Property="Orientation" Value="Horizontal"><Setter Property="Width" Value="Auto"/><Setter Property="Height" Value="10"/>
        <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ScrollBar">
          <Track x:Name="PART_Track"><Track.Thumb><Thumb MinWidth="36"><Thumb.Template><ControlTemplate TargetType="Thumb"><Border CornerRadius="4" Margin="2" Background="{DynamicResource Border}"/></ControlTemplate></Thumb.Template></Thumb></Track.Thumb></Track>
        </ControlTemplate></Setter.Value></Setter></Trigger></Style.Triggers>
    </Style>
    <Style TargetType="ToolTip"><Setter Property="Background" Value="{DynamicResource Surface}"/><Setter Property="Foreground" Value="{DynamicResource Text}"/><Setter Property="BorderBrush" Value="{DynamicResource Border}"/></Style>
    <Style x:Key="PlainList" TargetType="ListBox">
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ListBox"><Grid x:Name="g"><ScrollViewer Focusable="False"><ItemsPresenter/></ScrollViewer></Grid>
        <ControlTemplate.Triggers><Trigger Property="IsEnabled" Value="False"><Setter TargetName="g" Property="Opacity" Value="0.6"/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style TargetType="ListBoxItem">
      <Setter Property="Foreground" Value="{DynamicResource Text}"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ListBoxItem">
        <Border x:Name="b" CornerRadius="8" Padding="12,9" Margin="0,1" Background="Transparent"><ContentPresenter/></Border>
        <ControlTemplate.Triggers>
          <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="{DynamicResource SelBg}"/></Trigger>
          <Trigger Property="IsSelected" Value="True"><Setter TargetName="b" Property="Background" Value="{DynamicResource SelBg}"/></Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style TargetType="ListViewItem">
      <Setter Property="HorizontalContentAlignment" Value="Stretch"/><Setter Property="Foreground" Value="{DynamicResource Text}"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ListViewItem">
        <Border x:Name="b" Background="Transparent" Padding="6,5" BorderBrush="{DynamicResource Border}" BorderThickness="0,0,0,0.5"><GridViewRowPresenter VerticalAlignment="Center"/></Border>
        <ControlTemplate.Triggers>
          <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="{DynamicResource Hover}"/></Trigger>
          <Trigger Property="IsSelected" Value="True"><Setter TargetName="b" Property="Background" Value="{DynamicResource SelBg}"/></Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style TargetType="GridViewColumnHeader">
      <Setter Property="Foreground" Value="{DynamicResource Muted}"/><Setter Property="FontSize" Value="12"/><Setter Property="HorizontalContentAlignment" Value="Left"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="GridViewColumnHeader">
        <Border Background="Transparent" Padding="12,7"><ContentPresenter/></Border></ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style TargetType="CheckBox">
      <Setter Property="Foreground" Value="{DynamicResource Text}"/><Setter Property="Cursor" Value="Hand"/><Setter Property="VerticalContentAlignment" Value="Center"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="CheckBox">
        <StackPanel Orientation="Horizontal" Background="Transparent">
          <Border x:Name="b" Width="18" Height="18" CornerRadius="4" BorderThickness="1.5" BorderBrush="{DynamicResource Muted}" Background="{DynamicResource Input}" VerticalAlignment="Center"><TextBlock x:Name="t" Text="&#xE73E;" FontFamily="Segoe MDL2 Assets" FontSize="12" Foreground="{DynamicResource AccentText}" HorizontalAlignment="Center" VerticalAlignment="Center" Visibility="Hidden"/></Border>
          <ContentPresenter Margin="8,0,0,0" VerticalAlignment="Center"/></StackPanel>
        <ControlTemplate.Triggers>
          <Trigger Property="IsChecked" Value="True"><Setter TargetName="t" Property="Visibility" Value="Visible"/><Setter TargetName="b" Property="Background" Value="{DynamicResource Accent}"/><Setter TargetName="b" Property="BorderBrush" Value="{DynamicResource Accent}"/></Trigger>
          <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.45"/></Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style x:Key="Chip" TargetType="CheckBox">
      <Setter Property="Foreground" Value="{DynamicResource Text}"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="CheckBox">
        <Border x:Name="b" CornerRadius="8" Width="50" Height="34" Margin="0,0,8,0" Background="{DynamicResource Input}" BorderBrush="{DynamicResource Border}" BorderThickness="1"><ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>
        <ControlTemplate.Triggers><Trigger Property="IsChecked" Value="True"><Setter TargetName="b" Property="Background" Value="{DynamicResource Accent}"/><Setter Property="Foreground" Value="{DynamicResource AccentText}"/></Trigger></ControlTemplate.Triggers>
      </ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style TargetType="RadioButton">
      <Setter Property="Foreground" Value="{DynamicResource Text}"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="RadioButton">
        <StackPanel Orientation="Horizontal" Background="Transparent"><Grid Width="18" Height="18"><Ellipse x:Name="o" Stroke="{DynamicResource Muted}" StrokeThickness="1.5" Fill="{DynamicResource Input}"/><Ellipse x:Name="i" Width="8" Height="8" Fill="{DynamicResource Accent}" Visibility="Hidden"/></Grid><ContentPresenter Margin="8,0,0,0" VerticalAlignment="Center"/></StackPanel>
        <ControlTemplate.Triggers><Trigger Property="IsChecked" Value="True"><Setter TargetName="i" Property="Visibility" Value="Visible"/><Setter TargetName="o" Property="Stroke" Value="{DynamicResource Accent}"/></Trigger></ControlTemplate.Triggers>
      </ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style x:Key="Multi" TargetType="TextBox" BasedOn="{StaticResource {x:Type TextBox}}">
      <Setter Property="Height" Value="Auto"/><Setter Property="VerticalContentAlignment" Value="Top"/><Setter Property="Padding" Value="8"/><Setter Property="IsReadOnly" Value="True"/><Setter Property="TextWrapping" Value="Wrap"/><Setter Property="VerticalScrollBarVisibility" Value="Auto"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="TextBox"><Border CornerRadius="8" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1"><ScrollViewer x:Name="PART_ContentHost" Margin="{TemplateBinding Padding}"/></Border></ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style TargetType="TreeViewItem">
      <Setter Property="Foreground" Value="{DynamicResource Text}"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="TreeViewItem">
        <StackPanel><StackPanel Orientation="Horizontal" Margin="0,3">
          <ToggleButton x:Name="e" IsChecked="{Binding IsExpanded, RelativeSource={RelativeSource TemplatedParent}, Mode=TwoWay}" ClickMode="Press" Width="22" Focusable="False"><ToggleButton.Template><ControlTemplate TargetType="ToggleButton"><Border Background="Transparent"><TextBlock x:Name="t" Text="&#xE76C;" FontFamily="Segoe MDL2 Assets" FontSize="10" Foreground="{DynamicResource Muted}" HorizontalAlignment="Center" VerticalAlignment="Center"/></Border><ControlTemplate.Triggers><Trigger Property="IsChecked" Value="True"><Setter TargetName="t" Property="Text" Value="&#xE70D;"/></Trigger></ControlTemplate.Triggers></ControlTemplate></ToggleButton.Template></ToggleButton>
          <ContentPresenter ContentSource="Header"/></StackPanel>
          <ItemsPresenter x:Name="c" Margin="20,0,0,0" Visibility="Collapsed"/></StackPanel>
        <ControlTemplate.Triggers><Trigger Property="IsExpanded" Value="True"><Setter TargetName="c" Property="Visibility" Value="Visible"/></Trigger><Trigger Property="HasItems" Value="False"><Setter TargetName="e" Property="Visibility" Value="Hidden"/></Trigger></ControlTemplate.Triggers>
      </ControlTemplate></Setter.Value></Setter>
    </Style>
'@
try {
    Add-Type -Namespace Win32 -Name Dwm -MemberDefinition '[System.Runtime.InteropServices.DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(System.IntPtr hwnd, int attr, ref int val, int size);'
} catch { }
# Farben des Designs
$script:br = @{}
foreach ($k in $th.Keys) { $c = $th[$k]; $script:br[$k] = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromRgb($c.R, $c.G, $c.B)) }
$script:br['Hover'] = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromArgb(14, $th.Text.R, $th.Text.G, $th.Text.B))
$script:br['Warn'] = [System.Windows.Media.SolidColorBrush]::new($(if ($isDark) { [System.Windows.Media.Color]::FromRgb(0xFF, 0xB9, 0x00) } else { [System.Windows.Media.Color]::FromRgb(0x9D, 0x5D, 0x00) }))
foreach ($b in $script:br.Values) { $b.Freeze() }
function Set-Brushes($w) { foreach ($k in $script:br.Keys) { $w.Resources[$k] = $script:br[$k] } }
function Set-DarkTitle($w) {
    $w.Add_SourceInitialized({
        try { $v = if ($isDark) { 1 } else { 0 }; [void][Win32.Dwm]::DwmSetWindowAttribute((New-Object System.Windows.Interop.WindowInteropHelper $this).Handle, 20, [ref]$v, 4) } catch { }
    })
}
$script:winStack = New-Object System.Collections.ArrayList   # offene Dialoge, der oberste ist Besitzer des naechsten
# Baut einen Dialog; Rueckgabe: Tabelle mit Win und allen benannten Elementen. $size: z. B. 'Width="520" SizeToContent="Height" ResizeMode="NoResize"'
function New-Dlg([string]$title, [string]$size, [string]$body) {
    $x = '<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" xmlns:sys="clr-namespace:System;assembly=mscorlib" ' + $size +
        ' ShowInTaskbar="False" FontFamily="Segoe UI" FontSize="14" Background="{DynamicResource Bg}" Foreground="{DynamicResource Text}" UseLayoutRounding="True" TextOptions.TextFormattingMode="Display"><Window.Resources>' + $script:styles + '</Window.Resources>' + $body + '</Window>'
    $w = [System.Windows.Markup.XamlReader]::Parse($x)
    $w.Title = $title
    if ($script:win.Icon) { $w.Icon = $script:win.Icon }
    Set-Brushes $w; Set-DarkTitle $w
    $r = @{ Win = $w; Result = '' }
    foreach ($m in [regex]::Matches($body, 'x:Name="(\w+)"')) { $n = $m.Groups[1].Value; $e = $w.FindName($n); if ($e) { $r[$n] = $e } }
    return $r
}
function Show-Dlg($dlg) {
    $o = if ($script:winStack.Count) { $script:winStack[$script:winStack.Count - 1] } else { $script:win }
    if ($o -and $o.IsVisible) { $dlg.Win.Owner = $o; $dlg.Win.WindowStartupLocation = 'CenterOwner' } else { $dlg.Win.WindowStartupLocation = 'CenterScreen' }
    [void]$script:winStack.Add($dlg.Win)
    try { [void]$dlg.Win.ShowDialog() } finally { $script:winStack.Remove($dlg.Win) }
}
# ---- Meldungen (wie MessageBox): OK oder YesNo, Rueckgabe 'OK', 'Yes' oder 'No'. Esc/Schliessen = Nein
function Show-Msg([string]$text, [string]$title = 'DirToy', [string]$buttons = 'OK', [string]$icon = 'Information', [string]$default = 'Button1') {
    $yn = ($buttons -eq 'YesNo'); $no2 = ($yn -and $default -eq 'Button2')
    $btns = if ($yn) {
        '<Button x:Name="yes" Width="116" Margin="0,0,8,0" ' + $(if ($no2) { '' } else { 'IsDefault="True" Style="{StaticResource Primary}"' }) + '>Ja</Button><Button x:Name="no" Width="116" IsCancel="True" ' + $(if ($no2) { 'IsDefault="True" Style="{StaticResource Primary}"' } else { '' }) + '>Nein</Button>'
    } else { '<Button x:Name="no" Width="116" IsCancel="True" IsDefault="True" Style="{StaticResource Primary}">OK</Button>' }
    $g = switch ($icon) { 'Warning' { @('E7BA', 'Warn') } 'Error' { @('EA39', 'Err') } 'Question' { @('E897', 'Accent') } default { @('E946', 'Accent') } }
    $dlg = New-Dlg $title 'Width="540" SizeToContent="Height" MaxHeight="640" ResizeMode="NoResize"' ('<DockPanel Margin="24"><StackPanel DockPanel.Dock="Bottom" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,24,0,0">' + $btns + '</StackPanel>' +
        '<TextBlock DockPanel.Dock="Left" Text="&#x' + $g[0] + ';" Style="{StaticResource Icon}" FontSize="36" Foreground="{DynamicResource ' + $g[1] + '}" VerticalAlignment="Top" Margin="0,2,20,0"/>' +
        '<ScrollViewer VerticalScrollBarVisibility="Auto"><TextBlock x:Name="msgText" TextWrapping="Wrap" LineHeight="21"/></ScrollViewer></DockPanel>')
    $dlg.msgText.Text = $text
    $script:msgDlg = $dlg
    if ($yn) { $dlg.yes.Add_Click({ $script:msgDlg.Result = 'Yes'; $script:msgDlg.Win.Close() }) }
    $dlg.no.Add_Click({ $script:msgDlg.Win.Close() })
    [void]$(if ($yn -and -not $no2) { $dlg.yes } else { $dlg.no }).Focus()
    if ($icon -eq 'Warning' -or $icon -eq 'Error') { [System.Media.SystemSounds]::Exclamation.Play() }
    Show-Dlg $dlg
    if (-not $yn) { return 'OK' }
    if ($dlg.Result -eq 'Yes') { return 'Yes' }
    return 'No'
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
    $cell = '<GridViewColumn Width="{0}"><GridViewColumnHeader Tag="{1}">{1}</GridViewColumnHeader><GridViewColumn.CellTemplate><DataTemplate><TextBlock Text="{{Binding {1}}}" {2} TextTrimming="CharacterEllipsis" ToolTip="{{Binding {1}}}"/></DataTemplate></GridViewColumn.CellTemplate></GridViewColumn>'
    $cols = $(if ($multi) { ($cell -f 130, 'Task', '').Replace('>Task<', '>Aufgabe<') } else { '' }) + ($cell -f 220, 'Aktion', '') + ($cell -f $(if ($multi) { 270 } else { 380 }), 'Datei', '') + ($cell -f 190, 'Status', 'Foreground="{Binding StatusBrush}"')
    $dlg = New-Dlg 'DirToy - Ergebnis' 'Width="900" Height="680" MinWidth="620" MinHeight="460"' ('<DockPanel Margin="24">
      <TextBlock x:Name="head" DockPanel.Dock="Top" FontSize="20" FontWeight="SemiBold" Margin="0,0,0,12"/>
      <DockPanel DockPanel.Dock="Bottom" Margin="0,16,0,0" LastChildFill="False"><Button x:Name="csv">Details als CSV öffnen</Button><Button x:Name="close" DockPanel.Dock="Right" Style="{StaticResource Primary}" IsCancel="True" IsDefault="True">Schließen</Button></DockPanel>
      <Border DockPanel.Dock="Top" Background="{DynamicResource Surface}" CornerRadius="12" Padding="16,12" MaxHeight="230"><ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel x:Name="sum"/></ScrollViewer></Border>
      <TextBlock DockPanel.Dock="Top" Style="{StaticResource MutedText}" Margin="4,14,0,8" TextWrapping="Wrap" Text="Einzelne Aktionen (Fehler zuerst). Spaltenkopf anklicken zum Sortieren, Strg+C kopiert die markierten Zeilen."/>
      <Border Background="{DynamicResource Surface}" CornerRadius="12" Padding="4"><ListView x:Name="dv" Background="Transparent" BorderThickness="0" FontSize="13" ScrollViewer.HorizontalScrollBarVisibility="Disabled"><ListView.View><GridView AllowsColumnReorder="False">' + $cols + '</GridView></ListView.View></ListView></Border></DockPanel>')
    $dlg.head.Text = if ($multi) { "Ergebnis: $(@($results).Count) Aufgaben" } else { "Ergebnis: $(@($results)[0].Name)" }
    $add = { param([string]$a, [string]$b, $brush, [bool]$bold)
        $p = New-Object System.Windows.Controls.DockPanel; $p.Margin = '0,2'
        $r = New-Object System.Windows.Controls.TextBlock; $r.Text = $b; $r.Foreground = $brush; [System.Windows.Controls.DockPanel]::SetDock($r, 'Right')
        $l = New-Object System.Windows.Controls.TextBlock; $l.Text = $a; $l.Foreground = $brush; $l.TextWrapping = 'Wrap'
        if ($bold) { $l.FontWeight = 'SemiBold' }
        [void]$p.Children.Add($r); [void]$p.Children.Add($l); [void]$dlg.sum.Children.Add($p)
    }
    foreach ($r in $results) {
        if ($multi) { & $add $r.Name '' $script:br.Text $true }
        foreach ($k in $r.Sum.Keys) { & $add $k ('{0:N0}' -f $r.Sum[$k]) $script:br.Text $false }
        if ($r.Skipped -gt 0) { & $add 'Übersprungen' ('{0:N0}' -f $r.Skipped) $script:br.Muted $false }
        if ($r.Errors -gt 0) { & $add 'Fehler' ('{0:N0}' -f $r.Errors) $script:br.Err $false }
        $ts = [timespan]::FromSeconds([math]::Round($r.Seconds))
        & $add ('Dauer ' + $ts.ToString('hh\:mm\:ss') + ', kopierte Datenmenge ' + (Format-Bytes $r.Bytes)) '' $script:br.Muted $false
        if ($r.Cancelled) { & $add 'Der Lauf wurde abgebrochen (unvollständig, keine halben Dateien)' '' $script:br.Err $false }
    }
    # Details (Fehler zuerst, hoechstens 2000 Zeilen)
    $rows = [System.Collections.ObjectModel.ObservableCollection[DirToyRow]]::new()
    $max = 2000; $total = 0
    foreach ($r in $results) { $total += $r.Items.Count }
    foreach ($pass in 1, 2) {
        foreach ($r in $results) {
            foreach ($it in $r.Items) {
                if (($pass -eq 1) -ne ([string]$it[2] -like 'FEHLER*')) { continue }
                if ($rows.Count -ge $max) { break }
                $x = [DirToyRow]::new(); $x.Task = [string]$r.Name; $x.Aktion = [string]$it[0]; $x.Datei = [string]$it[1]; $x.Status = [string]$it[2]; $x.StatusBrush = Get-StatusBrush ([string]$it[2])
                $rows.Add($x)
            }
        }
    }
    if ($total -gt $rows.Count) {
        $x = [DirToyRow]::new(); $x.Aktion = "... und $($total - $rows.Count) weitere Aktionen"; $x.Datei = 'komplette Liste: „Details als CSV öffnen“'; $rows.Add($x)
    }
    $dlg.dv.ItemsSource = $rows
    $script:resDlg = $dlg; $script:resList = $results; $script:resSort = ''; $script:resAsc = $true
    $dlg.dv.AddHandler([System.Windows.Controls.GridViewColumnHeader]::ClickEvent, [System.Windows.RoutedEventHandler] {
        param($s, $e)
        $h = $e.OriginalSource
        if ($h -isnot [System.Windows.Controls.GridViewColumnHeader] -or -not $h.Tag) { return }
        $script:resAsc = if ($script:resSort -eq $h.Tag) { -not $script:resAsc } else { $true }
        $script:resSort = [string]$h.Tag
        $v = [System.Windows.Data.CollectionViewSource]::GetDefaultView($script:resDlg.dv.ItemsSource)
        $v.SortDescriptions.Clear()
        $v.SortDescriptions.Add((New-Object System.ComponentModel.SortDescription($script:resSort, $(if ($script:resAsc) { 'Ascending' } else { 'Descending' }))))
    })
    $dlg.dv.Add_PreviewKeyDown({
        param($s, $e)
        if ($e.Key -eq 'C' -and [System.Windows.Input.Keyboard]::Modifiers -eq 'Control') { Copy-Rows $false $script:resDlg.dv; $e.Handled = $true }
    })
    $dlg.csv.Add_Click({
        $f = Write-ResultFile $script:resList
        if ($f) { try { Start-Process -FilePath $f -ErrorAction Stop } catch { Start-Process notepad.exe -ArgumentList "`"$f`"" } }
        else { [void](Show-Msg 'Die CSV-Datei konnte nicht geschrieben werden.' 'DirToy' 'OK' 'Warning') }
    })
    $dlg.close.Add_Click({ $script:resDlg.Win.Close() })
    Show-Dlg $dlg
}
function Show-ResultsIfNeeded {
    if ($script:closeRequested -or -not [bool](Get-Setting 'ShowResult' $true)) { return }
    $list = @($script:results | Where-Object { ($_.Copied + $_.Deleted + $_.Errors + $_.Skipped) -gt 0 -or $_.Cancelled })
    if ($list.Count -eq 0) { return }
    Show-ResultDialog $list
}

# ---- Hauptfenster (WPF)
$script:xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" xmlns:sys="clr-namespace:System;assembly=mscorlib"
        Width="1120" Height="780" MinWidth="900" MinHeight="660" WindowStartupLocation="CenterScreen"
        FontFamily="Segoe UI" FontSize="14" Background="{DynamicResource Bg}" Foreground="{DynamicResource Text}"
        UseLayoutRounding="True" TextOptions.TextFormattingMode="Display">
  <Window.TaskbarItemInfo><TaskbarItemInfo x:Name="task"/></Window.TaskbarItemInfo>
  <Window.Resources>
@@STILE@@
  </Window.Resources>
  <Grid x:Name="root" Background="{DynamicResource Bg}">
    <Grid.ColumnDefinitions><ColumnDefinition Width="250"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
    <Border Background="{DynamicResource Surface}">
      <DockPanel Margin="12,16,12,12">
        <StackPanel DockPanel.Dock="Top" Margin="10,0,0,14">
          <StackPanel Orientation="Horizontal"><TextBlock Text="&#xE895;" Style="{StaticResource Icon}" FontSize="22" Foreground="{DynamicResource Accent}" Margin="0,2,10,0"/><TextBlock Text="DirToy" FontSize="24" FontWeight="SemiBold" Foreground="{DynamicResource Accent}"/></StackPanel>
          <Button x:Name="lblVer" AutomationProperties.Name="Updates prüfen" Style="{StaticResource Ghost}" Height="24" Padding="0" FontSize="12" Foreground="{DynamicResource Muted}" HorizontalAlignment="Left" ToolTip="Nach Updates suchen"/>
        </StackPanel>
        <StackPanel DockPanel.Dock="Bottom">
          <Button x:Name="btnUpd" Style="{StaticResource Primary}" Visibility="Collapsed" Margin="0,0,0,8"/>
          <Button x:Name="btnLog" AutomationProperties.Name="Protokoll" Style="{StaticResource Ghost}" Height="34" ToolTip="Protokoll aller bisherigen Läufe (sync.log)"><StackPanel Orientation="Horizontal"><TextBlock Text="&#xE7C3;" Style="{StaticResource Icon}" Margin="0,0,10,0"/><TextBlock Text="Protokoll"/></StackPanel></Button>
          <Button x:Name="btnTheme" AutomationProperties.Name="Design" Style="{StaticResource Ghost}" Height="34" ToolTip="Automatisch (wie Windows), Hell oder Dunkel. DirToy startet dabei kurz neu."><StackPanel Orientation="Horizontal"><TextBlock Text="&#xE793;" Style="{StaticResource Icon}" Margin="0,0,10,0"/><TextBlock x:Name="lblTheme"/></StackPanel></Button>
          <Button x:Name="btnHelp" AutomationProperties.Name="Hilfe" Style="{StaticResource Ghost}" Height="34" ToolTip="Anleitung"><StackPanel Orientation="Horizontal"><TextBlock Text="&#xE897;" Style="{StaticResource Icon}" Margin="0,0,10,0"/><TextBlock Text="Hilfe"/></StackPanel></Button>
        </StackPanel>
        <Button x:Name="btnNew" AutomationProperties.Name="Neue Aufgabe" DockPanel.Dock="Bottom" Margin="0,8,0,12" ToolTip="Neue Aufgabe anlegen"><StackPanel Orientation="Horizontal"><TextBlock Text="&#xE710;" Style="{StaticResource Icon}" Margin="0,0,8,0"/><TextBlock Text="Neue Aufgabe"/></StackPanel></Button>
        <ListBox x:Name="lb" Style="{StaticResource PlainList}" Background="Transparent" BorderThickness="0" Foreground="{DynamicResource Text}" ScrollViewer.HorizontalScrollBarVisibility="Disabled" AutomationProperties.Name="Aufgaben">
          <ListBox.ItemTemplate><DataTemplate>
            <DockPanel><Ellipse DockPanel.Dock="Left" Width="9" Height="9" Fill="{Binding Dot}" Margin="0,0,10,0" VerticalAlignment="Center"/>
              <StackPanel><TextBlock Text="{Binding Name}" TextTrimming="CharacterEllipsis"/><TextBlock Text="{Binding Sub}" Style="{StaticResource MutedText}" TextTrimming="CharacterEllipsis"/></StackPanel></DockPanel>
          </DataTemplate></ListBox.ItemTemplate>
        </ListBox>
      </DockPanel>
    </Border>
    <Grid Grid.Column="1" Margin="24,18,24,16">
      <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
      <DockPanel>
        <Button x:Name="btnGear" DockPanel.Dock="Right" Style="{StaticResource Ghost}" ToolTip="Einstellungen der Aufgabe: Ausschlüsse, Ordnerauswahl, Löschen" AutomationProperties.Name="Einstellungen der Aufgabe"><TextBlock Text="&#xE713;" Style="{StaticResource Icon}" FontSize="18"/></Button>
        <Button x:Name="btnSched" AutomationProperties.Name="Zeitplan" DockPanel.Dock="Right" Style="{StaticResource Ghost}" ToolTip="Automatische Ausführung einrichten"><StackPanel Orientation="Horizontal"><TextBlock Text="&#xE823;" Style="{StaticResource Icon}" Margin="0,0,8,0"/><TextBlock x:Name="lblSched" MaxWidth="360" TextTrimming="CharacterEllipsis"/></StackPanel></Button>
        <TextBox x:Name="tbName" FontSize="22" FontWeight="SemiBold" Height="42" Background="Transparent" BorderBrush="Transparent" Padding="4,0" Margin="-5,0,8,0" AutomationProperties.Name="Name der Aufgabe" ToolTip="Name der Aufgabe (anklicken zum Ändern)"/>
      </DockPanel>
      <Border x:Name="gear" Grid.Row="1" Visibility="Collapsed" Background="{DynamicResource Surface}" CornerRadius="12" Padding="16" Margin="0,12,0,0">
        <StackPanel>
          <TextBlock Text="Nicht synchronisieren: Dateinamen oder Muster, mit ; getrennt (z. B. Thumbs.db;*.tmp;~$*;node_modules)" Style="{StaticResource MutedText}" TextWrapping="Wrap" Margin="0,0,0,6"/>
          <DockPanel><Button x:Name="btnDel" DockPanel.Dock="Right" Margin="8,0,0,0" Height="34" Foreground="{DynamicResource Err}" ToolTip="Aufgabe löschen (Dateien bleiben unverändert)">Aufgabe löschen</Button>
            <Button x:Name="btnDirs" DockPanel.Dock="Right" Margin="8,0,0,0" Height="34" ToolTip="Ordner abwählen, die nicht synchronisiert werden sollen"/>
            <TextBox x:Name="tbEx" AutomationProperties.Name="Ausschlussmuster"/></DockPanel>
        </StackPanel>
      </Border>
      <Grid Grid.Row="2" Margin="0,14,0,0">
        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="190"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
        <Border Background="{DynamicResource Surface}" CornerRadius="14" Padding="16">
          <StackPanel>
            <Path Data="M 1,8 Q 1,4 5,4 L 15,4 L 19,9 L 39,9 Q 43,9 43,13 L 43,31 Q 43,35 39,35 L 5,35 Q 1,35 1,31 Z" Stroke="{DynamicResource Accent}" StrokeThickness="2.5" StrokeLineJoin="Round" Width="46" Height="38" HorizontalAlignment="Center"/>
            <TextBlock x:Name="lblA" FontSize="16" FontWeight="SemiBold" HorizontalAlignment="Center" Margin="0,8,0,0" TextTrimming="CharacterEllipsis"/>
            <TextBlock Text="Ordner A" Style="{StaticResource MutedText}" HorizontalAlignment="Center" Margin="0,2,0,10"/>
            <DockPanel><Button x:Name="btnA" DockPanel.Dock="Right" Height="34" Padding="10,0" Margin="6,0,0,0" ToolTip="Ordner A wählen" AutomationProperties.Name="Ordner A wählen"><TextBlock Text="&#xE712;" Style="{StaticResource Icon}"/></Button><TextBox x:Name="tbA" ToolTip="{Binding Text, RelativeSource={RelativeSource Self}}" AutomationProperties.Name="Ordner A"/></DockPanel>
          </StackPanel>
        </Border>
        <Grid Grid.Column="1" HorizontalAlignment="Center" VerticalAlignment="Center" Width="150" Height="90">
          <Line x:Name="l1" X1="0" X2="138" Y1="28" Y2="28" Stroke="{DynamicResource Border}" StrokeThickness="1.5" StrokeDashArray="2 4"/>
          <Line x:Name="l2" X1="12" X2="150" Y1="62" Y2="62" Stroke="{DynamicResource Border}" StrokeThickness="1.5" StrokeDashArray="2 4"/>
          <Path x:Name="p1" Data="M 142,22 L 149,28 L 142,34" Stroke="{DynamicResource Muted}" StrokeThickness="2"/>
          <Path x:Name="p2" Data="M 8,56 L 1,62 L 8,68" Stroke="{DynamicResource Muted}" StrokeThickness="2"/>
          <Canvas x:Name="lane" Width="150" Height="90" Opacity="0"/>
          <Grid x:Name="done" Width="64" Height="64" Opacity="0" IsHitTestVisible="False" RenderTransformOrigin="0.5,0.5"><Grid.RenderTransform><ScaleTransform x:Name="doneScale"/></Grid.RenderTransform>
            <Ellipse x:Name="doneBg"/><Path x:Name="donePath" StrokeThickness="5" StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round" StrokeDashArray="14" StrokeDashOffset="14"/></Grid>
        </Grid>
        <Border Grid.Column="2" Background="{DynamicResource Surface}" CornerRadius="14" Padding="16">
          <StackPanel>
            <Path Data="M 1,8 Q 1,4 5,4 L 15,4 L 19,9 L 39,9 Q 43,9 43,13 L 43,31 Q 43,35 39,35 L 5,35 Q 1,35 1,31 Z" Stroke="{DynamicResource Accent}" StrokeThickness="2.5" StrokeLineJoin="Round" Width="46" Height="38" HorizontalAlignment="Center"/>
            <TextBlock x:Name="lblB" FontSize="16" FontWeight="SemiBold" HorizontalAlignment="Center" Margin="0,8,0,0" TextTrimming="CharacterEllipsis"/>
            <TextBlock Text="Ordner B" Style="{StaticResource MutedText}" HorizontalAlignment="Center" Margin="0,2,0,10"/>
            <DockPanel><Button x:Name="btnB" DockPanel.Dock="Right" Height="34" Padding="10,0" Margin="6,0,0,0" ToolTip="Ordner B wählen" AutomationProperties.Name="Ordner B wählen"><TextBlock Text="&#xE712;" Style="{StaticResource Icon}"/></Button><TextBox x:Name="tbB" ToolTip="{Binding Text, RelativeSource={RelativeSource Self}}" AutomationProperties.Name="Ordner B"/></DockPanel>
          </StackPanel>
        </Border>
      </Grid>
      <DockPanel Grid.Row="3" Margin="0,14,0,0" LastChildFill="False">
        <Border Background="{DynamicResource Surface}" CornerRadius="8" VerticalAlignment="Center"><StackPanel Orientation="Horizontal">
          <RadioButton x:Name="m0" Style="{StaticResource Seg}" GroupName="m">Synchronisieren</RadioButton><RadioButton x:Name="m1" Style="{StaticResource Seg}" GroupName="m">Echo</RadioButton><RadioButton x:Name="m2" Style="{StaticResource Seg}" GroupName="m">Beitragen</RadioButton></StackPanel></Border>
        <Button x:Name="btnAll" DockPanel.Dock="Right" ToolTip="Alle Aufgaben nacheinander ausführen">Alle ausführen</Button>
        <Button x:Name="btnRun" AutomationProperties.Name="Starten" DockPanel.Dock="Right" Style="{StaticResource Primary}" Margin="8,0" MinWidth="120" ToolTip="Diese Aufgabe jetzt ausführen"><StackPanel Orientation="Horizontal"><TextBlock Text="&#xE768;" Style="{StaticResource Icon}" FontSize="13" Margin="0,0,8,0"/><TextBlock Text="Starten"/></StackPanel></Button>
        <Button x:Name="btnCancel" DockPanel.Dock="Right" Margin="8,0" MinWidth="120" Visibility="Collapsed" ToolTip="Bricht nach der aktuellen Datei ab. Es bleiben keine halben Dateien zurück.">Abbrechen</Button>
        <Button x:Name="btnPrev" DockPanel.Dock="Right" ToolTip="Zeigt nur an, was passieren würde">Vorschau</Button>
      </DockPanel>
      <TextBlock x:Name="lblMode" Grid.Row="4" Style="{StaticResource MutedText}" Margin="4,8,0,0"/>
      <StackPanel Grid.Row="5" Margin="0,14,0,10">
        <Border x:Name="track" Height="8" CornerRadius="4" Background="{DynamicResource Input}" ClipToBounds="True"><Grid HorizontalAlignment="Left"><Border x:Name="fill" Width="0" HorizontalAlignment="Left" CornerRadius="4" Background="{DynamicResource Accent}"/>
          <Canvas x:Name="shineBox" ClipToBounds="True" HorizontalAlignment="Left" Width="{Binding ActualWidth, ElementName=fill}"><Rectangle x:Name="shine" Width="90" Height="8" Visibility="Collapsed"><Rectangle.Fill><LinearGradientBrush StartPoint="0,0" EndPoint="1,0"><GradientStop Color="#00FFFFFF" Offset="0"/><GradientStop Color="#80FFFFFF" Offset="0.5"/><GradientStop Color="#00FFFFFF" Offset="1"/></LinearGradientBrush></Rectangle.Fill></Rectangle></Canvas></Grid></Border>
        <TextBlock x:Name="lblStatus" Style="{StaticResource MutedText}" Margin="4,6,0,0" Text="Bereit." TextTrimming="CharacterEllipsis"/>
      </StackPanel>
      <Border Grid.Row="6" Background="{DynamicResource Surface}" CornerRadius="12" Padding="4">
        <Grid>
          <ListView x:Name="lv" Background="Transparent" BorderThickness="0" FontSize="13" ScrollViewer.HorizontalScrollBarVisibility="Disabled" SelectionMode="Extended" VirtualizingPanel.IsVirtualizing="True" VirtualizingPanel.VirtualizationMode="Recycling" AutomationProperties.Name="Aktionen">
            <ListView.ContextMenu><ContextMenu><MenuItem x:Name="mi1" Header="Markierte Zeilen kopieren (Strg+C)"/><MenuItem x:Name="mi2" Header="Alle Zeilen kopieren"/><MenuItem x:Name="mi3" Header="Alles markieren (Strg+A)"/></ContextMenu></ListView.ContextMenu>
            <ListView.View><GridView AllowsColumnReorder="False">
              <GridViewColumn x:Name="c0" Width="250"><GridViewColumnHeader x:Name="h0" Tag="Aktion">Aktion</GridViewColumnHeader><GridViewColumn.CellTemplate><DataTemplate><StackPanel Orientation="Horizontal"><TextBlock Text="{Binding Icon}" Foreground="{Binding IconBrush}" Style="{StaticResource Icon}" FontSize="13" Width="22"/><TextBlock Text="{Binding Aktion}"/></StackPanel></DataTemplate></GridViewColumn.CellTemplate></GridViewColumn>
              <GridViewColumn x:Name="c1" Width="330"><GridViewColumnHeader x:Name="h1" Tag="Datei">Datei</GridViewColumnHeader><GridViewColumn.CellTemplate><DataTemplate><TextBlock Text="{Binding Datei}" TextTrimming="CharacterEllipsis" ToolTip="{Binding Datei}"/></DataTemplate></GridViewColumn.CellTemplate></GridViewColumn>
              <GridViewColumn x:Name="c2" Width="180"><GridViewColumnHeader x:Name="h2" Tag="Status">Status</GridViewColumnHeader><GridViewColumn.CellTemplate><DataTemplate><TextBlock Text="{Binding Status}" Foreground="{Binding StatusBrush}" TextTrimming="CharacterEllipsis" ToolTip="{Binding Status}"/></DataTemplate></GridViewColumn.CellTemplate></GridViewColumn>
            </GridView></ListView.View>
          </ListView>
          <StackPanel x:Name="empty" VerticalAlignment="Center" HorizontalAlignment="Center" IsHitTestVisible="False">
            <TextBlock Text="&#xE895;" Style="{StaticResource Icon}" FontSize="34" Foreground="{DynamicResource Border}" HorizontalAlignment="Center"/>
            <TextBlock Text="Noch nichts gelaufen. Mit „Vorschau“ siehst du, was passieren würde." Style="{StaticResource MutedText}" Margin="0,10,0,0"/>
          </StackPanel>
        </Grid>
      </Border>
    </Grid>
  </Grid>
</Window>
'@.Replace('@@STILE@@', $script:styles)
$script:win = [System.Windows.Markup.XamlReader]::Parse($script:xaml)
$win = $script:win
$script:ui = @{}
foreach ($m in [regex]::Matches($script:xaml, 'x:Name="(\w+)"')) { $n = $m.Groups[1].Value; $e = $win.FindName($n); if ($e) { $script:ui[$n] = $e } }
$ui = $script:ui
Set-Brushes $win
$win.Title = "DirToy $($script:version)"
$ico = Get-AppIcon
if ($ico) { $win.Icon = [System.Windows.Interop.Imaging]::CreateBitmapSourceFromHIcon($ico.Handle, [System.Windows.Int32Rect]::Empty, [System.Windows.Media.Imaging.BitmapSizeOptions]::FromEmptyOptions()) }
$ui.lblVer.Content = "Version $($script:version)  ·  Updates prüfen"
$ui.lblTheme.Text = @{ auto = 'Design: Automatisch'; hell = 'Design: Hell'; dunkel = 'Design: Dunkel' }[$script:themeSetting]
# $form: Besitzer fuer die Dialoge
$script:form = New-Object DirToyOwner
$form = $script:form
$win.Add_SourceInitialized({ $form.H = (New-Object System.Windows.Interop.WindowInteropHelper $win).Handle })
Set-DarkTitle $win
$script:updTimer = New-Object System.Windows.Threading.DispatcherTimer; $script:updTimer.Interval = [TimeSpan]::FromMilliseconds(300)
$script:updTimer.Add_Tick({ if ($script:updTask -and $script:updTask.IsCompleted) { Finish-UpdateCheck } })

# Liste der Aktionen
$script:rows = [System.Collections.ObjectModel.ObservableCollection[DirToyRow]]::new()
$ui.lv.ItemsSource = $script:rows
$script:sortCol = ''; $script:sortAsc = $true
function Set-ListSort([string]$col, [bool]$asc) {
    $script:sortCol = $col; $script:sortAsc = $asc
    $v = [System.Windows.Data.CollectionViewSource]::GetDefaultView($script:rows)
    $v.SortDescriptions.Clear()
    if ($col) { $v.SortDescriptions.Add((New-Object System.ComponentModel.SortDescription($col, $(if ($asc) { 'Ascending' } else { 'Descending' })))) }
    foreach ($h in $ui.h0, $ui.h1, $ui.h2) { $h.Content = [string]$h.Tag + $(if ($h.Tag -eq $col) { if ($asc) { ' ' + [char]0x25B2 } else { ' ' + [char]0x25BC } } else { '' }) }
}
foreach ($h in $ui.h0, $ui.h1, $ui.h2) {
    $h.Add_Click({ if (-not $script:busy) { $c = [string]$this.Tag; Set-ListSort $c $(if ($script:sortCol -eq $c) { -not $script:sortAsc } else { $true }) } })
}
function Copy-Rows([bool]$all, $list = $ui.lv) {
    $items = if ($all) { @($list.Items) } else { @($list.Items | Where-Object { $list.SelectedItems.Contains($_) }) }
    if ($items.Count -eq 0) { return }
    $sb = New-Object System.Text.StringBuilder
    foreach ($r in $items) { [void]$sb.AppendLine("$($r.Aktion)`t$($r.Datei)`t$($r.Status)") }
    try { [System.Windows.Forms.Clipboard]::SetText($sb.ToString()) } catch { }
}
$ui.mi1.Add_Click({ Copy-Rows $false }); $ui.mi2.Add_Click({ Copy-Rows $true }); $ui.mi3.Add_Click({ $ui.lv.SelectAll() })
$ui.lv.Add_PreviewKeyDown({
    param($s, $e)
    if ($e.Key -eq 'C' -and [System.Windows.Input.Keyboard]::Modifiers -eq 'Control') { Copy-Rows $false; $e.Handled = $true }
})
$ui.lv.Add_MouseDoubleClick({
    $r = $ui.lv.SelectedItem
    if ($r -and $r.File -and $r.File.EndsWith('vorschau.csv') -and (Test-Path -LiteralPath $r.File)) {
        try { Start-Process -FilePath $r.File -ErrorAction Stop }
        catch { Start-Process notepad.exe -ArgumentList "`"$($r.File)`"" }   # keine Zuordnung fuer .csv: im Editor oeffnen
    }
})
$ui.lv.Add_SizeChanged({ $w = $ui.lv.ActualWidth - $ui.c0.Width - $ui.c2.Width - 34; if ($w -gt 120) { $ui.c1.Width = $w } })

# ---- Animation zwischen den Ordnern
$script:motion = [System.Windows.SystemParameters]::ClientAreaAnimation   # in Windows abgeschaltete Animationen respektieren
function New-Anim([double]$from, [double]$to, [int]$ms) {
    return (New-Object System.Windows.Media.Animation.DoubleAnimation($from, $to, [System.Windows.Duration][TimeSpan]::FromMilliseconds($ms)))
}
function Set-Opacity($el, [double]$to) {
    if (-not $script:motion) { $el.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null); $el.Opacity = $to; return }
    $el.BeginAnimation([System.Windows.UIElement]::OpacityProperty, (New-Anim $el.Opacity $to 250))
}
function Show-Direction([int]$mode) {
    $two = ($mode -eq 0)
    $ui.l2.X1 = $(if ($two) { 12 } else { 0 }); $ui.l2.X2 = $(if ($two) { 150 } else { 138 })
    $ui.p2.Data = [System.Windows.Media.Geometry]::Parse($(if ($two) { 'M 8,56 L 1,62 L 8,68' } else { 'M 142,56 L 149,62 L 142,68' }))
}
function Start-Flow([int]$mode, [bool]$preview) {
    Set-Opacity $ui.done 0
    if (-not $script:motion) { return }
    $ui.lane.Children.Clear()
    foreach ($i in 0..9) {
        $e = New-Object System.Windows.Shapes.Ellipse; $e.Width = 9; $e.Height = 9; $e.Opacity = 0
        $e.Fill = $(if ($preview) { $script:br.Muted } else { $script:br.Accent })
        [System.Windows.Controls.Canvas]::SetTop($e, $(if ($i % 2) { 57.5 } else { 23.5 }))
        [void]$ui.lane.Children.Add($e)
        $back = ($mode -eq 0 -and $i % 2)
        $x = New-Anim $(if ($back) { 141 } else { 0 }) $(if ($back) { 0 } else { 141 }) 1500
        $x.EasingFunction = New-Object System.Windows.Media.Animation.SineEase -Property @{ EasingMode = 'EaseInOut' }
        $o = New-Object System.Windows.Media.Animation.DoubleAnimationUsingKeyFrames; $o.Duration = $x.Duration
        foreach ($kf in @(0, 0), @(0.2, 1), @(0.8, 1), @(1, 0)) { [void]$o.KeyFrames.Add((New-Object System.Windows.Media.Animation.LinearDoubleKeyFrame($kf[1], [System.Windows.Media.Animation.KeyTime]::FromPercent($kf[0])))) }
        foreach ($a in $x, $o) { $a.BeginTime = [TimeSpan]::FromMilliseconds(150 * $i); $a.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever }
        $e.BeginAnimation([System.Windows.Controls.Canvas]::LeftProperty, $x)
        $e.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $o)
    }
    Set-Opacity $ui.lane 1
    $ui.shine.Visibility = 'Visible'
    $s = New-Anim -90 900 1800; $s.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
    $ui.shine.BeginAnimation([System.Windows.Controls.Canvas]::LeftProperty, $s)
}
# $result: ok, err, cancel oder '' (nichts zeigen)
function Stop-Flow([string]$result) {
    Set-Opacity $ui.lane 0
    $ui.lane.Children.Clear()   # beendet alle Punkt-Animationen
    $ui.shine.BeginAnimation([System.Windows.Controls.Canvas]::LeftProperty, $null); $ui.shine.Visibility = 'Collapsed'
    if (-not $result) { return }
    $ui.doneBg.Fill = switch ($result) { 'ok' { $script:br.Ok } 'err' { $script:br.Err } default { $script:br.Muted } }
    $ui.donePath.Stroke = $script:br.Bg
    $ui.donePath.Data = [System.Windows.Media.Geometry]::Parse($(switch ($result) { 'ok' { 'M 18,33 L 28,43 L 46,23' } 'err' { 'M 22,22 L 42,42 M 42,22 L 22,42' } default { 'M 20,32 L 44,32' } }))
    $dash = [System.Windows.Shapes.Shape]::StrokeDashOffsetProperty
    if (-not $script:motion) { $ui.donePath.StrokeDashOffset = 0; Set-Opacity $ui.done 1; return }
    Set-Opacity $ui.done 1
    $sc = New-Anim 0.6 1 350; $sc.EasingFunction = New-Object System.Windows.Media.Animation.BackEase -Property @{ EasingMode = 'EaseOut'; Amplitude = 0.5 }
    $ui.doneScale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleXProperty, $sc)
    $ui.doneScale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleYProperty, $sc)
    $d = New-Anim 14 0 450; $d.BeginTime = [TimeSpan]::FromMilliseconds(200)
    $ui.donePath.BeginAnimation($dash, $d)
}

# ---- Anzeige: zeichnet, was der Sync-Thread meldet (laeuft nur im Fenster-Thread)
function Out-Status([string]$text) { $ui.lblStatus.Text = $text }
function Set-Progress([double]$frac) {
    $ui.fill.Width = Get-BarWidth ([int]$ui.track.ActualWidth) $frac
    $ui.task.ProgressValue = [math]::Max(0.0, [math]::Min(1.0, $frac))
}
function Get-StatusBrush([string]$st) {
    if ($st -like 'FEHLER*') { return $script:br.Err }
    if ($st -eq 'OK') { return $script:br.Ok }
    return $script:br.Muted
}
function Out-Row([string]$aktion, [string]$datei, [string]$status) {
    $r = [DirToyRow]::new()
    $r.Aktion = $aktion; $r.Datei = $datei; $r.Status = $status; $r.StatusBrush = Get-StatusBrush $status
    $g = 0; $c = 'Accent'
    if ($aktion -like '*löschen*') { $g = 0xE74D; $c = 'Err' }
    elseif ($aktion -like 'Konflikt*' -or $aktion -eq 'Warnung') { $g = 0xE7BA; $c = 'Warn' }
    elseif ($aktion -like '*Ordner anlegen') { $g = 0xE8F4 }
    elseif ($aktion -like 'A -> B*') { $g = 0xE72A }
    elseif ($aktion -like 'B -> A*') { $g = 0xE72B }
    elseif ($aktion -like 'Aufgabe *') { $g = 0xE946; $c = 'Muted' }
    if ($g) { $r.Icon = [string][char]$g; $r.IconBrush = $script:br[$c] }
    $script:rows.Add($r)
    return $r
}
function Set-RowStatus($row, [string]$status) { $row.Status = $status; $row.StatusBrush = Get-StatusBrush $status }
function Set-RowFile($row, [string]$path) { $row.File = $path }
function Limit-Rows([int]$max) { for ($k = $script:rows.Count - $max; $k -gt 0; $k--) { $script:rows.RemoveAt(0) } }
function Ask-User([string]$text, [string]$title, [bool]$defaultNo) {
    return ((Show-Msg $text $title 'YesNo' 'Warning' $(if ($defaultNo) { 'Button2' } else { 'Button1' })) -eq 'Yes')
}
# Liste leeren und Sortierung zuruecksetzen (neue Zeilen kommen sonst an sortierter Stelle statt am Ende)
function Clear-Log { Set-ListSort '' $true; $script:rows.Clear(); $ui.empty.Visibility = 'Collapsed' }

# ---- Sync im eigenen Thread. Der Kern fasst das Fenster nie an: Er legt Meldungen in $brg ab, ein Timer im
# Fenster-Thread holt sie ab. Zurueck geht nur: Abbruch ($brg.Cancel) und die Antwort auf eine Rueckfrage.
$script:workerFns = {
    function Out-Status([string]$text) { $brg.Status = $text }
    function Set-Progress([double]$frac) { $brg.Frac = $frac }
    function Out-Row([string]$aktion, [string]$datei, [string]$status) {
        $script:rowId++
        $brg.Q.Enqueue(@('row', $script:rowId, $aktion, $datei, $status, [bool]$script:bulk))
        return $script:rowId
    }
    function Set-RowStatus($row, [string]$status) { $brg.Q.Enqueue(@('status', $row, $status)) }
    function Set-RowFile($row, [string]$path) { $brg.Q.Enqueue(@('file', $row, $path)) }
    function Start-Bulk { }
    function Stop-Bulk { }
    function Limit-Rows([int]$max, [bool]$scroll) { $brg.Q.Enqueue(@('limit', $max, $scroll)) }
    function Test-Cancel { return $brg.Cancel }
    # Kommt das Fenster nicht nach, wartet der Sync kurz (sonst waechst die Warteschlange unbegrenzt)
    function Pump { while ($brg.Q.Count -gt 4000 -and -not $brg.Cancel) { [System.Threading.Thread]::Sleep(10) } }
    function Ask-User([string]$text, [string]$title, [bool]$defaultNo) {
        $brg.Answer = $false
        $brg.Ev.Reset()
        $brg.Ask = @($text, $title, $defaultNo)
        while (-not $brg.Ev.Wait(200)) { if ($brg.Cancel) { $brg.Ask = $null; return $false } }
        if ($brg.Answer -and -not $brg.Cancel) { return $true }
        $brg.Declined = $true
        return $false
    }
}
$script:workerRun = {
    $ErrorActionPreference = 'Stop'
    try {
        foreach ($job in $jobs) {
            $brg.Declined = $false
            $res = Run-Task $job $isPreview
            if (-not $isPreview) {
                $no = ([bool]$brg.Declined -or ($res -and $res.Cancelled))   # Rueckfrage verneint oder abgebrochen
                $bad = ($null -eq $res -and -not $no)
                if ($bad) { $brg.Failed = $true }
                if ($no) { $brg.Stopped = $true }
                $brg.Infos.Add(@([string]$job.Id, $bad, $(if ($res) { [int]$res.Errors } else { 0 }), $no))
            }
            if ($brg.Cancel) { break }
        }
    } catch { $brg.Error = [string]$_.Exception.Message; $brg.Stack = ($_ | Out-String) + $_.ScriptStackTrace }
}
$script:brg = $null
$script:job = $null
$script:rowMap = $null
$script:asking = $false

# Startet den Lauf; $doneText steht am Ende in der Statuszeile, $showResult: danach das Ergebnis-Fenster
function Start-SyncJob($tasks, [bool]$preview, [string]$doneText, [bool]$showResult) {
    $script:results.Clear()
    $script:lastFrac = -1.0; $script:lastStatus = ''
    $script:rowMap = New-Object 'System.Collections.Generic.Dictionary[int,object]'
    $script:brg = [hashtable]::Synchronized(@{
        Q = (New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'); Status = ''; Frac = 0.0; Cancel = $false
        Ask = $null; Answer = $false; Ev = (New-Object System.Threading.ManualResetEventSlim); Error = ''; Stack = ''; Failed = $false; Stopped = $false; Declined = $false; Infos = (New-Object System.Collections.Generic.List[object]) })
    $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    foreach ($f in $script:coreFns) { $iss.Commands.Add((New-Object System.Management.Automation.Runspaces.SessionStateFunctionEntry($f[0], $f[1]))) }
    $vars = @{ brg = $script:brg; NoGui = $false; headless = $false; cancel = $false; bulk = $false; inPlan = $false; scanCount = 0; tmpFiles = $null; copyBuf = $null; rowId = 0; logOn = $false
        version = $script:version; tmpSuffix = $script:tmpSuffix; pumpMs = $script:pumpMs; dataDir = $script:dataDir; stateDir = $script:stateDir; logFile = $script:logFile; errLog = $script:errLog
        warn = (New-Object System.Collections.Generic.List[string]); results = (New-Object System.Collections.Generic.List[object]) }
    foreach ($k in $vars.Keys) { $iss.Variables.Add((New-Object System.Management.Automation.Runspaces.SessionStateVariableEntry($k, $vars[$k], ''))) }
    # Momentaufnahme der Aufgaben: Aendern im Fenster wirkt erst beim naechsten Lauf
    $jobs = @(foreach ($t in $tasks) { $c = $t.PSObject.Copy(); $c.ExcludeDirs = [string[]]@($t.ExcludeDirs | Where-Object { $_ }); $c })
    $rs = [runspacefactory]::CreateRunspace($iss); $rs.ApartmentState = 'STA'; $rs.ThreadOptions = 'ReuseThread'; $rs.Open()
    $ps = [powershell]::Create(); $ps.Runspace = $rs
    # ein einziges Skript: AddStatement haengt sich in PowerShell 5.1 mit ReuseThread auf
    [void]$ps.AddScript("param(`$jobs, `$isPreview)`n" + $script:workerFns.ToString() + "`n" + $script:workerRun.ToString()).AddArgument($jobs).AddArgument($preview)
    $script:job = @{ Ps = $ps; Rs = $rs; H = $ps.BeginInvoke(); Results = $vars.results; Done = $doneText; Show = $showResult; Preview = $preview }
    $script:jobTimer.Start()
}
function Request-Cancel {
    $script:cancel = $true
    if ($script:brg) { $script:brg.Cancel = $true }
}
# Holt Meldungen ab, hoechstens $ms Millisekunden lang
function Receive-Rows([int]$ms) {
    $q = $script:brg.Q
    if ($q.Count -eq 0) { return }
    $sw = [System.Diagnostics.Stopwatch]::StartNew(); $m = $null; $scroll = $false
    while ($sw.ElapsedMilliseconds -lt $ms -and $q.TryDequeue([ref]$m)) {
        switch ($m[0]) {
            'row'    { $script:rowMap[$m[1]] = Out-Row $m[2] $m[3] $m[4]; if (-not $m[5]) { $scroll = $true } }
            'status' { Set-RowStatus $script:rowMap[$m[1]] $m[2] }
            'file'   { Set-RowFile $script:rowMap[$m[1]] $m[2] }
            'limit'  { Limit-Rows $m[1]; if ($m[2]) { $scroll = $true } }
        }
    }
    if ($scroll -and $script:rows.Count -gt 0) { $ui.lv.ScrollIntoView($script:rows[$script:rows.Count - 1]) }
}
function Update-Job {
    if (-not $script:job) { return }
    $b = $script:brg
    $finished = $script:job.H.IsCompleted   # vor dem Abholen pruefen: danach kommt nichts mehr dazu
    if ($b.Frac -ne $script:lastFrac) { $script:lastFrac = $b.Frac; Set-Progress $script:lastFrac }
    if ($b.Status -ne $script:lastStatus) { $script:lastStatus = $b.Status; Out-Status $script:lastStatus }
    Receive-Rows $(if ($finished) { 60 } else { 25 })
    if ($b.Ask -and -not $script:asking) {
        $script:asking = $true
        $a = $b.Ask
        try { $b.Answer = (Ask-User $a[0] $a[1] $a[2]) } catch { $b.Answer = $false } finally { $b.Ask = $null; $script:asking = $false; $b.Ev.Set() }
        return
    }
    if ($finished -and $b.Q.Count -eq 0 -and -not $script:asking) { Complete-Job }
}
function Complete-Job {
    $j = $script:job; $b = $script:brg
    $script:jobTimer.Stop()
    try { [void]$j.Ps.EndInvoke($j.H) } catch { if (-not $b.Error) { $b.Error = [string]$_.Exception.Message; $b.Stack = ($_ | Out-String) } }
    foreach ($r in $j.Results) { $script:results.Add($r) }
    $j.Ps.Dispose(); $j.Rs.Dispose(); $b.Ev.Dispose()
    $script:job = $null; $script:brg = $null; $script:rowMap = $null
    if ($b.Error) {
        try { Add-Content -Path $script:errLog -Value ("=== " + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + "`r`n" + $b.Stack) -Encoding UTF8 } catch { }
    }
    $was = $script:cancel
    Set-Busy $false
    $err = $false; foreach ($r in $j.Results) { if ($r.Errors -gt 0) { $err = $true } }
    $bad = ($b.Error -or $err -or $b.Failed)
    Stop-Flow $(if ($bad) { 'err' } elseif ($was -or $b.Stopped) { 'cancel' } elseif ($j.Preview) { '' } else { 'ok' })
    $ui.task.ProgressState = $(if ($bad) { 'Error' } else { 'None' })
    foreach ($x in $b.Infos) { Set-TaskInfo $x }
    $ui.lblStatus.Text = $(if ($b.Error) { 'Fehler, siehe fehler.log.' } elseif ($was) { 'Abgebrochen.' } else { $j.Done })
    if ($b.Error -and -not $script:closeRequested) { [void](Show-Msg "Der Lauf wurde durch einen Fehler beendet:`n`n$($b.Error)" 'DirToy' 'OK' 'Error') }
    if ($j.Show) { Show-ResultsIfNeeded }
}
$script:jobTimer = New-Object System.Windows.Threading.DispatcherTimer([System.Windows.Threading.DispatcherPriority]::Normal); $script:jobTimer.Interval = [TimeSpan]::FromMilliseconds(50)
$script:jobTimer.Add_Tick({ Update-Job })

# ---- Anleitung, wenn der Zeitplan nicht angelegt werden konnte (z. B. ohne Admin-Rechte)
function Show-ManualSchedDialog($t, $s, [string]$err) {
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
    $dlg = New-Dlg 'Zeitplan von Hand anlegen' 'Width="720" Height="600" ResizeMode="NoResize"' '<DockPanel Margin="20">
      <WrapPanel DockPanel.Dock="Bottom" Margin="0,16,0,0"><Button x:Name="b1" Style="{StaticResource Primary}" Margin="0,0,8,8">Befehl kopieren</Button><Button x:Name="b2" Margin="0,0,8,8">Argumente kopieren</Button><Button x:Name="b3" Margin="0,0,8,8">Aufgabenplaner öffnen</Button><Button x:Name="b5" Margin="0,0,8,8">Beim Anmelden starten</Button><Button x:Name="b4" IsCancel="True" Margin="0,0,0,8">Schließen</Button></WrapPanel>
      <TextBox x:Name="tb" Style="{StaticResource Multi}"/></DockPanel>'
    $dlg.tb.Text = $txt
    $script:mCmd = $cmd; $script:mArgs = $psArgs; $script:mTask = $t; $script:mDlg = $dlg
    $dlg.b1.Add_Click({ try { [System.Windows.Forms.Clipboard]::SetText($script:mCmd); [void](Show-Msg 'Der Befehl liegt in der Zwischenablage.' 'DirToy') } catch { } })
    $dlg.b2.Add_Click({ try { [System.Windows.Forms.Clipboard]::SetText($script:mArgs); [void](Show-Msg 'Die Argumente liegen in der Zwischenablage.' 'DirToy') } catch { } })
    $dlg.b3.Add_Click({ try { Start-Process 'taskschd.msc' } catch { [void](Show-Msg ('Der Aufgabenplaner ließ sich nicht öffnen (Windows-Taste, "Aufgabenplanung" tippen).') 'DirToy') } })
    $dlg.b4.Add_Click({ $script:mDlg.Win.Close() })
    $dlg.b5.Add_Click({
        $lnk = New-AutostartLink $script:mTask
        if ($lnk) { Save-Tasks; [void](Show-Msg "Eingerichtet. DirToy führt die Aufgabe ab jetzt bei jeder Windows-Anmeldung aus.`n`n$lnk" 'DirToy') }
        else { [void](Show-Msg 'Der Eintrag im Autostart-Ordner ließ sich nicht anlegen.' 'DirToy' 'OK' 'Warning') }
    })
    Show-Dlg $dlg
}

# ---- Zeitplan-Dialog
function Get-SchedInput {   # liest die Eingaben; Rueckgabe: Zeitplan oder Fehlertext
    $d = $script:sd
    $ty = 0; foreach ($k in 0..3) { if ($d["t$k"].IsChecked) { $ty = $k } }
    $num = { param([string]$v, [int]$lo, [int]$hi) $n = 0; if ([int]::TryParse($v.Trim(), [ref]$n) -and $n -ge $lo -and $n -le $hi) { $n } else { $null } }
    $time = [datetime]::MinValue
    $okTime = [datetime]::TryParseExact($d.time.Text.Trim(), [string[]]@('H:mm', 'HH:mm'), [Globalization.CultureInfo]::InvariantCulture, 'None', [ref]$time)
    if ($ty -le 2 -and -not $okTime) { return 'Bitte eine Uhrzeit im Format HH:MM eingeben, z. B. 18:30.' }
    $min = & $num $d.min.Text 1 1440; $rm = & $num $d.repMin.Text 1 1440; $rh = & $num $d.repHr.Text 1 24
    if ($ty -eq 2 -and $null -eq $min) { return 'Das Intervall muss zwischen 1 und 1440 Minuten liegen.' }
    $days = @(foreach ($k in $script:sdDays) { if ($d[$k[0]].IsChecked) { $k[1] } })
    if ($ty -eq 1 -and $days.Count -eq 0) { return 'Bitte mindestens einen Wochentag wählen.' }
    $rp = ($ty -le 1 -and [bool]$d.rep.IsChecked)
    if ($rp -and ($null -eq $rm -or $null -eq $rh)) { return 'Wiederholung: 1 bis 1440 Minuten, für 1 bis 24 Stunden.' }
    if ($rp -and $rm -gt $rh * 60) { return 'Das Intervall darf nicht länger sein als der Zeitraum.' }
    $nt = 1; foreach ($k in 0..2) { if ($d["n$k"].IsChecked) { $nt = $k } }
    return [pscustomobject]@{ Type = $ty; Time = $(if ($okTime) { $time.ToString('HH:mm') } else { '22:00' }); Days = $days; Minutes = $(if ($null -eq $min) { 60 } else { $min }); Start2 = ($ty -eq 2); Repeat = $rp; RepMinutes = $(if ($null -eq $rm) { 20 } else { $rm }); RepHours = $(if ($null -eq $rh) { 10 } else { $rh }); Notify = $nt }
}
function Update-SchedDialog {
    $d = $script:sd
    $ty = 0; foreach ($k in 0..3) { if ($d["t$k"].IsChecked) { $ty = $k } }
    $vis = { param([bool]$x) if ($x) { 'Visible' } else { 'Collapsed' } }
    $d.pTime.Visibility = & $vis ($ty -le 2)
    $d.lTime.Text = if ($ty -eq 2) { 'Startzeit (erster Lauf)' } else { 'Uhrzeit' }
    $d.pMin.Visibility = & $vis ($ty -eq 2)
    if ($ty -eq 2 -and -not $script:sdNowSet) { $script:sdNowSet = $true; $d.time.Text = [datetime]::Now.ToString('HH:mm') }
    $d.pRep.Visibility = & $vis ($ty -le 1)
    $on = ($ty -le 1 -and [bool]$d.rep.IsChecked)
    $d.repMin.IsEnabled = $d.repHr.IsEnabled = $on
    $d.pDays.Visibility = & $vis ($ty -eq 1)
    $d.info.Text = 'Die Aufgabe läuft im Hintergrund, solange du angemeldet bist. ' + $(if ($ty -eq 2 -or $on) { 'Verpasste Läufe werden bei Intervallen nicht nachgeholt.' } else { 'Verpasste Läufe werden nachgeholt.' })
}
$script:sdDays = @(@('d0', 'Monday'), @('d1', 'Tuesday'), @('d2', 'Wednesday'), @('d3', 'Thursday'), @('d4', 'Friday'), @('d5', 'Saturday'), @('d6', 'Sunday'))
function Show-ScheduleDialog($t) {
    $dlg = New-Dlg 'Zeitplan' 'Width="600" SizeToContent="Height" ResizeMode="NoResize"' '<StackPanel Margin="24">
      <TextBlock x:Name="head" FontSize="20" FontWeight="SemiBold" TextTrimming="CharacterEllipsis" Margin="0,0,0,16"/>
      <TextBlock Text="Wann ausführen?" Style="{StaticResource MutedText}" Margin="0,0,0,6"/>
      <Border Background="{DynamicResource Surface}" CornerRadius="8" HorizontalAlignment="Left"><StackPanel Orientation="Horizontal"><RadioButton x:Name="t0" GroupName="t" Style="{StaticResource Seg}">Täglich</RadioButton><RadioButton x:Name="t1" GroupName="t" Style="{StaticResource Seg}">Wöchentlich</RadioButton><RadioButton x:Name="t2" GroupName="t" Style="{StaticResource Seg}">Alle X Minuten</RadioButton><RadioButton x:Name="t3" GroupName="t" Style="{StaticResource Seg}">Bei Anmeldung</RadioButton></StackPanel></Border>
      <StackPanel Orientation="Horizontal" Margin="0,16,0,0">
        <StackPanel x:Name="pMin" Margin="0,0,20,0"><TextBlock Text="Intervall in Minuten" Style="{StaticResource MutedText}" Margin="0,0,0,6"/><TextBox x:Name="min" Width="120" AutomationProperties.Name="Intervall in Minuten"/></StackPanel>
        <StackPanel x:Name="pTime"><TextBlock x:Name="lTime" Style="{StaticResource MutedText}" Margin="0,0,0,6"/><TextBox x:Name="time" Width="120" AutomationProperties.Name="Uhrzeit"/></StackPanel></StackPanel>
      <StackPanel x:Name="pDays" Orientation="Horizontal" Margin="0,16,0,0"><CheckBox x:Name="d0" Style="{StaticResource Chip}">Mo</CheckBox><CheckBox x:Name="d1" Style="{StaticResource Chip}">Di</CheckBox><CheckBox x:Name="d2" Style="{StaticResource Chip}">Mi</CheckBox><CheckBox x:Name="d3" Style="{StaticResource Chip}">Do</CheckBox><CheckBox x:Name="d4" Style="{StaticResource Chip}">Fr</CheckBox><CheckBox x:Name="d5" Style="{StaticResource Chip}">Sa</CheckBox><CheckBox x:Name="d6" Style="{StaticResource Chip}">So</CheckBox></StackPanel>
      <StackPanel x:Name="pRep" Orientation="Horizontal" Margin="0,16,0,0"><CheckBox x:Name="rep" VerticalAlignment="Center">Danach wiederholen alle</CheckBox><TextBox x:Name="repMin" Width="60" Margin="10,0" AutomationProperties.Name="Wiederholung in Minuten"/><TextBlock Text="Min. für" VerticalAlignment="Center"/><TextBox x:Name="repHr" Width="50" Margin="10,0" AutomationProperties.Name="Wiederholung für Stunden"/><TextBlock Text="Std." VerticalAlignment="Center"/></StackPanel>
      <TextBlock Text="Windows-Meldung nach dem Lauf" Style="{StaticResource MutedText}" Margin="0,20,0,8"/>
      <RadioButton x:Name="n0" GroupName="n" Margin="0,0,0,8">Keine Meldung</RadioButton><RadioButton x:Name="n1" GroupName="n" Margin="0,0,0,8">Wenn etwas synchronisiert wurde oder Fehler auftraten</RadioButton><RadioButton x:Name="n2" GroupName="n">Nur bei Fehlern</RadioButton>
      <TextBlock x:Name="info" Style="{StaticResource MutedText}" TextWrapping="Wrap" Margin="0,20,0,0"/>
      <DockPanel Margin="0,20,0,0" LastChildFill="False"><Button x:Name="save" Style="{StaticResource Primary}" IsDefault="True" MinWidth="120" Margin="0,0,8,0">Aktivieren</Button><Button x:Name="remove">Zeitplan entfernen</Button><Button x:Name="cancel" DockPanel.Dock="Right" IsCancel="True">Abbrechen</Button></DockPanel>
    </StackPanel>'
    $script:sd = $dlg; $script:sdTask = $t
    $dlg.head.Text = "Zeitplan für $($t.Name)"
    $sc = $t.Schedule
    # Startzeit beim Intervall: bei neuen Zeitplaenen und Altbestand ohne Startzeit ist der Vorschlag "jetzt"
    $script:sdNowSet = [bool]($sc -and [int]$sc.Type -eq 2 -and [bool]$sc.Start2)
    $dlg.time.Text = '22:00'; $dlg.min.Text = '60'; $dlg.repMin.Text = '20'; $dlg.repHr.Text = '10'
    $ty = if ($sc) { [int]$sc.Type } else { 0 }
    $dlg["t$ty"].IsChecked = $true
    $dlg["n$(if ($sc -and $null -ne $sc.Notify) { [int]$sc.Notify } else { 1 })"].IsChecked = $true
    foreach ($k in $script:sdDays) { $dlg[$k[0]].IsChecked = $(if ($sc) { @($sc.Days) -contains $k[1] } else { $k[1] -notin @('Saturday', 'Sunday') }) }
    if ($sc) {
        if ([string]$sc.Time) { $dlg.time.Text = [string]$sc.Time }
        if ($sc.Minutes) { $dlg.min.Text = [string]$sc.Minutes }
        if ([bool]$sc.Repeat) {
            $dlg.rep.IsChecked = $true
            if ($sc.RepMinutes) { $dlg.repMin.Text = [string]$sc.RepMinutes }
            if ($sc.RepHours) { $dlg.repHr.Text = [string]$sc.RepHours }
        }
    }
    $dlg.remove.IsEnabled = [bool]$t.SchedName
    if ($t.SchedName) { $dlg.save.Content = 'Speichern' }
    foreach ($k in 't0', 't1', 't2', 't3') { $dlg[$k].Add_Checked({ Update-SchedDialog }) }
    $dlg.rep.Add_Checked({ Update-SchedDialog }); $dlg.rep.Add_Unchecked({ Update-SchedDialog })
    Update-SchedDialog
    $dlg.save.Add_Click({
        $new = Get-SchedInput
        if ($new -is [string]) { [void](Show-Msg $new 'Zeitplan' 'OK' 'Warning'); return }
        try { Register-Sched $script:sdTask $new; Save-Tasks; $script:sd.Win.Close() }
        catch { Show-ManualSchedDialog $script:sdTask $new $_.Exception.Message }
    })
    $dlg.remove.Add_Click({
        try { Unregister-Sched $script:sdTask; $script:sdTask.Schedule = $null; Save-Tasks; $script:sd.Win.Close() }
        catch { [void](Show-Msg $_.Exception.Message 'Fehler' 'OK' 'Error') }
    })
    $dlg.cancel.Add_Click({ $script:sd.Win.Close() })
    Show-Dlg $dlg
}
function Update-SchedLabel {
    $t = $script:cur
    if (-not $t) { $ui.lblSched.Text = ''; return }
    $info = Get-SchedInfo $t
    if ($info) {
        $n = if ($info.Next -and $info.Next.Year -gt 2000) { '  ·  nächster Lauf ' + $info.Next.ToString('dd.MM. HH:mm') } else { '' }
        $ui.lblSched.Text = 'Zeitplan: ' + (Get-SchedText $t.Schedule) + $n
    } elseif ($t.SchedName) { $ui.lblSched.Text = 'ACHTUNG: Zeitplan fehlt im Aufgabenplaner, bitte hier neu aktivieren' }
    elseif ($t.AutoLnk -and (Test-Path -LiteralPath ([string]$t.AutoLnk))) { $ui.lblSched.Text = 'Läuft bei jeder Windows-Anmeldung (Autostart-Ordner)' }
    elseif ($t.Schedule) { $ui.lblSched.Text = 'ACHTUNG: Zeitplan ist nicht angelegt, bitte hier neu aktivieren' }
    else { $ui.lblSched.Text = 'Kein Zeitplan' }
}
# ---- Hilfe-Fenster
function Show-Help {
    $dlg = New-Dlg 'DirToy - Hilfe' 'Width="760" Height="720" MinWidth="560" MinHeight="420"' '<DockPanel Margin="24,16,24,20">
      <DockPanel DockPanel.Dock="Bottom" Margin="0,16,0,0" LastChildFill="False"><Button x:Name="lnk" Margin="0,0,16,0">Desktop-Verknüpfung</Button><CheckBox x:Name="showRes" VerticalAlignment="Center">Ergebnis-Fenster nach dem Lauf zeigen</CheckBox><Button x:Name="close" DockPanel.Dock="Right" Style="{StaticResource Primary}" IsCancel="True" IsDefault="True">Schließen</Button></DockPanel>
      <ScrollViewer x:Name="sv" VerticalScrollBarVisibility="Auto"><StackPanel x:Name="p" Margin="0,0,16,0"/></ScrollViewer></DockPanel>'
    $script:hp = $dlg.p
    $script:helpDlg = $dlg
    function HelpT([string]$t, [double]$size, $brush, [string]$margin, [bool]$bold) {
        $x = New-Object System.Windows.Controls.TextBlock; $x.Text = $t; $x.FontSize = $size; $x.Foreground = $brush; $x.Margin = $margin; $x.TextWrapping = 'Wrap'
        if ($bold) { $x.FontWeight = 'SemiBold' }
        [void]$script:hp.Children.Add($x); return
    }
    function HelpH($t) { HelpT $t 16 $script:br.Accent '0,20,0,4' $true }
    function HelpP($t) { HelpT ([string]$t).Trim() 14 $script:br.Text '0,3' $false }
    function HelpB($k, $t) {
        $x = New-Object System.Windows.Controls.TextBlock; $x.TextWrapping = 'Wrap'; $x.Margin = '12,3,0,3'
        $r = New-Object System.Windows.Documents.Run "$k   "; $r.FontWeight = 'SemiBold'
        $x.Inlines.Add($r); $x.Inlines.Add((New-Object System.Windows.Documents.Run ([string]$t)))
        [void]$script:hp.Children.Add($x)
    }
    HelpT 'DirToy' 26 $script:br.Accent '0' $true
    HelpT "Version $($script:version)" 12 $script:br.Muted '0,0,0,10' $false
    HelpP 'Hält zwei Ordner synchron. Du kannst beliebig viele Aufgaben anlegen, jede mit eigenen Ordnern, Modus, Ausschlüssen und Zeitplan.'
    HelpH 'So geht es'
    HelpB '1.' 'Links auf "Neue Aufgabe" klicken und der Aufgabe einen Namen geben.'
    HelpB '2.' 'Ordner A und Ordner B wählen (Knopf "..." neben dem Pfad).'
    HelpB '3.' 'Modus wählen (siehe unten).'
    HelpB '4.' '"Vorschau" zeigt, was passieren würde, ohne etwas zu verändern.'
    HelpB '5.' '"Starten" führt es aus. Zwischen den Ordnern siehst du die Richtung, der Balken zeigt den Fortschritt, die Liste das Ergebnis.'
    HelpH 'Die drei Modi'
    HelpB 'Synchronisieren' 'Beide Richtungen. Neue und geänderte Dateien werden auf die andere Seite kopiert, bei Änderungen auf beiden Seiten gewinnt die neuere Datei. Löscht du eine Datei auf einer Seite, wird sie beim nächsten Lauf auch auf der anderen gelöscht. Beim allerersten Lauf wird nichts gelöscht.'
    HelpB 'Echo' 'Nur A nach B. B wird zu einer exakten Kopie von A: Was in A fehlt, wird in B gelöscht, und Änderungen in B werden überschrieben.'
    HelpB 'Beitragen' 'Nur A nach B. Neue und geänderte Dateien aus A werden kopiert, es wird nie etwas gelöscht.'
    HelpP '   Bei gleicher Zeit, aber anderer Größe meldet das Tool einen Konflikt und überspringt die Datei.'
    HelpH 'Nicht synchronisieren'
    HelpP 'Das Feld liegt hinter dem Zahnrad oben rechts. Darin stehen Dateinamen oder Muster, getrennt mit Semikolon. * steht für beliebig viele Zeichen, ? für ein Zeichen. Die Muster gelten für Dateien und Ordnernamen in beiden Ordnern. Ausgeschlossenes wird weder kopiert noch gelöscht.'
    HelpB 'Beispiele' 'Thumbs.db;*.tmp;~$*;node_modules;*.bak'
    HelpH 'Ordner abwählen'
    HelpP 'Hinter dem Zahnrad oben rechts, mit "Ordner abwählen ...", siehst du beide Ordner als Baum nebeneinander. Entfernst du bei einem Ordner den Haken, wird er samt allen Unterordnern nicht synchronisiert (auf keiner Seite kopiert oder gelöscht). Der Haken gilt für beide Seiten. Neue Ordner, die später dazukommen, sind immer dabei, gespeichert werden nur die abgewählten. Ein abgewählter Ordner bleibt auch dann abgewählt, wenn er gelöscht und später neu angelegt wird; solche Einträge erscheinen grau mit "(nicht vorhanden)" und lassen sich durch Anhaken entfernen. "Alle wieder einschließen" setzt alle Haken zurück.'
    HelpH 'Löschen und Sicherheit'
    HelpP 'Dateien werden zuerst unter einem Zwischennamen (.dirtoy-tmp) kopiert und erst am Ende umbenannt. Bricht ein Lauf ab oder schließt du das Fenster, bleibt die alte Datei im Ziel unverändert; übrig gebliebene Zwischendateien räumt DirToy beim nächsten Lauf auf. Mit "Abbrechen" stoppst du einen Lauf nach der aktuellen Datei.'
    HelpP 'Kann ein Ordner nicht gelesen werden, wird dort auf beiden Seiten nichts verändert. Vor dem Löschen fragt das Tool nach. Gelöscht wird in den Papierkorb, bei Netzlaufwerken ohne Papierkorb aber endgültig. Schau dir deshalb bei "Synchronisieren" und "Echo" zuerst die Vorschau an. Ordner dürfen nicht identisch sein oder ineinander liegen. Ordner werden komplett mit allen Unterordnern gespiegelt, auch leere. Ein Ordner wird nur gelöscht, wenn er danach wirklich leer ist (ausgeschlossene Dateien darin verhindern das Löschen).'
    HelpH 'Zeitplan (automatisch)'
    HelpP 'Mit dem Zeitplan-Knopf oben rechts legst du für die gewählte Aufgabe einen Eintrag im Windows-Aufgabenplaner an: täglich, wöchentlich, alle X Minuten (mit Startzeit) oder bei der Anmeldung. Täglich und wöchentlich lassen sich mit "Danach wiederholen alle ... Min. für ... Std." kombinieren (z. B. täglich ab 08:00 alle 20 Minuten für 10 Stunden). Du kannst den Eintrag im Aufgabenplaner jederzeit ändern oder entfernen. Das Tool muss dafür nicht laufen, aber du musst bei Windows angemeldet sein. Verpasste Läufe werden nachgeholt, bei Intervallen und Wiederholungen aber nicht. DirToy prüft nach dem Anlegen, ob der Eintrag wirklich existiert. Fehlen auf dem Rechner die Rechte (kein Administrator), zeigt DirToy eine Anleitung zum Anlegen von Hand, mit kopierbarem Befehl und als Notlösung einem Autostart-Eintrag. Bei automatischen Läufen gibt es keine Rückfrage vor dem Löschen. Wirkt eine Löschung auffällig (eine Seite ist ganz leer, oder mindestens 10 Dateien und mehr als die Hälfte würden gelöscht), bricht der automatische Lauf ab, ohne etwas zu verändern. Ist das gewollt, die Aufgabe einmal von Hand starten.'
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
    $dlg.showRes.IsChecked = [bool](Get-Setting 'ShowResult' $true)
    $dlg.showRes.Add_Checked({ Set-Setting 'ShowResult' $true }); $dlg.showRes.Add_Unchecked({ Set-Setting 'ShowResult' $false })
    $dlg.lnk.Add_Click({
        $p = New-DesktopShortcut
        if ($p) { [void](Show-Msg "Die Verknüpfung wurde auf dem Desktop angelegt:`n$p" 'DirToy' 'OK' 'Information') }
        else { [void](Show-Msg 'Die Verknüpfung konnte nicht angelegt werden.' 'DirToy' 'OK' 'Warning') }
    })
    $dlg.close.Add_Click({ $script:helpDlg.Win.Close() })
    Show-Dlg $dlg
}

# ---- Update-Fenster (mode: new = neue Version da, current = aktuell, error = Pruefung fehlgeschlagen)
function Show-UpdateDialog($info, [string]$mode) {
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
    $new = ($mode -eq 'new')
    $dlg = New-Dlg 'DirToy - Update' 'Width="600" SizeToContent="Height" ResizeMode="NoResize"' ('<StackPanel Margin="24"><TextBlock x:Name="head" FontSize="20" FontWeight="SemiBold" Foreground="{DynamicResource Accent}"/><TextBlock x:Name="sub" Style="{StaticResource MutedText}" TextWrapping="Wrap" Margin="0,4,0,0"/>' +
        $(if ($new) { '<TextBlock Text="Änderungen" Style="{StaticResource MutedText}" Margin="0,16,0,6"/><TextBox x:Name="notes" Style="{StaticResource Multi}" Height="240" AutomationProperties.Name="Änderungen"/>' } else { '' }) +
        '<CheckBox x:Name="auto" Margin="0,18,0,0">Beim Start automatisch nach Updates suchen</CheckBox><DockPanel Margin="0,20,0,0" LastChildFill="False">' +
        $(if ($new) { '<Button x:Name="go" Style="{StaticResource Primary}" IsDefault="True" Margin="0,0,8,0">Jetzt aktualisieren</Button><Button x:Name="web">Release-Seite</Button><Button x:Name="later" DockPanel.Dock="Right" IsCancel="True">Später</Button>' } else { '<Button x:Name="later" DockPanel.Dock="Right" Style="{StaticResource Primary}" IsCancel="True" IsDefault="True">Schließen</Button>' }) + '</DockPanel></StackPanel>')
    $dlg.head.Text = $head; $dlg.sub.Text = $sub
    $dlg.auto.IsChecked = [bool](Get-Setting 'UpdateCheck' $true)
    $script:updAction = ''; $script:updDlg = $dlg
    if ($new) {
        $notes = [string]$info.Notes; if ($notes.Length -gt 3000) { $notes = $notes.Substring(0, 3000) + ' ...' }
        $dlg.notes.Text = $(if ($notes.Trim()) { $notes } else { '(keine Beschreibung)' })
        $dlg.go.Add_Click({ $script:updAction = 'install'; $script:updDlg.Win.Close() })
        $dlg.web.Add_Click({ $script:updAction = 'web'; $script:updDlg.Win.Close() })
    }
    $dlg.later.Add_Click({ $script:updDlg.Win.Close() })
    Show-Dlg $dlg
    Set-Setting 'UpdateCheck' ([bool]$dlg.auto.IsChecked)
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
    if ($script:busy) { [void](Show-Msg 'Bitte erst den laufenden Vorgang beenden oder abbrechen.' 'DirToy' 'OK' 'Information'); return }
    $q = "DirToy $($info.Version) herunterladen und installieren?`n`nDie aktuelle Datei wird als DirToy.ps1.bak-$($script:version) gesichert. Danach startet DirToy neu."
    if ((Show-Msg $q 'DirToy - Update' 'YesNo' 'Question') -ne 'Yes') { return }
    try {
        [System.Windows.Input.Mouse]::OverrideCursor = [System.Windows.Input.Cursors]::Wait
        Install-Update $info $script:scriptPath ''
    } catch {
        [System.Windows.Input.Mouse]::OverrideCursor = $null
        [void](Show-Msg "Das Update ist fehlgeschlagen. Die bisherige Version bleibt unverändert.`n`n$($_.Exception.Message)" 'DirToy - Update' 'OK' 'Error')
        return
    }
    [System.Windows.Input.Mouse]::OverrideCursor = $null
    Save-Tasks
    Restart-DirToy

    $win.Close()
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
    $ui.btnUpd.Visibility = $(if ($show) { 'Visible' } else { 'Collapsed' })
    if ($show) { $ui.btnUpd.Content = "Update verfügbar: $($info.Version)" }
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
    $n = [DirToyNode]::new(); $n.Text = $text; $n.Path = $path; $n.Kind = $kind; $n.Root = $root; $n.Loaded = ($kind -ne 'normal')
    if ($kind -eq 'normal') { $x = [DirToyNode]::new(); $x.Text = '...'; $x.Kind = 'dummy'; $x.Loaded = $true; $n.Nodes.Add($x) }   # Platzhalter fuer Pfeil
    return $n
}
function Fill-Nodes($coll, [string]$parentPath, [string]$root) {
    $coll.Clear()
    $abs = Join-Path $root $parentPath
    try { $dirs = @((New-Object System.IO.DirectoryInfo $abs).GetDirectories() | Sort-Object Name) } catch { $dirs = @() }
    foreach ($d in $dirs) {
        if ($d.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { continue }
        $p = $parentPath + $d.Name + '\'
        if (Test-Excluded $d.Name $script:fdPats) { $coll.Add((New-TreeNodeFor ($d.Name + '   (durch Muster ausgeschlossen)') $p 'pattern' $root)) }
        else { $coll.Add((New-TreeNodeFor $d.Name $p 'normal' $root)) }
    }
    # abgewaehlte Ordner, die es nirgends mehr gibt
    foreach ($x in @($script:fdSet | Sort-Object)) {
        if (Test-ExistsAny $x) { continue }
        $par = Get-ParentPath $x
        $orphan = ($par -ne '') -and -not (Test-ExistsAny $par)
        if ($parentPath -eq '' -and $orphan) { $coll.Add((New-TreeNodeFor ($x.TrimEnd('\') + '   (nicht vorhanden)') $x 'missing' $root)) }
        elseif ($par -eq $parentPath -and -not $orphan) {
            $name = $x.TrimEnd('\').Substring($par.Length)
            $coll.Add((New-TreeNodeFor ($name + '   (nicht vorhanden)') $x 'missing' $root))
        }
    }
}
function Update-TreeChecks($nodes) {
    foreach ($n in $nodes) {
        if ($n.Kind -eq 'dummy') { continue }
        $excl = ($n.Kind -ne 'normal') -or (Test-EffExcluded $n.Path)
        $n.Checked = -not $excl
        $n.Brush = $(if ($excl) { $script:br.Muted } else { $script:br.Text })
        if ($n.Loaded -and $n.Nodes.Count -gt 0) { Update-TreeChecks $n.Nodes }
    }
}
function Refresh-Trees {
    foreach ($c in @($script:fdA, $script:fdB)) { Update-TreeChecks $c }
    $script:fdDlg.count.Text = "$($script:fdSet.Count) Ordner abgewählt"
}
function Remove-MissingIn($coll, [string]$path) {
    for ($i = $coll.Count - 1; $i -ge 0; $i--) {
        $n = $coll[$i]
        if ($n.Kind -eq 'missing' -and $n.Path -ieq $path) { $coll.RemoveAt($i) }
        elseif ($n.Loaded -and $n.Nodes.Count -gt 0) { Remove-MissingIn $n.Nodes $path }
    }
}
function Show-FolderDialog($t) {
    try {
        $script:fdRootA = [System.IO.Path]::GetFullPath([string]$t.A).TrimEnd('\')
        $script:fdRootB = [System.IO.Path]::GetFullPath([string]$t.B).TrimEnd('\')
    } catch { $script:fdRootA = ''; $script:fdRootB = '' }
    if (-not $t.A -or -not $t.B -or -not (Test-Path -LiteralPath $script:fdRootA -PathType Container) -or -not (Test-Path -LiteralPath $script:fdRootB -PathType Container)) {
        [void](Show-Msg ('Bitte zuerst Ordner A und Ordner B angeben (beide müssen existieren).') 'Ordner wählen')
        return
    }
    $script:fdTask = $t
    $script:fdPats = Get-Patterns $t
    $script:fdSet = Get-ExcludeDirs $t
    $tree = '<TreeView x:Name="{0}" Background="Transparent" BorderThickness="0" AutomationProperties.Name="{1}"><TreeView.ItemTemplate><HierarchicalDataTemplate ItemsSource="{{Binding Nodes}}"><CheckBox IsChecked="{{Binding Checked, Mode=TwoWay}}" AutomationProperties.Name="{{Binding Text}}"><TextBlock Text="{{Binding Text}}" Foreground="{{Binding Brush}}"/></CheckBox></HierarchicalDataTemplate></TreeView.ItemTemplate></TreeView>'
    $dlg = New-Dlg 'Ordner auswählen' 'Width="1020" Height="720" MinWidth="700" MinHeight="460"' ('<DockPanel Margin="24">
      <TextBlock DockPanel.Dock="Top" Text="Ordner auswählen" FontSize="20" FontWeight="SemiBold"/>
      <TextBlock DockPanel.Dock="Top" Style="{StaticResource MutedText}" TextWrapping="Wrap" Margin="0,4,0,14" Text="Haken entfernen = Ordner samt Unterordnern wird nicht synchronisiert. Neue Ordner sind standardmäßig dabei (Haken gesetzt)."/>
      <DockPanel DockPanel.Dock="Bottom" Margin="0,14,0,0" LastChildFill="False"><Button x:Name="all">Alle wieder einschließen</Button><TextBlock x:Name="count" Style="{StaticResource MutedText}" VerticalAlignment="Center" Margin="14,0"/><Button x:Name="cancel" DockPanel.Dock="Right" IsCancel="True">Abbrechen</Button><Button x:Name="ok" DockPanel.Dock="Right" Style="{StaticResource Primary}" IsDefault="True" MinWidth="100" Margin="0,0,8,0">OK</Button></DockPanel>
      <TextBlock x:Name="hint" DockPanel.Dock="Bottom" Style="{StaticResource MutedText}" Foreground="{DynamicResource Warn}" Margin="0,10,0,0"/>
      <Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="16"/><ColumnDefinition/></Grid.ColumnDefinitions>
        <Border Background="{DynamicResource Surface}" CornerRadius="12" Padding="12"><DockPanel><TextBlock x:Name="la" DockPanel.Dock="Top" Style="{StaticResource MutedText}" TextTrimming="CharacterEllipsis" Margin="4,0,0,8"/>' + ($tree -f 'tvA', 'Ordner A') + '</DockPanel></Border>
        <Border Grid.Column="2" Background="{DynamicResource Surface}" CornerRadius="12" Padding="12"><DockPanel><TextBlock x:Name="lb" DockPanel.Dock="Top" Style="{StaticResource MutedText}" TextTrimming="CharacterEllipsis" Margin="4,0,0,8"/>' + ($tree -f 'tvB', 'Ordner B') + '</DockPanel></Border></Grid></DockPanel>')
    $script:fdDlg = $dlg
    $dlg.la.Text = 'A:  ' + $script:fdRootA; $dlg.lb.Text = 'B:  ' + $script:fdRootB
    $script:fdA = [System.Collections.ObjectModel.ObservableCollection[DirToyNode]]::new()
    $script:fdB = [System.Collections.ObjectModel.ObservableCollection[DirToyNode]]::new()
    $dlg.tvA.ItemsSource = $script:fdA; $dlg.tvB.ItemsSource = $script:fdB
    $expand = [System.Windows.RoutedEventHandler] {
        param($s, $e)
        $n = $e.OriginalSource.DataContext
        if ($n -is [DirToyNode] -and -not $n.Loaded) { $n.Loaded = $true; Fill-Nodes $n.Nodes $n.Path $n.Root; Refresh-Trees }
    }
    $checked = [System.Windows.RoutedEventHandler] {
        param($s, $e)
        if ($e.OriginalSource -isnot [System.Windows.Controls.CheckBox]) { return }
        $n = $e.OriginalSource.DataContext
        if ($n -isnot [DirToyNode] -or $n.Kind -eq 'dummy') { return }
        # kam die Aenderung aus dem Baum selbst (Haken passt schon zur Auswahl)? Dann nichts tun
        if ($n.Checked -eq ($n.Kind -eq 'normal' -and -not (Test-EffExcluded $n.Path))) { return }
        $script:fdDlg.hint.Text = ''
        if ($n.Kind -eq 'pattern') { $n.Checked = $false; $script:fdDlg.hint.Text = 'Dieser Ordner ist durch ein Muster im Ausschlussfeld ausgeschlossen.'; return }
        if ($n.Checked -and (Test-AncExcluded $n.Path)) { $n.Checked = $false; $script:fdDlg.hint.Text = 'Ein übergeordneter Ordner ist abgewählt. Dort zuerst den Haken wieder setzen.'; return }
        if ($n.Checked) {
            [void]$script:fdSet.Remove($n.Path)
            if ($n.Kind -eq 'missing') { Remove-MissingIn $script:fdA $n.Path; Remove-MissingIn $script:fdB $n.Path }
        } else { [void]$script:fdSet.Add($n.Path) }
        Refresh-Trees
    }
    foreach ($tv in $dlg.tvA, $dlg.tvB) {
        $tv.AddHandler([System.Windows.Controls.TreeViewItem]::ExpandedEvent, $expand)
        $tv.AddHandler([System.Windows.Controls.Primitives.ToggleButton]::CheckedEvent, $checked)
        $tv.AddHandler([System.Windows.Controls.Primitives.ToggleButton]::UncheckedEvent, $checked)
    }
    $dlg.all.Add_Click({
        $script:fdSet.Clear()
        Fill-Nodes $script:fdA '' $script:fdRootA; Fill-Nodes $script:fdB '' $script:fdRootB
        Refresh-Trees
    })
    $dlg.ok.Add_Click({
        $script:fdTask.ExcludeDirs = [string[]]@($script:fdSet | Sort-Object)
        Save-Tasks
        $script:fdDlg.Win.Close()
    })
    $dlg.cancel.Add_Click({ $script:fdDlg.Win.Close() })
    Fill-Nodes $script:fdA '' $script:fdRootA
    Fill-Nodes $script:fdB '' $script:fdRootB
    Refresh-Trees
    Show-Dlg $dlg
}
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
function Show-Mode([int]$m) { $ui.lblMode.Text = $script:modeHelp[$m]; Show-Direction $m }
function Show-Cur {
    $i = $ui.lb.SelectedIndex
    $script:loading = $true
    if ($i -ge 0) {
        $script:cur = $script:tasks[$i]
        $ui.tbName.Text = [string]$script:cur.Name; $ui.tbA.Text = [string]$script:cur.A; $ui.tbB.Text = [string]$script:cur.B; $ui.tbEx.Text = [string]$script:cur.Exclude
        $mi = [int]$script:cur.Mode; if ($mi -lt 0 -or $mi -gt 2) { $mi = 0 }
        $ui["m$mi"].IsChecked = $true; Show-Mode $mi
    } else {
        $script:cur = $null
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
