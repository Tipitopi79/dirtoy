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
