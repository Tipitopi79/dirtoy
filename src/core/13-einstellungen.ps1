# ---------------------------------------------------------------- Einstellungen + Update-Pruefung (GitHub)
$script:settingsFile = Join-Path $script:dataDir 'einstellungen.json'
$script:repo = 'Tipitopi79/dirtoy'
function Get-Setting([string]$name, $default) {
    try {
        if (Test-Path $script:settingsFile) {
            $s = Get-Content $script:settingsFile -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($s.PSObject.Properties[$name] -and $null -ne $s.$name) { return $s.$name }
        }
    } catch { }
    return $default
}
function Set-Setting([string]$name, $value) {
    try {
        $h = [ordered]@{}
        if (Test-Path $script:settingsFile) {
            $s = Get-Content $script:settingsFile -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($p in $s.PSObject.Properties) { $h[$p.Name] = $p.Value }
        }
        $h[$name] = $value
        Set-Content -Path $script:settingsFile -Value (ConvertTo-Json -InputObject $h) -Encoding UTF8
    } catch { }
}
