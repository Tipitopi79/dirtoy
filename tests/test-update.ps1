# Test von Install-Update mit Wegwerf-Schluessel und lokalen Dateien (file://). Arbeitet nur in einem eigenen Temp-Ordner.
# Start: powershell -NoProfile -ExecutionPolicy Bypass -STA -File tests\test-update.ps1   (anderes Programm: DIRTOY_TEST_PS1)
$base = Join-Path ([IO.Path]::GetTempPath()) ('dirtoy-upd-' + [guid]::NewGuid().ToString('N'))
$env:DIRTOY_DATA = Join-Path $base 'daten'
[void](New-Item -ItemType Directory -Force -Path $env:DIRTOY_DATA)
$prog = if ($env:DIRTOY_TEST_PS1) { $env:DIRTOY_TEST_PS1 } else { Join-Path (Split-Path $PSScriptRoot) 'DirToy.ps1' }
. $prog -NoGui
. (Join-Path (Split-Path $PSScriptRoot) 'tools\signierung.ps1')
$script:fails = 0
function Check([string]$name, [bool]$cond) { if ($cond) { Write-Host "ok      $name" } else { $script:fails++; Write-Host "FEHLER  $name" } }
$enc = New-Object Text.UTF8Encoding($true)
try {
    # eingebauter Schluessel: RSA 3072, kein privater Teil
    $c = New-Object Security.Cryptography.X509Certificates.X509Certificate2 (,[Convert]::FromBase64String($script:signingCert))
    Check 'eingebauter Schluessel: 3072 Bit, nur oeffentlich' ($c.PublicKey.Key.KeySize -eq 3072 -and -not $c.HasPrivateKey)
    $pass = ConvertTo-SecureString 'wegwerf-passphrase-test' -AsPlainText -Force
    $echt = Join-Path $base 'echt.pfx'; $fremd = Join-Path $base 'fremd.pfx'
    $script:signingCert = New-SigningKey $echt $pass; [void](New-SigningKey $fremd $pass)
    $quelle = [IO.File]::ReadAllText($prog, [Text.Encoding]::UTF8).Replace("`r`n", "`n")
    $gut = $enc.GetPreamble() + $enc.GetBytes($quelle.Replace("`$script:version = '$($script:version)'", "`$script:version = '99.0.0'"))
    $info = [pscustomobject]@{ Version = [version]'99.0.0'; Tag = 'v99.0.0' }
    $ziel = Join-Path $base 'Programm.ps1'; $dl = Join-Path $base 'DirToy.ps1'; $url = ([uri]$dl).AbsoluteUri
    # Legt Download und Signatur hin, installiert; liefert Fehlertext ('' = installiert)
    function Try-Install([byte[]]$datei, $sig) {
        [IO.File]::WriteAllText($ziel, 'alte Datei'); [IO.File]::WriteAllBytes($dl, $datei)
        if (Test-Path "$dl.sig") { [IO.File]::Delete("$dl.sig") }
        if ($null -ne $sig) { [IO.File]::WriteAllText("$dl.sig", $sig) }
        try { Install-Update $info $ziel $url; return '' } catch { return [string]$_.Exception.Message }
    }
    function Check-Nein([string]$name, [byte[]]$datei, $sig, [string]$grund) {
        $m = Try-Install $datei $sig
        Check "$name ($m)" ($m -like "*$grund*" -and [IO.File]::ReadAllText($ziel) -eq 'alte Datei' -and -not (Test-Path "$ziel.neu") -and -not (Test-Path "$ziel.bak-*"))
    }
    $sig = New-UpdateSignature $gut $echt $pass
    $boese = [byte[]]$gut.Clone(); $boese[60000] = $boese[60000] -bxor 1
    Check-Nein 'ohne Signatur abgelehnt' $gut $null 'konnte nicht geladen'
    Check-Nein 'leere Signatur abgelehnt' $gut '' 'Signatur des Updates ist ung?ltig'
    Check-Nein 'Muell als Signatur abgelehnt' $gut 'kein-base64!!' 'Signatur des Updates ist ung?ltig'
    Check-Nein 'ein Bit veraendert abgelehnt' $boese $sig 'Signatur des Updates ist ung?ltig'
    Check-Nein 'angehaengte Zeile abgelehnt' ([byte[]]($gut + [byte[]][char[]]"`nWrite-Host 1")) $sig 'Signatur des Updates ist ung?ltig'
    Check-Nein 'fremder Schluessel abgelehnt' $gut (New-UpdateSignature $gut $fremd $pass) 'Signatur des Updates ist ung?ltig'
    $alt = $enc.GetPreamble() + $enc.GetBytes($quelle)
    Check-Nein 'echte, aber andere Version abgelehnt' $alt (New-UpdateSignature $alt $echt $pass) 'nicht die Version'
    $kaputt = [byte[]]($gut + [byte[]][char[]]"`nfunction {{{")
    Check-Nein 'signiert, aber kein gueltiges Skript' $kaputt (New-UpdateSignature $kaputt $echt $pass) 'kein g?ltiges Skript'
    $k = $script:signingCert; $script:signingCert = ''; Check-Nein 'ohne eingebauten Schluessel abgelehnt' $gut $sig 'kein Signaturschluessel'; $script:signingCert = $k
    $m = Try-Install $gut $sig
    Check "gueltiges Update wird installiert $m" ($m -eq '' -and [Convert]::ToBase64String([IO.File]::ReadAllBytes($ziel)) -eq [Convert]::ToBase64String($gut))
    Check 'alte Datei gesichert' ([IO.File]::ReadAllText("$ziel.bak-$($script:version)") -eq 'alte Datei')
    # GitHub liefert LF, signiert wird die CRLF-Datei
    $crlf = $enc.GetPreamble() + $enc.GetBytes($enc.GetString($gut, 3, $gut.Length - 3).Replace("`n", "`r`n"))
    $m = Try-Install $gut (New-UpdateSignature $crlf $echt $pass); Check "CRLF signiert, LF geliefert $m" ($m -eq '')
} finally { if (Test-Path $base) { [IO.Directory]::Delete($base, $true) } }
if ($script:fails -gt 0) { Write-Host "$($script:fails) FEHLER"; exit 1 }
Write-Host 'ALLES OK'; exit 0
