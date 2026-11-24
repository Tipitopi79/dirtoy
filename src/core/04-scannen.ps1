# ---------------------------------------------------------------- Scannen
function New-Dict { New-Object 'System.Collections.Generic.Dictionary[string,System.IO.FileInfo]' ([StringComparer]::OrdinalIgnoreCase) }
function Test-Excluded([string]$name, $pats) {
    foreach ($p in $pats) { if ($name -like $p) { return $true } }
    return $false
}
function New-DirSet { New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase) }
function Scan-Dir([System.IO.DirectoryInfo]$dir, [string]$rel, $pats, $dict, $dirs) {
    try { $entries = $dir.GetFileSystemInfos() }
    catch {
        # Nicht lesbar heisst nicht "leer": sonst wuerde der Inhalt auf der anderen Seite geloescht
        if ($rel -eq '') { throw "Ordner nicht lesbar, es wurde nichts verändert: $($dir.FullName) ($($_.Exception.Message))" }
        [void]$script:unread.Add($rel)
        $script:warn.Add("$($dir.FullName): nicht lesbar, auf beiden Seiten wird hier nichts verändert ($($_.Exception.Message))"); return
    }
    foreach ($e in $entries) {
        $script:scanCount++
        if (($script:scanCount % 300) -eq 0) {
            if ($script:lblStatus) { $script:lblStatus.Text = "Lese Ordner ein ... ($($script:scanCount) Einträge)" }
            Pump
            if ($script:cancel -and $script:inPlan) { throw 'DIRTOY_CANCEL' }
        }
        if ($e -isnot [System.IO.DirectoryInfo] -and $e.Name.EndsWith($script:tmpSuffix, [StringComparison]::OrdinalIgnoreCase)) {
            if ($null -ne $script:tmpFiles) { $script:tmpFiles.Add($e.FullName) }
            continue
        }
        if (Test-Excluded $e.Name $pats) { continue }
        if ($e -is [System.IO.DirectoryInfo]) {
            if ($e.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { [void]$script:unread.Add($rel + $e.Name + '\'); continue }   # Verknuepfung: nicht eingelesen, also auch nichts ableiten
            if ($script:exDirs -and $script:exDirs.Contains($rel + $e.Name + '\')) { continue }   # im Ordnerbaum abgewaehlt
            if ($dirs) { [void]$dirs.Add($rel + $e.Name + '\') }
            Scan-Dir $e ($rel + $e.Name + '\') $pats $dict $dirs
        } else {
            $dict[$rel + $e.Name] = $e
        }
    }
}
# Liegt der Eintrag in (oder ist er selbst) ein Ordner, der auf einer Seite nicht eingelesen werden konnte?
function Test-Unread([string]$rel, $unread) {
    foreach ($u in $unread) { if ($rel.StartsWith($u, [StringComparison]::OrdinalIgnoreCase)) { return $true } }
    return $false
}
function Get-ExcludeDirs($t) {
    $set = New-DirSet
    foreach ($x in @($t.ExcludeDirs)) { if ($x) { [void]$set.Add(([string]$x).TrimEnd('\') + '\') } }
    return ,$set
}
function Get-Patterns($t) { @(([string]$t.Exclude) -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }

