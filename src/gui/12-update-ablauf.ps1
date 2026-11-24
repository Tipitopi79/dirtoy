function Do-UpdateAction($info, [string]$action) {
    if ($action -eq 'web') { Start-Process $info.Url; return }
    if ($action -ne 'install') { return }
    if ($script:busy) { [void](Show-Msg 'Bitte erst den laufenden Vorgang beenden oder abbrechen.' 'DirToy' 'OK' 'Information'); return }
    $q = "DirToy $($info.Version) herunterladen und installieren?`n`nDie aktuelle Datei wird als DirToy.ps1.bak-$($script:version) gesichert. Danach startet DirToy neu."
    if ((Show-Msg $q 'DirToy - Update' 'YesNo' 'Question') -ne 'Yes') { return }
    try {
        $form.Cursor = 'WaitCursor'
        Install-Update $info $script:scriptPath ''
    } catch {
        $form.Cursor = 'Default'
        [void](Show-Msg "Das Update ist fehlgeschlagen. Die bisherige Version bleibt unverändert.`n`n$($_.Exception.Message)" 'DirToy - Update' 'OK' 'Error')
        return
    }
    $form.Cursor = 'Default'
    Save-Tasks
    Restart-DirToy

    $form.Close()
}
# Hintergrund-Pruefung: HttpClient-Task, ein Timer fragt das Ergebnis ab (Fenster bleibt bedienbar)
$script:updInfo = $null; $script:updTask = $null; $script:updManual = $false
function Start-UpdateCheck([bool]$manual) {
    if ($script:updTask -and -not $script:updTask.IsCompleted) { return }
    $script:updManual = $manual
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $c = New-Object System.Net.Http.HttpClient
        $c.Timeout = [TimeSpan]::FromSeconds(10)
        $c.DefaultRequestHeaders.UserAgent.ParseAdd('DirToy')
        $script:updTask = $c.GetStringAsync("https://api.github.com/repos/$($script:repo)/releases/latest")
        $script:updTimer.Start()
    } catch { $script:updTask = $null; if ($manual) { [void](Show-UpdateDialog $null 'error') } }
}
function Finish-UpdateCheck {
    $script:updTimer.Stop()
    $info = $null
    if ($script:updTask -and -not $script:updTask.IsFaulted -and -not $script:updTask.IsCanceled) { $info = Read-Release $script:updTask.Result }
    $script:updTask = $null
    $script:updInfo = $info
    $show = Test-NewerVersion $info
    $btnUpd.Visible = $show
    $lb.Height = $(if ($show) { 386 } else { 430 })
    if ($show) { $btnUpd.Text = "Update verfügbar: $($info.Version)" }
    if ($script:updManual) {
        $act = if ($show) { Show-UpdateDialog $info 'new' } elseif ($info) { Show-UpdateDialog $info 'current' } else { Show-UpdateDialog $null 'error' }
        Do-UpdateAction $info $act
    }
}
