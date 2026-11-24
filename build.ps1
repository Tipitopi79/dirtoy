# Fuegt src\core\*.ps1 und src\gui\*.ps1 (nach Dateinamen sortiert) zu DirToy.ps1 zusammen.
#   build.ps1          schreibt DirToy.ps1 (UTF-8 mit BOM, CRLF)
#   build.ps1 -Check   schreibt nichts, prueft nur, ob DirToy.ps1 zum Stand in src passt (Exitcode 1 = nein)
param([switch]$Check)
$ErrorActionPreference = 'Stop'
function Read-Text([string]$path) { return [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8).Replace("`r`n", "`n") }
$sb = New-Object System.Text.StringBuilder
foreach ($ordner in 'core', 'gui') {
    $dir = [System.IO.Path]::Combine($PSScriptRoot, 'src', $ordner)
    $dateien = [string[]][System.IO.Directory]::GetFiles($dir, '*.ps1')
    if ($dateien.Length -eq 0) { throw "Keine Dateien in $dir" }
    [Array]::Sort($dateien, [StringComparer]::Ordinal)
    foreach ($f in $dateien) {
        $t = Read-Text $f
        $errs = $null; $toks = $null
        [void][System.Management.Automation.Language.Parser]::ParseInput($t, [ref]$toks, [ref]$errs)
        if ($errs -and $errs.Count -gt 0) { throw "${f}: $($errs[0].Message) (Zeile $($errs[0].Extent.StartLineNumber))" }
        if (-not $t.EndsWith("`n")) { $t += "`n" }
        [void]$sb.Append($t)
    }
}
$neu = $sb.ToString()
$ziel = [System.IO.Path]::Combine($PSScriptRoot, 'DirToy.ps1')
if ($Check) {
    if ((Read-Text $ziel) -cne $neu) { Write-Host 'DirToy.ps1 passt nicht zu src. Bitte build.ps1 ausfuehren.'; exit 1 }
    Write-Host 'DirToy.ps1 passt zu src.'; exit 0
}
[System.IO.File]::WriteAllText($ziel, $neu.Replace("`n", "`r`n"), (New-Object System.Text.UTF8Encoding($true)))
Write-Host "DirToy.ps1 gebaut ($($neu.Length) Zeichen)."
