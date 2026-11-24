# ---------------------------------------------------------------- Aufgaben speichern/laden
function Load-Tasks {
    $script:tasks = @()
    if (Test-Path $script:taskFile) {
        $raw = Get-Content $script:taskFile -Raw -Encoding UTF8
        try { if ($raw -and $raw.Trim()) { [void](ConvertFrom-Json $raw) } }
        catch {
            Copy-Item $script:taskFile ($script:taskFile + ".defekt-" + (Get-Date -Format yyyyMMdd-HHmmss)) -Force
            $raw = $null
        }
        if ($raw -and $raw.Trim()) { $items = ConvertFrom-Json $raw; $script:tasks = @(foreach ($it in $items) { $it })
        foreach ($t in $script:tasks) {
            foreach ($pn in @('Schedule', 'SchedName', 'AutoLnk')) {
                if (-not $t.PSObject.Properties[$pn]) { Add-Member -InputObject $t -NotePropertyName $pn -NotePropertyValue $(if ($pn -ne 'Schedule') { '' } else { $null }) }
            }
            if (-not $t.PSObject.Properties['ExcludeDirs']) { Add-Member -InputObject $t -NotePropertyName 'ExcludeDirs' -NotePropertyValue ([string[]]@()) }
        } }
    }
}
function Save-Tasks {
    $json = ConvertTo-Json -InputObject @($script:tasks) -Depth 4
    $tmp = $script:taskFile + ".tmp"
    Set-Content -Path $tmp -Value $json -Encoding UTF8
    Move-Item -Path $tmp -Destination $script:taskFile -Force
}
function New-Task([string]$name) {
    [pscustomobject]@{ Id = [guid]::NewGuid().ToString('N'); Name = $name; A = ''; B = ''; Mode = 0; Exclude = 'Thumbs.db;desktop.ini;~$*;*.tmp'; ExcludeDirs = [string[]]@(); Schedule = $null; SchedName = ''; AutoLnk = '' }
}

