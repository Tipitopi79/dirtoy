# ---------------------------------------------------------------- Zustand (zum Erkennen von Löschungen)
function Get-State([string]$id) {
    $set = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    # Neues Format: eine Zeile pro Eintrag (schnell, auch bei hunderttausenden Dateien)
    $f = Join-Path $script:stateDir "$id.state"
    if (Test-Path $f) {
        foreach ($line in [System.IO.File]::ReadLines($f, [System.Text.Encoding]::UTF8)) { if ($line) { [void]$set.Add($line) } }
    } else {
        # altes JSON-Format (nur kleine Staende)
        $fj = Join-Path $script:stateDir "$id.json"
        if (Test-Path $fj) {
            try {
                $raw = Get-Content $fj -Raw -Encoding UTF8
                if ($raw -and $raw.Trim()) { $items = ConvertFrom-Json $raw; foreach ($p in $items) { [void]$set.Add([string]$p) } }
            } catch { }
        }
    }
    return ,$set
}
function Save-State([string]$id, $keys) {
    $f = Join-Path $script:stateDir "$id.state"
    $tmp = $f + '.tmp'
    [System.IO.File]::WriteAllLines($tmp, [string[]]@($keys), (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -Path $tmp -Destination $f -Force
    Remove-Item (Join-Path $script:stateDir "$id.json") -ErrorAction SilentlyContinue
}

