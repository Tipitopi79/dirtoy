# Tests fuer den Sync-Kern. Arbeitet nur in einem eigenen Temp-Ordner.
# Start: powershell -NoProfile -ExecutionPolicy Bypass -STA -File tests\test-kern.ps1
$base = Join-Path ([IO.Path]::GetTempPath()) ('dirtoy-test-' + [guid]::NewGuid().ToString('N'))
$env:DIRTOY_DATA = Join-Path $base 'daten'
[void](New-Item -ItemType Directory -Force -Path $env:DIRTOY_DATA)
. (Join-Path (Split-Path $PSScriptRoot) 'DirToy.ps1') -NoGui

$script:fails = 0; $script:nr = 0
function Check([string]$name, [bool]$cond) {
    if ($cond) { Write-Host "ok      $name" } else { $script:fails++; Write-Host "FEHLER  $name" }
}
function Put([string]$path, [string]$text) {
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path))
    [IO.File]::WriteAllText($path, $text)
    [IO.File]::SetLastWriteTimeUtc($path, [datetime]'2026-01-01')
}
# Neues Ordnerpaar; beide Seiten: top.txt, sub\x.txt, sub\tief\y.txt
function New-Pair([int]$mode, [bool]$withState) {
    $script:nr++
    $t = New-Task "Test$($script:nr)"
    $t.A = Join-Path $base "$($script:nr)\A"; $t.B = Join-Path $base "$($script:nr)\B"; $t.Mode = $mode
    foreach ($r in $t.A, $t.B) { foreach ($f in 'top.txt', 'sub\x.txt', 'sub\tief\y.txt') { Put (Join-Path $r $f) 'inhalt' } }
    if ($withState) { Save-State $t.Id @('top.txt', 'sub\', 'sub\x.txt', 'sub\tief\', 'sub\tief\y.txt') }
    return $t
}
function Set-Readable([string]$dir, [bool]$readable) {
    $acl = [IO.Directory]::GetAccessControl($dir, 'Access')
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $rule = New-Object Security.AccessControl.FileSystemAccessRule($sid, 'ListDirectory', 'Deny')
    if ($readable) { [void]$acl.RemoveAccessRule($rule) } else { $acl.AddAccessRule($rule) }
    [IO.Directory]::SetAccessControl($dir, $acl)
}
function Dels($plan) { @($plan | Where-Object { $_.Typ -in 'Delete', 'RmDir' }).Count }

try {
    # --- normales Verhalten
    foreach ($m in 0, 1, 2) { $t = New-Pair $m $true; Check "Modus ${m}: gleich -> nichts zu tun" ((Build-Plan $t).Plan.Count -eq 0) }
    $t = New-Pair 0 $true; [IO.File]::Delete("$($t.A)\top.txt")
    $p = (Build-Plan $t).Plan; Check 'Sync: in A geloescht -> in B loeschen' ($p.Count -eq 1 -and $p[0].Typ -eq 'Delete' -and $p[0].Src -eq "$($t.B)\top.txt")
    $t = New-Pair 0 $false; [IO.File]::Delete("$($t.A)\top.txt")
    $p = (Build-Plan $t).Plan; Check 'Sync ohne Stand: B -> A kopieren, nichts loeschen' ($p.Count -eq 1 -and $p[0].Typ -eq 'Copy')
    $t = New-Pair 1 $false; [IO.File]::Delete("$($t.A)\top.txt"); Check 'Echo: in B loeschen' ((Dels (Build-Plan $t).Plan) -eq 1)
    $t = New-Pair 2 $true; [IO.File]::Delete("$($t.A)\top.txt"); Check 'Beitragen: loescht nie' ((Build-Plan $t).Plan.Count -eq 0)
    $t = New-Pair 0 $true; [IO.Directory]::Delete("$($t.A)\sub", $true)
    Check 'Sync: ganzer Ordner geloescht -> 2 Dateien + 2 Ordner loeschen' ((Dels (Build-Plan $t).Plan) -eq 4)

    # --- Fortschrittsbalken (rundete frueher auf ganz leer oder ganz voll)
    $script:progTrack = @{ Width = 1000 }; $script:progFill = @{ Width = -1 }
    foreach ($c in @(0, 0), @(0.35, 350), @(0.5, 500), @(0.9, 900), @(1, 1000), @(2, 1000)) {
        Set-Progress $c[0]; Check "Fortschritt $($c[0]) -> $($c[1])" ($script:progFill.Width -eq $c[1])
    }
    $script:progTrack = $null; $script:progFill = $null

    # --- geaenderte Dateien, Ausschluesse
    foreach ($c in @(0, 'A', 'A'), @(0, 'B', 'B'), @(1, 'A', 'A'), @(1, 'B', 'A'), @(2, 'A', 'A'), @(2, 'B', '')) {
        $t = New-Pair $c[0] $true; $f = Join-Path $t.($c[1]) 'top.txt'
        [IO.File]::WriteAllText($f, 'geaendert'); [IO.File]::SetLastWriteTimeUtc($f, [datetime]'2026-02-01')
        $p = (Build-Plan $t).Plan
        if ($c[2]) { $q = Join-Path $t.($c[2]) 'top.txt'; $ok = ($p.Count -eq 1 -and $p[0].Typ -eq 'Copy' -and $p[0].Src -eq $q) } else { $ok = ($p.Count -eq 0) }
        Check "Modus $($c[0]): $($c[1]) neuer -> Quelle '$($c[2])'" $ok
    }
    $t = New-Pair 0 $true; Put "$($t.A)\x.tmp" 'x'; Put "$($t.A)\sub\Thumbs.db" 'x'; Put "$($t.B)\~`$a.docx" 'x'
    Check 'Ausschlussmuster: werden nicht angefasst' ((Build-Plan $t).Plan.Count -eq 0)

    # --- nicht lesbarer Unterordner
    foreach ($m in 0, 1, 2) { foreach ($side in 'A', 'B') {
        $t = New-Pair $m $true; $d = Join-Path $t.$side 'sub'; $other = if ($side -eq 'A') { $t.B } else { $t.A }
        Put (Join-Path $t.A 'neu.txt') 'neu'
        Set-Readable $d $false
        try {
            $bl = $false; try { [void][IO.Directory]::GetFileSystemEntries($d) } catch { $bl = $true }
            Check "Vorbedingung: $side\sub ist wirklich gesperrt" $bl
            $p = (Build-Plan $t).Plan
            Check "Modus $m, $side\sub gesperrt: keine Loeschung" ((Dels $p) -eq 0)
            Check "Modus $m, $side\sub gesperrt: darunter keine Aktion" (@($p | Where-Object { $_.Rel -like 'sub\*' }).Count -eq 0)
            Check "Modus $m, $side\sub gesperrt: Rest laeuft weiter" (@($p | Where-Object { $_.Rel -eq 'neu.txt' }).Count -eq 1)
            [void](Run-Task $t $false)
            Check "Modus $m, $side\sub gesperrt: Datei der anderen Seite noch da" ([IO.File]::Exists((Join-Path $other 'sub\tief\y.txt')))
            $s = Get-State $t.Id
            Check "Modus $m, $side\sub gesperrt: Stand bleibt" ($s.Contains('sub\x.txt') -and $s.Contains('sub\tief\y.txt') -and $s.Contains('sub\tief\'))
        } finally { Set-Readable $d $true }
        # danach wird eine echte Loeschung wieder erkannt
        if ($m -eq 0 -and $side -eq 'A') {
            [IO.File]::Delete("$($t.A)\sub\x.txt")
            Check 'Wieder lesbar: echte Loeschung wird erkannt' ((Dels (Build-Plan $t).Plan) -eq 1)
        }
    } }

    # --- nicht lesbarer Hauptordner
    foreach ($m in 0, 1, 2) { foreach ($side in 'A', 'B') {
        $t = New-Pair $m $true; Set-Readable $t.$side $false
        try { $thrown = $false; try { [void](Build-Plan $t) } catch { $thrown = $true }; Check "Modus ${m}: Hauptordner $side gesperrt -> Abbruch" $thrown }
        finally { Set-Readable $t.$side $true }
    } }

    # --- Loeschgrenze ($NoGui = wie Zeitplan: bricht ab)
    foreach ($c in @(0, 'A'), @(0, 'B'), @(1, 'A')) {
        $m = $c[0]; $side = $c[1]; $t = New-Pair $m $true; $root = $t.$side; $other = if ($side -eq 'A') { $t.B } else { $t.A }
        [IO.Directory]::Delete($root, $true); [void][IO.Directory]::CreateDirectory($root)
        $r = Run-Task $t $false
        Check "Modus ${m}: $side ploetzlich leer -> Abbruch" ($null -eq $r)
        Check "Modus ${m}: $side ploetzlich leer -> Dateien noch da" ([IO.File]::Exists("$other\top.txt") -and [IO.File]::Exists("$other\sub\tief\y.txt"))
        Check "Modus ${m}: $side ploetzlich leer -> Stand bleibt" ((Get-State $t.Id).Contains('top.txt'))
    }
    $t = New-Pair 1 $false; [IO.Directory]::Delete($t.A, $true); Put "$($t.A)\anders.txt" 'x'
    foreach ($i in 1..10) { Put "$($t.B)\b$i.txt" 'x' }
    Check 'Echo: falscher Ordner (ueber die Haelfte) -> Abbruch' ($null -eq (Run-Task $t $false))
    Check 'Echo: falscher Ordner -> nichts kopiert, nichts geloescht' ([IO.File]::Exists("$($t.B)\b1.txt") -and -not [IO.File]::Exists("$($t.B)\anders.txt"))
    $t = New-Pair 0 $true; foreach ($i in 1..8) { foreach ($r in $t.A, $t.B) { Put "$r\b$i.txt" 'x' } }
    Save-State $t.Id @(@(1..8 | ForEach-Object { "b$_.txt" }) + 'top.txt', 'sub\', 'sub\x.txt', 'sub\tief\', 'sub\tief\y.txt')
    foreach ($i in 1..5) { [IO.File]::Delete("$($t.A)\b$i.txt") }
    $r = Run-Task $t $false; Check 'Sync: 5 von 11 geloescht (unter der Grenze) -> laeuft' ($r.Deleted -eq 5 -and $r.Errors -eq 0)
    $t = New-Pair 0 $true; [IO.File]::Delete("$($t.A)\top.txt"); [IO.File]::Delete("$($t.A)\sub\x.txt")
    $r = Run-Task $t $false; Check 'Sync: 2 von 3 geloescht (wenige Dateien) -> laeuft' ($r.Deleted -eq 2)
    # 10 von 20: genau die Haelfte ist erlaubt, 11 von 20 nicht
    foreach ($c in @(10, $false), @(11, $true)) {
        $t = New-Pair 1 $false; foreach ($i in 1..17) { Put "$($t.B)\b$i.txt" 'x'; if ($i -gt $c[0]) { Put "$($t.A)\b$i.txt" 'x' } }
        Check "Echo: $($c[0]) von 20 -> Alarm $($c[1])" ([bool](Build-Plan $t).Mass -eq $c[1])
    }
    $t = New-Pair 0 $false; [IO.Directory]::Delete($t.B, $true); [void][IO.Directory]::CreateDirectory($t.B)
    $r = Run-Task $t $false; Check 'Erstsync in leeren Ordner -> laeuft' ($r.Copied -eq 3 -and $r.Deleted -eq 0)
    $t = New-Pair 1 $false; [IO.Directory]::Delete($t.B, $true); [void][IO.Directory]::CreateDirectory($t.B)
    $r = Run-Task $t $false; Check 'Echo in leeres B -> laeuft' ($r.Copied -eq 3)

    # --- Unterordner ist auf einer Seite eine Verknuepfung (Junction), wird nicht eingelesen
    foreach ($m in 0, 1) {
        $t = New-Pair $m $true; [IO.Directory]::Delete("$($t.A)\sub", $true)
        $ziel = Join-Path $base "$($script:nr)\ziel"; [void][IO.Directory]::CreateDirectory($ziel)
        [void](New-Item -ItemType Junction -Path "$($t.A)\sub" -Value $ziel)
        try { Check "Modus ${m}: Junction statt Ordner -> keine Loeschung" ((Dels (Build-Plan $t).Plan) -eq 0) }
        finally { [IO.Directory]::Delete("$($t.A)\sub") }
    }
} finally {
    try { [IO.Directory]::Delete($base, $true) } catch { Write-Host "Testordner nicht entfernt: $base" }
}
Write-Host "$($script:fails) Fehler"
exit $(if ($script:fails) { 1 } else { 0 })
