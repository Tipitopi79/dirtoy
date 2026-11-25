# Antwort von GET /releases/latest -> @{ Version; Tag; Url; Notes } oder $null (kein gueltiger Release)
function Read-Release([string]$json) {
    try {
        $j = ConvertFrom-Json $json
        $tag = [string]$j.tag_name
        if ($tag -notmatch '^v?(\d+\.\d+\.\d+)$') { return $null }
        $url = [string]$j.html_url
        if ($url -notlike "https://github.com/$($script:repo)/*") { $url = "https://github.com/$($script:repo)/releases/tag/$tag" }
        return [pscustomobject]@{ Version = [version]$Matches[1]; Tag = $tag; Url = $url; Notes = [string]$j.body }
    } catch { return $null }
}
function Test-NewerVersion($info) { return ($null -ne $info -and $info.Version -gt [version]$script:version) }
# Laedt DirToy.ps1 des Release-Tags, prueft sie und ersetzt die laufende Datei (Sicherung bleibt als .bak-<alte Version>)
function Install-Update($info, [string]$target, [string]$sourceUrl) {
    if ($info.Tag -notmatch '^v?\d+\.\d+\.\d+$') { throw 'Ungültiger Versions-Tag.' }
    if (-not $sourceUrl) { $sourceUrl = "https://raw.githubusercontent.com/$($script:repo)/$($info.Tag)/DirToy.ps1" }
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $wc = New-Object System.Net.WebClient
    $wc.Headers['User-Agent'] = 'DirToy'
    try {
        $bytes = $wc.DownloadData($sourceUrl)
        try { $sig = [System.Text.Encoding]::ASCII.GetString($wc.DownloadData($sourceUrl + '.sig')) }
        catch { throw "Die Signatur des Updates konnte nicht geladen werden. $($_.Exception.Message)" }
    } finally { $wc.Dispose() }
    if ($bytes.Length -lt 50KB) { throw 'Die heruntergeladene Datei ist zu klein.' }
    # Nichts wird gespeichert, bevor die Signatur mit dem eingebauten Schluessel stimmt
    if (-not (Test-UpdateSignature $bytes $sig)) { throw 'Die Signatur des Updates ist ungültig. Die Datei stammt nicht vom Entwickler oder wurde verändert.' }
    $neu = $target + '.neu'
    [System.IO.File]::WriteAllBytes($neu, $bytes)
    try {
        $errs = $null; $toks = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($neu, [ref]$toks, [ref]$errs)
        if ($errs -and $errs.Count -gt 0) { throw 'Die heruntergeladene Datei ist kein gültiges Skript.' }
        $txt = [System.Text.Encoding]::UTF8.GetString($bytes)
        if ($txt -notmatch "\`$script:version\s*=\s*'$([regex]::Escape([string]$info.Version))'") { throw "Die Datei enthält nicht die Version $($info.Version)." }
        $bak = $target + '.bak-' + $script:version
        Copy-Item $target $bak -Force
        Move-Item $neu $target -Force
    } finally { if (Test-Path $neu) { Remove-Item $neu -Force -ErrorAction SilentlyContinue } }
}
