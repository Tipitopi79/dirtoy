# ---- Anzeige: zeichnet, was der Sync-Thread meldet (laeuft nur im Fenster-Thread)
function Out-Status([string]$text) { $script:lblStatus.Text = $text }
function Set-Progress([double]$frac) { $script:progFill.Width = (Get-BarWidth $script:progTrack.Width $frac) }
function Out-Row([string]$aktion, [string]$datei, [string]$status) {
    $it = New-Object System.Windows.Forms.ListViewItem($aktion)
    [void]$it.SubItems.Add($datei); [void]$it.SubItems.Add($status)
    $c = Get-StatusColor $status; if ($c) { $it.ForeColor = $c }
    [void]$script:lv.Items.Add($it)
    if (-not $script:bulk) { $it.EnsureVisible() }
    return $it
}
function Set-RowStatus($row, [string]$status) { $row.SubItems[2].Text = $status; $row.ForeColor = (Get-StatusColor $status) }
function Set-RowFile($row, [string]$path) { $row.Tag = $path }
function Start-Bulk { $script:lv.BeginUpdate() }
function Stop-Bulk { $script:lv.EndUpdate() }
function Limit-Rows([int]$max, [bool]$scroll) {
    $n = $script:lv.Items.Count
    if ($n -eq 0) { return }
    if ($n -gt $max) { $script:lv.BeginUpdate(); try { for ($k = $n - $max; $k -gt 0; $k--) { $script:lv.Items.RemoveAt(0) } } finally { $script:lv.EndUpdate() } }
    if ($scroll) { $script:lv.EnsureVisible($script:lv.Items.Count - 1) }
}
function Ask-User([string]$text, [string]$title, [bool]$defaultNo) {
    return ((Show-Msg $text $title 'YesNo' 'Warning' $(if ($defaultNo) { 'Button2' } else { 'Button1' })) -eq 'Yes')
}

