if ($Task -or $All) {
    # Headless-Modus fuer den Windows-Aufgabenplaner
    $NoGui = $true
    $script:headless = $true
    $script:logOn = $true
    Load-Tasks
    $sel = @($script:tasks | Where-Object { $All -or $_.Name -ieq $Task -or $_.Id -eq $Task })
    if ($sel.Count -eq 0) { [void](Add-Log 'FEHLER' '' "Aufgabe nicht gefunden: $Task"); exit 2 }
    $bad = 0; $msgs = New-Object System.Collections.Generic.List[string]
    foreach ($t in $sel) {
        $r = Run-Task $t $false
        $nm = if ($t.Schedule -and $null -ne $t.Schedule.Notify) { [int]$t.Schedule.Notify } else { 1 }
        if ($null -eq $r) { $bad++; if ($nm -ge 1) { $msgs.Add("$($t.Name): FEHLER (siehe Protokoll)") } }
        elseif ($r.Errors -gt 0) { $bad++; if ($nm -ge 1) { $msgs.Add("$($t.Name): $($r.Errors) Fehler, $($r.Copied) kopiert, $($r.Deleted) gelöscht") } }
        elseif ($nm -eq 1 -and ($r.Copied + $r.Deleted) -gt 0) { $msgs.Add("$($t.Name): $($r.Copied) kopiert, $($r.Deleted) gelöscht") }
    }
    if ($msgs.Count -gt 0) { Send-Notify $(if ($bad) { 'DirToy - Fehler' } else { 'DirToy - fertig' }) ($msgs -join "`n") ([bool]$bad) }
    exit $(if ($bad) { 1 } else { 0 })
}
