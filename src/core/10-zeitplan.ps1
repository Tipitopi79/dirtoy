# ---------------------------------------------------------------- Aufgabenplaner
$script:schedPath = '\DirToy\'
function Get-SchedText($s) {
    if (-not $s) { return 'Kein Zeitplan' }
    $dn = @{ Monday='Mo'; Tuesday='Di'; Wednesday='Mi'; Thursday='Do'; Friday='Fr'; Saturday='Sa'; Sunday='So' }
    $rep = if ([bool]$s.Repeat -and [int]$s.Type -le 1) { ", dann alle $($s.RepMinutes) Min. für $($s.RepHours) Std." } else { '' }
    switch ([int]$s.Type) {
        0 { "täglich um $($s.Time)$rep" }
        1 { 'wöchentlich ' + ((@($s.Days) | ForEach-Object { $dn[[string]$_] }) -join ',') + " um $($s.Time)$rep" }
        2 { "alle $($s.Minutes) Minuten" + $(if ([bool]$s.Start2) { " ab $($s.Time)" } else { '' }) }
        3 { 'bei Anmeldung' }
    }
}
# Autostart-Verknuepfung (Notloesung ohne Aufgabenplaner) entfernen
function Remove-AutoLnk($t) {
    if ($t.AutoLnk) { Remove-Item -LiteralPath ([string]$t.AutoLnk) -Force -ErrorAction SilentlyContinue }
    $t.AutoLnk = ''
}
# Liest die Aufgabe nach dem Anlegen zurueck und prueft sie; liefert $null (alles in Ordnung) oder einen Fehlertext
function Test-SchedRegistered([string]$name, [string]$id, [bool]$rep) {
    try { $st = Get-ScheduledTask -TaskPath $script:schedPath -TaskName $name -ErrorAction Stop }
    catch { return 'Die Aufgabe ist nach dem Anlegen im Windows-Aufgabenplaner nicht zu finden.' }
    $a = @($st.Actions)
    if ($a.Count -eq 0 -or ([string]$a[0].Arguments) -notlike "*$id*") { return 'Die angelegte Aufgabe enthält nicht den erwarteten Startbefehl.' }
    $tr = @($st.Triggers)
    if ($tr.Count -eq 0) { return 'Die angelegte Aufgabe hat keinen Auslöser (Zeitpunkt).' }
    if ($rep -and -not [string]$tr[0].Repetition.Interval) { return 'Die Wiederholung wurde nicht übernommen.' }
    return $null
}
function Get-SchedInfo($t) {
    if (-not $t.SchedName) { return $null }
    try {
        $st = Get-ScheduledTask -TaskPath $script:schedPath -TaskName $t.SchedName -ErrorAction Stop
        $i = $st | Get-ScheduledTaskInfo
        return [pscustomobject]@{ State = $st.State; Next = $i.NextRunTime; Last = $i.LastRunTime; Result = $i.LastTaskResult }
    } catch { return $null }
}
function Unregister-Sched($t) {
    if ($t.SchedName) {
        Unregister-ScheduledTask -TaskPath $script:schedPath -TaskName $t.SchedName -Confirm:$false -ErrorAction SilentlyContinue
    }
    $t.SchedName = ''
    Remove-AutoLnk $t
}
# Legt den Zeitplan $s fuer die Aufgabe an, liest ihn zurueck und prueft ihn. Bei Fehlern wird eine Ausnahme geworfen
# und die Aufgabe ($t) bleibt unveraendert; nur bei Erfolg werden Schedule/SchedName gesetzt.
function Register-Sched($t, $s) {
    $name = 'DirToy - ' + (([string]$t.Name -replace '[\\/:*?"<>|]', '_').Trim())
    $user = "$env:USERDOMAIN\$env:USERNAME"
    $arg = "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$($script:scriptPath)`" -Task `"$($t.Id)`""
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arg
    $hm = ([string]$s.Time).Split(':')
    $at = [datetime]::Today.AddHours([int]$hm[0]).AddMinutes([int]$hm[1])
    $rep = ([bool]$s.Repeat -and [int]$s.Type -le 1)
    switch ([int]$s.Type) {
        0 { $trg = New-ScheduledTaskTrigger -Daily -At $at }
        1 { $trg = New-ScheduledTaskTrigger -Weekly -DaysOfWeek ([string[]]@($s.Days)) -At $at }
        2 { $at2 = if ([bool]$s.Start2) { $at } else { (Get-Date).AddMinutes(1) }
            $trg = New-ScheduledTaskTrigger -Once -At $at2 -RepetitionInterval (New-TimeSpan -Minutes ([int]$s.Minutes)) -RepetitionDuration (New-TimeSpan -Days 3650) }
        3 { $trg = New-ScheduledTaskTrigger -AtLogOn -User $user }
    }
    if ($rep) {
        # Tages-/Wochen-Trigger kennt in PowerShell 5.1 keine Wiederholung: sie wird von einem Einmal-Trigger uebernommen
        $r = New-ScheduledTaskTrigger -Once -At $at -RepetitionInterval (New-TimeSpan -Minutes ([int]$s.RepMinutes)) -RepetitionDuration (New-TimeSpan -Hours ([int]$s.RepHours))
        $trg.Repetition = $r.Repetition
    }
    # Wiederholungen/Intervalle werden nicht nachgeholt; Zeitplaene mit fester Uhrzeit und Anmeldung schon
    $noCatchUp = ($rep -or [int]$s.Type -eq 2)
    $sp = @{ AllowStartIfOnBatteries = $true; DontStopIfGoingOnBatteries = $true; MultipleInstances = 'IgnoreNew'; ExecutionTimeLimit = (New-TimeSpan -Hours 12) }
    if (-not $noCatchUp) { $sp.StartWhenAvailable = $true }
    $set = New-ScheduledTaskSettingsSet @sp
    $pri = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
    [void](Register-ScheduledTask -TaskName $name -TaskPath $script:schedPath -Action $action -Trigger $trg -Settings $set -Principal $pri -Description "DirToy: $($t.Name)" -Force -ErrorAction Stop)
    $bad = Test-SchedRegistered $name ([string]$t.Id) $rep
    if ($bad) {
        Unregister-ScheduledTask -TaskPath $script:schedPath -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue
        throw $bad
    }
    if ($t.SchedName -and $t.SchedName -ne $name) {
        Unregister-ScheduledTask -TaskPath $script:schedPath -TaskName $t.SchedName -Confirm:$false -ErrorAction SilentlyContinue
    }
    $t.SchedName = $name
    $t.Schedule = $s
    Remove-AutoLnk $t
}
# Fertiger schtasks-Befehl (fuer die Eingabeaufforderung) zum manuellen Anlegen
function Get-SchtasksCommand($t, $s) {
    $name = 'DirToy - ' + (([string]$t.Name -replace '[\\/:*?"<>|]', '_').Trim())
    $tr = "powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File \`"$($script:scriptPath)\`" -Task $($t.Id)"
    $c = "schtasks /Create /TN `"$name`" /TR `"$tr`" /F"
    $dm = @{ Monday='MON'; Tuesday='TUE'; Wednesday='WED'; Thursday='THU'; Friday='FRI'; Saturday='SAT'; Sunday='SUN' }
    switch ([int]$s.Type) {
        0 { $c += " /SC DAILY /ST $($s.Time)" }
        1 { $c += " /SC WEEKLY /D " + ((@($s.Days) | ForEach-Object { $dm[[string]$_] }) -join ',') + " /ST $($s.Time)" }
        2 { $c += " /SC MINUTE /MO $([int]$s.Minutes)" + $(if ([bool]$s.Start2) { " /ST $($s.Time)" } else { '' }) }
        3 { $c += ' /SC ONLOGON' }
    }
    if ([bool]$s.Repeat -and [int]$s.Type -le 1) { $c += " /RI $([int]$s.RepMinutes) /DU {0:00}:00" -f [int]$s.RepHours }
    return $c
}
