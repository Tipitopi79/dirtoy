# Loeschen darf nie ein Windows-Fenster zeigen (das haelt den Lauf an, bei Zeitplaenen unbemerkt).
# Jeder Fall laeuft in einem eigenen Prozess mit Zeitlimit: haengt er, stand dort ein Fenster.
# Start: powershell -NoProfile -ExecutionPolicy Bypass -File tests\test-loeschen.ps1   (anderes Programm: DIRTOY_TEST_PS1)
param([string]$Fall, [string]$Ordner)
$prog = if ($env:DIRTOY_TEST_PS1) { $env:DIRTOY_TEST_PS1 } else { Join-Path (Split-Path $PSScriptRoot) 'DirToy.ps1' }

if ($Fall) {
    # ---- Kindprozess: ein Fall
    $env:DIRTOY_DATA = Join-Path $Ordner 'daten'
    [void](New-Item -ItemType Directory -Force -Path $env:DIRTOY_DATA)
    . $prog -NoGui
    function Put([string]$p) { [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($p)); [IO.File]::WriteAllText($p, 'x'); [IO.File]::SetLastWriteTimeUtc($p, [datetime]'2026-01-01') }
    $t = New-Task 'Loeschtest'; $t.A = Join-Path $Ordner 'A'; $t.B = Join-Path $Ordner 'B'; $t.Mode = 0
    $keys = @()
    foreach ($i in 1..10) { foreach ($r in $t.A, $t.B) { Put "$r\d$i.txt" }; $keys += "d$i.txt" }
    Save-State $t.Id $keys
    switch ($Fall) {
        'gesperrt' {
            foreach ($i in 1..3) { [IO.File]::Delete("$($t.A)\d$i.txt") }
            $lock = [IO.File]::Open("$($t.B)\d2.txt", 'Open', 'Read', 'None')
            try { $r = Run-Task $t $false } finally { $lock.Dispose() }
            "ERG1 $($r.Deleted) $($r.Errors) $([IO.File]::Exists("$($t.B)\d2.txt")) $([IO.File]::Exists("$($t.B)\d1.txt")) $((Get-State $t.Id).Contains('d2.txt')) $((Get-State $t.Id).Contains('d1.txt'))"
            "LOG $(([IO.File]::ReadAllText($script:logFile) -split "`n" | Where-Object { $_ -match 'd2\.txt' -and $_ -match 'FEHLER' }).Count)"
            $r = Run-Task $t $false
            "ERG2 $($r.Deleted) $($r.Errors) $([IO.File]::Exists("$($t.B)\d2.txt"))"
        }
        'verweigert' {
            # Windows verweigert das Loeschen (Rechte): die Shell zeigt sonst "Wiederholen / Abbrechen"
            [IO.File]::Delete("$($t.A)\d2.txt")
            $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
            $f = "$($t.B)\d2.txt"; $acl = [IO.File]::GetAccessControl($f)
            $fr = New-Object Security.AccessControl.FileSystemAccessRule($sid, 'Delete', 'Deny'); $acl.AddAccessRule($fr); [IO.File]::SetAccessControl($f, $acl)
            $dacl = [IO.Directory]::GetAccessControl($t.B)
            $dr = New-Object Security.AccessControl.FileSystemAccessRule($sid, 'DeleteSubdirectoriesAndFiles', 'Deny'); $dacl.AddAccessRule($dr); [IO.Directory]::SetAccessControl($t.B, $dacl)
            try { $r = Run-Task $t $false }
            finally { [void]$dacl.RemoveAccessRule($dr); [IO.Directory]::SetAccessControl($t.B, $dacl); $acl = [IO.File]::GetAccessControl($f); [void]$acl.RemoveAccessRule($fr); [IO.File]::SetAccessControl($f, $acl) }
            "VERW $($r.Deleted) $($r.Errors) $([IO.File]::Exists($f)) $((Get-State $t.Id).Contains('d2.txt'))"
        }
        'papierkorb' {
            $name = 'dirtoy-papierkorb-' + [guid]::NewGuid().ToString('N') + '.txt'
            Put "$($t.B)\$name"; [IO.File]::SetAttributes("$($t.B)\$name", 'ReadOnly')
            Delete-One "$($t.B)\$name"
            $sh = New-Object -ComObject Shell.Application
            $im = @($sh.Namespace(10).Items() | Where-Object { $_.Name -eq $name -or $_.Name -eq [IO.Path]::GetFileNameWithoutExtension($name) })
            "PK $([IO.File]::Exists("$($t.B)\$name")) $($im.Count)"
            foreach ($x in $im) { try { Remove-Item -LiteralPath $x.Path -Force } catch { } }   # Testdatei wieder aus dem Papierkorb
        }
        'fehlt' {
            $e = ''; try { Delete-One "$($t.B)\gibtsnicht.txt" } catch { $e = $_.Exception.Message }
            "FEHLT $([bool]$e)"
            # Windows-Fehlerfenster abgeschaltet (FOF_NOERRORUI), Papierkorb an (FOF_ALLOWUNDO)
            $fl = [int]([regex]::Match((Get-Item function:Delete-One).ScriptBlock.Ast.Extent.Text, 'flags = (0x[0-9A-Fa-f]+)').Groups[1].Value)
            "FLAGS $((($fl -band 0x400) -ne 0) -and (($fl -band 0x40) -ne 0) -and (($fl -band 0x10) -ne 0) -and (($fl -band 0x4) -ne 0))"
        }
        'thread' {
            # wie der Lauf aus dem Fenster: eigener Thread, nur die Funktionen, keine Skript-Variablen
            $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
            $iss.Commands.Add((New-Object System.Management.Automation.Runspaces.SessionStateFunctionEntry('Delete-One', (Get-Item function:Delete-One).Definition)))
            $rs = [runspacefactory]::CreateRunspace($iss); $rs.ApartmentState = 'STA'; $rs.Open()
            $f1 = "$($t.B)\d1.txt"; $f2 = "$($t.B)\d2.txt"
            $lock = [IO.File]::Open($f2, 'Open', 'Read', 'None')
            try {
                $ps = [powershell]::Create(); $ps.Runspace = $rs
                [void]$ps.AddScript('param($a, $b) $ErrorActionPreference = "Stop"; Delete-One $a; try { Delete-One $b; "B ok" } catch { "B FEHLER " + $_.Exception.Message }').AddArgument($f1).AddArgument($f2)
                $o = $ps.Invoke()
                "THREAD $([IO.File]::Exists($f1)) $([IO.File]::Exists($f2)) $($o -join ' / ')"
            } finally { $lock.Dispose(); $rs.Dispose() }
        }
    }
    exit 0
}

# ---- Steuerung
$script:fails = 0
function Check([string]$name, [bool]$cond, $info = '') {
    if ($cond) { Write-Host "ok      $name" } else { $script:fails++; Write-Host "FEHLER  $name  $info" }
}
function Run-Fall([string]$fall) {
    $d = Join-Path ([IO.Path]::GetTempPath()) ('dirtoy-loeschen-' + [guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Force -Path $d)
    $out = Join-Path $d 'aus.txt'
    $p = Start-Process powershell -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', "`"$PSCommandPath`"", '-Fall', $fall, '-Ordner', "`"$d`"") -RedirectStandardOutput $out -PassThru -WindowStyle Hidden
    $fertig = $p.WaitForExit(30000)
    if (-not $fertig) { & taskkill /PID $p.Id /T /F | Out-Null; Start-Sleep 1 }
    $txt = if (Test-Path $out) { [IO.File]::ReadAllText($out) } else { '' }
    try { [IO.Directory]::Delete($d, $true) } catch { }
    return @{ Fertig = $fertig; Text = $txt }
}

$r = Run-Fall 'gesperrt'
Check 'gesperrte Datei: Lauf endet ohne Windows-Fenster' $r.Fertig
$z = ($r.Text -split "`r?`n" | Where-Object { $_ -like 'ERG1 *' }) -split ' '
Check 'gesperrte Datei: andere Loeschungen erledigt, 1 Fehler' ($z[1] -eq '2' -and $z[2] -eq '1') $z
Check 'gesperrte Datei: bleibt erhalten, andere weg' ($z[3] -eq 'True' -and $z[4] -eq 'False') $z
Check 'gesperrte Datei: bleibt im Stand, erledigte nicht' ($z[5] -eq 'True' -and $z[6] -eq 'False') $z
Check 'gesperrte Datei: Fehler steht im Protokoll' (($r.Text -split "`r?`n") -contains 'LOG 1') $r.Text
$z = ($r.Text -split "`r?`n" | Where-Object { $_ -like 'ERG2 *' }) -split ' '
Check 'naechster Lauf loescht sie ohne Fehler' ($z[1] -eq '1' -and $z[2] -eq '0' -and $z[3] -eq 'False') $z

$r = Run-Fall 'verweigert'
Check 'Loeschen verweigert: Lauf endet ohne Windows-Fenster' $r.Fertig
Check 'Loeschen verweigert: 1 Fehler, Datei und Stand bleiben' ($r.Text -match 'VERW 0 1 True True') $r.Text

$r = Run-Fall 'papierkorb'
Check 'Papierkorb: Lauf endet' $r.Fertig
Check 'schreibgeschuetzte Datei landet im Papierkorb' ($r.Text -match 'PK False 1') $r.Text

$r = Run-Fall 'fehlt'
Check 'fehlende Datei: Fehler statt Fenster' ($r.Fertig -and $r.Text -match 'FEHLT True') $r.Text
Check 'Windows-Fehlerfenster beim Loeschen abgeschaltet, Papierkorb an' ($r.Text -match 'FLAGS True') $r.Text

$r = Run-Fall 'thread'
Check 'eigener Thread (Lauf aus dem Fenster): kein Windows-Fenster' $r.Fertig
Check 'eigener Thread: loescht, gesperrte Datei wird Fehler' ($r.Text -match 'THREAD False True B FEHLER .*0x20') $r.Text

if ($script:fails) { Write-Host "$($script:fails) FEHLER" } else { Write-Host 'ALLES OK' }
exit $(if ($script:fails) { 1 } else { 0 })
