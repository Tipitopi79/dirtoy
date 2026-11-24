# Startet DirToy neu (Design-Wechsel, Update); der Aufrufer schliesst danach das Fenster
function Restart-DirToy {
    $c = Get-LaunchCommand
    Start-Process -FilePath $c.File -ArgumentList $c.Args
}
# Startbefehl ohne aufblitzendes Konsolenfenster: conhost.exe --headless (Windows 10 ab 2004 / 11), sonst PowerShell direkt
function Get-LaunchCommand {
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $psArgs = "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$($script:scriptPath)`""
    $ch = Join-Path $env:SystemRoot 'System32\conhost.exe'
    if ((Test-Path $ch) -and [Environment]::OSVersion.Version.Build -ge 19041) {
        return @{ File = $ch; Args = "--headless `"$ps`" $psArgs" }
    }
    return @{ File = $ps; Args = $psArgs }
}
# Legt eine Verknuepfung auf dem Desktop an (startet DirToy ohne Konsolenfenster-Dauerzustand)
function Get-DesktopDir { if ($env:DIRTOY_DESKTOP) { return $env:DIRTOY_DESKTOP } else { return [Environment]::GetFolderPath('Desktop') } }
function New-DesktopShortcut {
    try {
        $dir = Split-Path $script:scriptPath
        $lnk = Join-Path (Get-DesktopDir) 'DirToy.lnk'
        $ws = New-Object -ComObject WScript.Shell
        $sc = $ws.CreateShortcut($lnk)
        $c = Get-LaunchCommand
        $sc.TargetPath = $c.File
        $sc.Arguments = $c.Args
        $sc.WorkingDirectory = $dir
        $sc.WindowStyle = 7
        $sc.Description = 'DirToy - Ordner synchron halten'
        $ico = Join-Path $dir 'DirToy.ico'
        if (Test-Path $ico) { $sc.IconLocation = $ico }
        $sc.Save()
        return $lnk
    } catch { return $null }
}
# Notloesung ohne Aufgabenplaner: Verknuepfung im Autostart-Ordner startet die Aufgabe bei jeder Anmeldung
function New-AutostartLink($t) {
    try {
        $dir = if ($env:DIRTOY_STARTUP) { $env:DIRTOY_STARTUP } else { [Environment]::GetFolderPath('Startup') }
        $lnk = Join-Path $dir (('DirToy - ' + ([string]$t.Name -replace '[\\/:*?"<>|]', '_').Trim()) + '.lnk')
        $ws = New-Object -ComObject WScript.Shell
        $sc = $ws.CreateShortcut($lnk)
        $c = Get-LaunchCommand
        $sc.TargetPath = $c.File
        $sc.Arguments = $c.Args + " -Task `"$($t.Id)`""
        $sc.WorkingDirectory = Split-Path $script:scriptPath
        $sc.WindowStyle = 7
        $sc.Description = "DirToy: $($t.Name)"
        $sc.Save()
        $t.AutoLnk = $lnk
        return $lnk
    } catch { return $null }
}
