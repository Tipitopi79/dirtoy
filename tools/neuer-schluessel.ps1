# Einmalig ausfuehren (von Hand im eigenen Terminal, nicht durch Claude): erzeugt den Signaturschluessel fuer DirToy-Updates.
#   - privater Schluessel: %USERPROFILE%\.dirtoy-signing\dirtoy-signing.pfx (passphrase-geschuetzt, ausserhalb des Repos)
#   - oeffentlicher Teil:  src\core\16-signierschluessel.ps1 (wird eingebaut und darf ins Repo)
# Danach: PFX-Datei und Passphrase in Bitwarden sichern (Anhang + Passwort-Eintrag).
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'src\core\15-signatur.ps1')
. (Join-Path $PSScriptRoot 'signierung.ps1')

$pfx = Join-Path $env:USERPROFILE '.dirtoy-signing\dirtoy-signing.pfx'
$ziel = Join-Path $root 'src\core\16-signierschluessel.ps1'
if (Test-Path -LiteralPath $pfx) { throw "Es gibt schon einen Schluessel: $pfx`nNichts geaendert." }
if (Test-Path -LiteralPath $ziel) { throw "$ziel gibt es schon. Nichts geaendert." }

$p1 = Read-Passphrase 'Neue Passphrase (mind. 12 Zeichen)'
$p2 = Read-Passphrase 'Passphrase wiederholen'
$a = ConvertTo-PlainText $p1
if ($a -ne (ConvertTo-PlainText $p2)) { throw 'Die Passphrasen sind verschieden.' }
if ($a.Length -lt 12) { throw 'Die Passphrase ist zu kurz (mind. 12 Zeichen).' }
$a = $null

$pub = New-SigningKey $pfx $p1
$text = "# Oeffentlicher Schluessel zur Pruefung der Update-Signatur (erzeugt von tools\neuer-schluessel.ps1). Nicht von Hand aendern.`n`$script:signingCert = '$pub'`n"
[System.IO.File]::WriteAllText($ziel, $text, (New-Object System.Text.UTF8Encoding($true)))

$cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 (,[Convert]::FromBase64String($pub))
Write-Host "Schluessel gespeichert: $pfx"
Write-Host "Oeffentlicher Teil:     $ziel"
Write-Host "Fingerabdruck (SHA-256): $([BitConverter]::ToString((New-Object System.Security.Cryptography.SHA256Managed).ComputeHash($cert.RawData)).Replace('-', ''))"
Write-Host ''
Write-Host 'Jetzt in Bitwarden sichern: die PFX-Datei (als Anhang) und die Passphrase. Dann build.ps1 ausfuehren.'
