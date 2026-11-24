# ---------------------------------------------------------------- Log-Ausgabe
function Write-LogLine([string]$aktion, [string]$datei, [string]$status) {
    try { [System.IO.File]::AppendAllText($script:logFile, ((Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' | ' + $aktion + ' | ' + $datei + ' | ' + $status + "`r`n"), [System.Text.Encoding]::UTF8) } catch { }
}
function Add-Log([string]$aktion, [string]$datei, [string]$status) {
    if ($script:logOn -and $status -ne '...') { Write-LogLine $aktion $datei $status }
    return (Out-Row $aktion $datei $status)
}

# ---- Meldestellen: Nur hierueber spricht der Kern mit der Aussenwelt. Das hier ist die Fassung ohne Fenster;
# gui\06c-sync-thread.ps1 ersetzt diese Funktionen im Sync-Thread durch die Fassung mit Fenster.
function Out-Status([string]$text) { }                                # Statuszeile
function Set-Progress([double]$frac) { }                              # Fortschritt 0..1
function Out-Row([string]$aktion, [string]$datei, [string]$status) {  # neue Zeile; Rueckgabe: Zeile oder $null
    Write-Host "$aktion | $datei | $status"
    return $null
}
function Set-RowStatus($row, [string]$status) { }                     # Status einer Zeile aendern
function Set-RowFile($row, [string]$path) { }                         # Datei, die ein Doppelklick auf die Zeile oeffnet
function Start-Bulk { }                                               # viele Zeilen am Stueck: Anfang ...
function Stop-Bulk { }                                                # ... und Ende
function Limit-Rows([int]$max, [bool]$scroll) { }                     # hoechstens $max Zeilen behalten, aelteste zuerst weg
function Test-Cancel { return $script:cancel }                         # Abbruch gewuenscht?
function Pump { }                                                     # Oberflaeche zwischendurch bedienen
function Ask-User([string]$text, [string]$title, [bool]$defaultNo) { return $false }   # Rueckfrage; ohne Fenster immer Nein
# Breite des Fortschrittsbalkens (0.0/1.0: mit 0/1 rundet PowerShell auf ganze Zahlen)
function Get-BarWidth([int]$width, [double]$frac) { return [int]($width * [math]::Max(0.0, [math]::Min(1.0, $frac))) }

