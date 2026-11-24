# ---------------------------------------------------------------- Log-Ausgabe
function Write-LogLine([string]$aktion, [string]$datei, [string]$status) {
    try { [System.IO.File]::AppendAllText($script:logFile, ((Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' | ' + $aktion + ' | ' + $datei + ' | ' + $status + "`r`n"), [System.Text.Encoding]::UTF8) } catch { }
}
function Set-Progress([double]$frac) {
    if (-not $script:progFill) { return }
    $w = [int]($script:progTrack.Width * [math]::Max(0.0, [math]::Min(1.0, $frac)))
    $script:progFill.Width = $w
}
function Add-Log([string]$aktion, [string]$datei, [string]$status) {
    if ($script:logOn -and $status -ne '...') { Write-LogLine $aktion $datei $status }
    if ($script:lv) {
        $it = New-Object System.Windows.Forms.ListViewItem($aktion)
        [void]$it.SubItems.Add($datei); [void]$it.SubItems.Add($status)
        $c = Get-StatusColor $status; if ($c) { $it.ForeColor = $c }
        [void]$script:lv.Items.Add($it)
        if (-not $script:bulk) { $it.EnsureVisible() }
        return $it
    } else {
        Write-Host "$aktion | $datei | $status"
        return $null
    }
}
function Pump { if (-not $NoGui) { [System.Windows.Forms.Application]::DoEvents() } }

