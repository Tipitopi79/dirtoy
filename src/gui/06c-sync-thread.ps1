# ---- Sync im eigenen Thread. Der Kern fasst das Fenster nie an: Er legt Meldungen in $brg ab, ein Timer im
# Fenster-Thread holt sie ab. Zurueck geht nur: Abbruch ($brg.Cancel) und die Antwort auf eine Rueckfrage.
$script:workerFns = {
    function Out-Status([string]$text) { $brg.Status = $text }
    function Set-Progress([double]$frac) { $brg.Frac = $frac }
    function Out-Row([string]$aktion, [string]$datei, [string]$status) {
        $script:rowId++
        $brg.Q.Enqueue(@('row', $script:rowId, $aktion, $datei, $status, [bool]$script:bulk))
        return $script:rowId
    }
    function Set-RowStatus($row, [string]$status) { $brg.Q.Enqueue(@('status', $row, $status)) }
    function Set-RowFile($row, [string]$path) { $brg.Q.Enqueue(@('file', $row, $path)) }
    function Start-Bulk { }
    function Stop-Bulk { }
    function Limit-Rows([int]$max, [bool]$scroll) { $brg.Q.Enqueue(@('limit', $max, $scroll)) }
    function Test-Cancel { return $brg.Cancel }
    # Kommt das Fenster nicht nach, wartet der Sync kurz (sonst waechst die Warteschlange unbegrenzt)
    function Pump { while ($brg.Q.Count -gt 4000 -and -not $brg.Cancel) { [System.Threading.Thread]::Sleep(10) } }
    function Ask-User([string]$text, [string]$title, [bool]$defaultNo) {
        $brg.Answer = $false
        $brg.Ev.Reset()
        $brg.Ask = @($text, $title, $defaultNo)
        while (-not $brg.Ev.Wait(200)) { if ($brg.Cancel) { $brg.Ask = $null; return $false } }
        if ($brg.Answer -and -not $brg.Cancel) { return $true }
        $brg.Declined = $true
        return $false
    }
}
$script:workerRun = {
    $ErrorActionPreference = 'Stop'
    try {
        foreach ($job in $jobs) {
            $brg.Declined = $false
            $res = Run-Task $job $isPreview
            if (-not $isPreview) {
                $no = ([bool]$brg.Declined -or ($res -and $res.Cancelled))   # Rueckfrage verneint oder abgebrochen
                $bad = ($null -eq $res -and -not $no)
                if ($bad) { $brg.Failed = $true }
                if ($no) { $brg.Stopped = $true }
                $brg.Infos.Add(@([string]$job.Id, $bad, $(if ($res) { [int]$res.Errors } else { 0 }), $no))
            }
            if ($brg.Cancel) { break }
        }
    } catch { $brg.Error = [string]$_.Exception.Message; $brg.Stack = ($_ | Out-String) + $_.ScriptStackTrace }
}
$script:brg = $null
$script:job = $null
$script:rowMap = $null
$script:asking = $false

# Startet den Lauf; $doneText steht am Ende in der Statuszeile, $showResult: danach das Ergebnis-Fenster
function Start-SyncJob($tasks, [bool]$preview, [string]$doneText, [bool]$showResult) {
    $script:results.Clear()
    $script:lastFrac = -1.0; $script:lastStatus = ''
    $script:rowMap = New-Object 'System.Collections.Generic.Dictionary[int,object]'
    $script:brg = [hashtable]::Synchronized(@{
        Q = (New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'); Status = ''; Frac = 0.0; Cancel = $false
        Ask = $null; Answer = $false; Ev = (New-Object System.Threading.ManualResetEventSlim); Error = ''; Stack = ''; Failed = $false; Stopped = $false; Declined = $false; Infos = (New-Object System.Collections.Generic.List[object]) })
    $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    foreach ($f in $script:coreFns) { $iss.Commands.Add((New-Object System.Management.Automation.Runspaces.SessionStateFunctionEntry($f[0], $f[1]))) }
    $vars = @{ brg = $script:brg; NoGui = $false; headless = $false; cancel = $false; bulk = $false; inPlan = $false; scanCount = 0; tmpFiles = $null; copyBuf = $null; rowId = 0; logOn = $false
        version = $script:version; tmpSuffix = $script:tmpSuffix; pumpMs = $script:pumpMs; dataDir = $script:dataDir; stateDir = $script:stateDir; logFile = $script:logFile; errLog = $script:errLog
        warn = (New-Object System.Collections.Generic.List[string]); results = (New-Object System.Collections.Generic.List[object]) }
    foreach ($k in $vars.Keys) { $iss.Variables.Add((New-Object System.Management.Automation.Runspaces.SessionStateVariableEntry($k, $vars[$k], ''))) }
    # Momentaufnahme der Aufgaben: Aendern im Fenster wirkt erst beim naechsten Lauf
    $jobs = @(foreach ($t in $tasks) { $c = $t.PSObject.Copy(); $c.ExcludeDirs = [string[]]@($t.ExcludeDirs | Where-Object { $_ }); $c })
    $rs = [runspacefactory]::CreateRunspace($iss); $rs.ApartmentState = 'STA'; $rs.ThreadOptions = 'ReuseThread'; $rs.Open()
    $ps = [powershell]::Create(); $ps.Runspace = $rs
    # ein einziges Skript: AddStatement haengt sich in PowerShell 5.1 mit ReuseThread auf
    [void]$ps.AddScript("param(`$jobs, `$isPreview)`n" + $script:workerFns.ToString() + "`n" + $script:workerRun.ToString()).AddArgument($jobs).AddArgument($preview)
    $script:job = @{ Ps = $ps; Rs = $rs; H = $ps.BeginInvoke(); Results = $vars.results; Done = $doneText; Show = $showResult; Preview = $preview }
    $script:jobTimer.Start()
}
function Request-Cancel {
    $script:cancel = $true
    if ($script:brg) { $script:brg.Cancel = $true }
}
# Holt Meldungen ab, hoechstens $ms Millisekunden lang
function Receive-Rows([int]$ms) {
    $q = $script:brg.Q
    if ($q.Count -eq 0) { return }
    $sw = [System.Diagnostics.Stopwatch]::StartNew(); $m = $null; $scroll = $false
    while ($sw.ElapsedMilliseconds -lt $ms -and $q.TryDequeue([ref]$m)) {
        switch ($m[0]) {
            'row'    { $script:rowMap[$m[1]] = Out-Row $m[2] $m[3] $m[4]; if (-not $m[5]) { $scroll = $true } }
            'status' { Set-RowStatus $script:rowMap[$m[1]] $m[2] }
            'file'   { Set-RowFile $script:rowMap[$m[1]] $m[2] }
            'limit'  { Limit-Rows $m[1]; if ($m[2]) { $scroll = $true } }
        }
    }
    if ($scroll -and $script:rows.Count -gt 0) { $ui.lv.ScrollIntoView($script:rows[$script:rows.Count - 1]) }
}
function Update-Job {
    if (-not $script:job) { return }
    $b = $script:brg
    $finished = $script:job.H.IsCompleted   # vor dem Abholen pruefen: danach kommt nichts mehr dazu
    if ($b.Frac -ne $script:lastFrac) { $script:lastFrac = $b.Frac; Set-Progress $script:lastFrac }
    if ($b.Status -ne $script:lastStatus) { $script:lastStatus = $b.Status; Out-Status $script:lastStatus }
    Receive-Rows $(if ($finished) { 60 } else { 25 })
    if ($b.Ask -and -not $script:asking) {
        $script:asking = $true
        $a = $b.Ask
        try { $b.Answer = (Ask-User $a[0] $a[1] $a[2]) } catch { $b.Answer = $false } finally { $b.Ask = $null; $script:asking = $false; $b.Ev.Set() }
        return
    }
    if ($finished -and $b.Q.Count -eq 0 -and -not $script:asking) { Complete-Job }
}
function Complete-Job {
    $j = $script:job; $b = $script:brg
    $script:jobTimer.Stop()
    try { [void]$j.Ps.EndInvoke($j.H) } catch { if (-not $b.Error) { $b.Error = [string]$_.Exception.Message; $b.Stack = ($_ | Out-String) } }
    foreach ($r in $j.Results) { $script:results.Add($r) }
    $j.Ps.Dispose(); $j.Rs.Dispose(); $b.Ev.Dispose()
    $script:job = $null; $script:brg = $null; $script:rowMap = $null
    if ($b.Error) {
        try { Add-Content -Path $script:errLog -Value ("=== " + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + "`r`n" + $b.Stack) -Encoding UTF8 } catch { }
    }
    $was = $script:cancel
    Set-Busy $false
    $err = $false; foreach ($r in $j.Results) { if ($r.Errors -gt 0) { $err = $true } }
    $bad = ($b.Error -or $err -or $b.Failed)
    Stop-Flow $(if ($bad) { 'err' } elseif ($was -or $b.Stopped) { 'cancel' } elseif ($j.Preview) { '' } else { 'ok' })
    $ui.task.ProgressState = $(if ($bad) { 'Error' } else { 'None' })
    foreach ($x in $b.Infos) { Set-TaskInfo $x }
    $ui.lblStatus.Text = $(if ($b.Error) { 'Fehler, siehe fehler.log.' } elseif ($was) { 'Abgebrochen.' } else { $j.Done })
    if ($b.Error -and -not $script:closeRequested) { [void](Show-Msg "Der Lauf wurde durch einen Fehler beendet:`n`n$($b.Error)" 'DirToy' 'OK' 'Error') }
    if ($j.Show) { Show-ResultsIfNeeded }
}
$script:jobTimer = New-Object System.Windows.Threading.DispatcherTimer([System.Windows.Threading.DispatcherPriority]::Normal); $script:jobTimer.Interval = [TimeSpan]::FromMilliseconds(50)
$script:jobTimer.Add_Tick({ Update-Job })

