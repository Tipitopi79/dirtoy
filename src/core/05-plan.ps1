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
            if ($script:lblStatus) { $script:lblStatus.Text = "Vergleiche ... $idx / $total" }
            Pump
            if ($script:cancel) { throw 'DIRTOY_CANCEL' }
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

