param([switch]$NoGui, [string]$Task, [switch]$All)
# DirToy - grafisches Ordner-Synchronisationstool (Vorbild: SyncToy)
# Start: DirToy.cmd (Doppelklick)

Add-Type -AssemblyName System.Windows.Forms, System.Drawing, Microsoft.VisualBasic, System.Net.Http
[System.Windows.Forms.Application]::EnableVisualStyles()
$ErrorActionPreference = 'Stop'

$script:errLog = Join-Path $PSScriptRoot 'DirToy-Daten\fehler.log'
# Logdatei ueber 2 MB -> wird zu <name>.alt (aelteres .alt wird ersetzt)
function Limit-Log([string]$path) {
    try { if ((Test-Path $path) -and (Get-Item $path).Length -gt 2MB) { Move-Item $path ($path + '.alt') -Force } } catch { }
}
trap {
    try {
        Limit-Log $script:errLog
        New-Item -ItemType Directory -Force -Path (Split-Path $script:errLog) | Out-Null
        Add-Content -Path $script:errLog -Value ("=== " + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + "`r`n" + ($_ | Out-String) + ($_.ScriptStackTrace)) -Encoding UTF8
    } catch { }
    if (-not $NoGui -and -not $Task -and -not $All) {
        [void][System.Windows.Forms.MessageBox]::Show("DirToy konnte nicht starten oder ist abgestürzt:`n`n$($_.Exception.Message)`n`nDetails stehen in:`n$($script:errLog)", 'DirToy', 'OK', 'Error')
    }
    exit 1
}
$script:version = '2.0.0'
$script:bulk = $false
$script:tmpSuffix = '.dirtoy-tmp'
$script:pumpMs = 150
$script:cancel = $false
$script:inPlan = $false
$script:scanCount = 0
$script:tmpFiles = $null
$script:copyBuf = $null
# Datenordner: DirToy-Daten neben dem Programm; ist dort nicht schreibbar (z. B. C:\Program Files ohne Admin-Rechte),
# dann %APPDATA%\DirToy. Beim ersten Wechsel werden Aufgaben, Einstellungen und Zustand aus dem alten Ordner uebernommen.
function Test-DirWritable([string]$dir) {
    try {
        if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Force -Path $dir) }
        $f = Join-Path $dir ('.schreibtest-' + [guid]::NewGuid().ToString('N'))
        [System.IO.File]::WriteAllText($f, 'x'); [System.IO.File]::Delete($f)
        return $true
    } catch { return $false }
}
$script:localData = Join-Path $PSScriptRoot 'DirToy-Daten'
$script:dataFallback = $false
if ($env:DIRTOY_DATA) { $script:dataDir = $env:DIRTOY_DATA }
else {
    # Migration: Datenordner frueherer Namen -> DirToy-Daten
    try {
        if (-not (Test-Path $script:localData)) {
            foreach ($o in @('TwinSync-Daten', 'SyncTool-Daten')) {
                $old = Join-Path $PSScriptRoot $o
                if (Test-Path $old) { Rename-Item -Path $old -NewName 'DirToy-Daten'; break }
            }
        }
    } catch { }
    if (Test-DirWritable $script:localData) { $script:dataDir = $script:localData }
    else {
        $script:dataFallback = $true
        $script:dataDir = Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'DirToy'
        try {
            if (-not (Test-Path (Join-Path $script:dataDir 'aufgaben.json')) -and (Test-Path -LiteralPath $script:localData)) {
                [void](New-Item -ItemType Directory -Force -Path $script:dataDir)
                foreach ($n in 'aufgaben.json', 'einstellungen.json') {
                    $src = Join-Path $script:localData $n
                    if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src -Destination $script:dataDir -Force }
                }
                $sd = Join-Path $script:localData 'state'
                if (Test-Path -LiteralPath $sd) { Copy-Item -LiteralPath $sd -Destination $script:dataDir -Recurse -Force }
            }
        } catch { }
    }
}
$script:errLog = Join-Path $script:dataDir 'fehler.log'
$script:stateDir = Join-Path $script:dataDir 'state'
$script:taskFile = Join-Path $script:dataDir 'aufgaben.json'
New-Item -ItemType Directory -Force -Path $script:stateDir | Out-Null
$script:logFile = Join-Path $script:dataDir 'sync.log'
$script:logOn = $false
Limit-Log $script:logFile
Limit-Log $script:errLog

$script:modes = @(
    'Synchronisieren  (A <-> B, neuere Datei gewinnt, Löschungen werden übernommen)',
    'Echo  (A -> B, B wird exakt wie A gemacht)',
    'Beitragen  (A -> B, es wird nichts gelöscht)'
)
$script:warn = New-Object System.Collections.Generic.List[string]
$script:results = New-Object System.Collections.Generic.List[object]   # Ergebnisse der Laeufe fuers Ergebnis-Fenster
$script:tasks = @()
$script:cur = $null
$script:loading = $false
$script:scriptPath = $PSCommandPath

