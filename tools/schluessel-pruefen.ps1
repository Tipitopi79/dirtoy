# Prueft, ob PFX-Datei, Passphrase und eingebauter oeffentlicher Schluessel zusammenpassen (von Hand im eigenen Terminal ausfuehren).
# Schreibt nichts, signiert nur ein paar Testbytes im Speicher.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'src\core\15-signatur.ps1')
. (Join-Path $root 'src\core\16-signierschluessel.ps1')
. (Join-Path $PSScriptRoot 'signierung.ps1')

$pfx = Join-Path $env:USERPROFILE '.dirtoy-signing\dirtoy-signing.pfx'
if (-not (Test-Path -LiteralPath $pfx)) { throw "Schluessel nicht gefunden: $pfx" }
$cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 (,[Convert]::FromBase64String($script:signingCert))
Write-Host "Eingebauter Schluessel: $($cert.Subject), gueltig bis $($cert.NotAfter.ToString('yyyy-MM-dd'))"
Write-Host "Fingerabdruck (SHA-256): $([BitConverter]::ToString((New-Object System.Security.Cryptography.SHA256Managed).ComputeHash($cert.RawData)).Replace('-', ''))"

$test = [System.Text.Encoding]::UTF8.GetBytes('DirToy Schluesseltest')
try { $sig = New-UpdateSignature $test $pfx (Read-Passphrase 'Passphrase') }
catch { Write-Host 'FEHLER: PFX-Datei konnte nicht geoeffnet werden. Passphrase falsch?'; exit 1 }
if (Test-UpdateSignature $test $sig) { Write-Host 'OK: Passphrase stimmt und der Schluessel passt zum eingebauten oeffentlichen Teil.' }
else { Write-Host 'FEHLER: Die Signatur passt nicht zum eingebauten oeffentlichen Schluessel.'; exit 1 }
