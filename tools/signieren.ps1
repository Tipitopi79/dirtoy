# Signiert DirToy.ps1 mit dem privaten Schluessel (von Hand im eigenen Terminal ausfuehren, nicht durch Claude).
# Ablauf pro Release: build.ps1 -> signieren.ps1 -> DirToy.ps1 und DirToy.ps1.sig committen -> Tag v... pushen.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'src\core\15-signatur.ps1')
. (Join-Path $root 'src\core\16-signierschluessel.ps1')
. (Join-Path $PSScriptRoot 'signierung.ps1')

$pfx = Join-Path $env:USERPROFILE '.dirtoy-signing\dirtoy-signing.pfx'
if (-not (Test-Path -LiteralPath $pfx)) { throw "Schluessel nicht gefunden: $pfx" }

& (Join-Path $root 'build.ps1') -Check
if ($LASTEXITCODE -ne 0) { throw 'DirToy.ps1 passt nicht zu src. Erst build.ps1 ausfuehren.' }

$datei = Join-Path $root 'DirToy.ps1'
$bytes = [System.IO.File]::ReadAllBytes($datei)
$sig = New-UpdateSignature $bytes $pfx (Read-Passphrase 'Passphrase')

# Gegenprobe mit dem eingebauten oeffentlichen Schluessel: faengt falsche PFX-Datei und kaputte Signatur ab
if (-not (Test-UpdateSignature $bytes $sig)) { throw 'Die Signatur passt nicht zum eingebauten Schluessel. Nichts geschrieben.' }
[System.IO.File]::WriteAllText("$datei.sig", $sig + "`n", (New-Object System.Text.UTF8Encoding($false)))
Write-Host "Signiert: $datei.sig"
