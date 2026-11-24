# Test der Update-Signatur mit einem Wegwerf-Schluessel im Temp-Ordner (nie der echte Schluessel).
#   powershell -File tests\test-signatur.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'src\core\15-signatur.ps1')
. (Join-Path $root 'tools\signierung.ps1')

$fail = 0
function Check([string]$name, [bool]$cond) {
    if ($cond) { Write-Host "OK   $name" } else { Write-Host "FEHL $name"; $script:fail++ }
}

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('dirtoy-sigtest-' + [guid]::NewGuid().ToString('N'))
try {
    $pass = ConvertTo-SecureString 'wegwerf-passphrase-test' -AsPlainText -Force
    $pfx = Join-Path $tmp 'test.pfx'
    $script:signingCert = New-SigningKey $pfx $pass
    Check 'PFX wurde angelegt' (Test-Path $pfx)

    $enc = New-Object System.Text.UTF8Encoding($false)
    $data = $enc.GetBytes("`$script:version = '9.9.9'`r`nWrite-Host 'hallo'`r`n")
    $sig = New-UpdateSignature $data $pfx $pass
    Check 'gueltige Signatur wird erkannt' (Test-UpdateSignature $data $sig)

    $lf = $enc.GetBytes("`$script:version = '9.9.9'`nWrite-Host 'hallo'`n")
    Check 'CRLF/LF-Unterschied ist egal' (Test-UpdateSignature $lf $sig)

    $evil = $enc.GetBytes("`$script:version = '9.9.9'`r`nWrite-Host 'boese'`r`n")
    Check 'geaenderte Datei wird abgelehnt' (-not (Test-UpdateSignature $evil $sig))
    Check 'leere Signatur wird abgelehnt' (-not (Test-UpdateSignature $data ''))
    Check 'Muell als Signatur wird abgelehnt' (-not (Test-UpdateSignature $data 'kein-base64!!'))
    Check 'abgeschnittene Signatur wird abgelehnt' (-not (Test-UpdateSignature $data $sig.Substring(0, 100)))

    # Signatur eines fremden Schluessels (Angreifer mit eigenem Paar)
    $pfx2 = Join-Path $tmp 'fremd.pfx'
    [void](New-SigningKey $pfx2 $pass)
    $fremd = New-UpdateSignature $data $pfx2 $pass
    Check 'Signatur eines fremden Schluessels wird abgelehnt' (-not (Test-UpdateSignature $data $fremd))

    $falsch = ConvertTo-SecureString 'falsche-passphrase!' -AsPlainText -Force
    $threw = $false
    try { [void](New-UpdateSignature $data $pfx $falsch) } catch { $threw = $true }
    Check 'falsche Passphrase kann nicht signieren' $threw

    $script:signingCert = ''
    $threw = $false
    try { [void](Test-UpdateSignature $data $sig) } catch { $threw = $true }
    Check 'ohne eingebauten Schluessel wird nie akzeptiert' $threw
} finally {
    if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
}
if ($fail -gt 0) { Write-Host "$fail Fehler"; exit 1 }
Write-Host 'Alle Signatur-Tests bestanden.'
