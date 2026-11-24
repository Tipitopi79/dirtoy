# ---- Anzeige: zeichnet, was der Sync-Thread meldet (laeuft nur im Fenster-Thread)
function Out-Status([string]$text) { $ui.lblStatus.Text = $text }
function Set-Progress([double]$frac) {
    $ui.fill.Width = Get-BarWidth ([int]$ui.track.ActualWidth) $frac
    $ui.task.ProgressValue = [math]::Max(0.0, [math]::Min(1.0, $frac))
}
function Get-StatusBrush([string]$st) {
    if ($st -like 'FEHLER*') { return $script:br.Err }
    if ($st -eq 'OK') { return $script:br.Ok }
    return $script:br.Muted
}
function Out-Row([string]$aktion, [string]$datei, [string]$status) {
    $r = [DirToyRow]::new()
    $r.Aktion = $aktion; $r.Datei = $datei; $r.Status = $status; $r.StatusBrush = Get-StatusBrush $status
    $g = 0; $c = 'Accent'
    if ($aktion -like '*löschen*') { $g = 0xE74D; $c = 'Err' }
    elseif ($aktion -like 'Konflikt*' -or $aktion -eq 'Warnung') { $g = 0xE7BA; $c = 'Warn' }
    elseif ($aktion -like '*Ordner anlegen') { $g = 0xE8F4 }
    elseif ($aktion -like 'A -> B*') { $g = 0xE72A }
    elseif ($aktion -like 'B -> A*') { $g = 0xE72B }
    elseif ($aktion -like 'Aufgabe *') { $g = 0xE946; $c = 'Muted' }
    if ($g) { $r.Icon = [string][char]$g; $r.IconBrush = $script:br[$c] }
    $script:rows.Add($r)
    return $r
}
function Set-RowStatus($row, [string]$status) { $row.Status = $status; $row.StatusBrush = Get-StatusBrush $status }
function Set-RowFile($row, [string]$path) { $row.File = $path }
function Limit-Rows([int]$max) { for ($k = $script:rows.Count - $max; $k -gt 0; $k--) { $script:rows.RemoveAt(0) } }
function Ask-User([string]$text, [string]$title, [bool]$defaultNo) {
    return ((Show-Msg $text $title 'YesNo' 'Warning' $(if ($defaultNo) { 'Button2' } else { 'Button1' })) -eq 'Yes')
}
# Liste leeren und Sortierung zuruecksetzen (neue Zeilen kommen sonst an sortierter Stelle statt am Ende)
function Clear-Log { Set-ListSort '' $true; $script:rows.Clear(); $ui.empty.Visibility = 'Collapsed' }

