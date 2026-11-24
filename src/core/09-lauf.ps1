function Run-Task($t, [bool]$preview) {
    $script:warn.Clear()
    $script:logOn = (-not $preview)
    if (-not $preview) { Limit-Log $script:logFile; Write-LogLine ("=== Aufgabe '" + $t.Name + "' (" + $(if ($script:headless) { 'automatisch' } else { 'manuell' }) + ', DirToy ' + $script:version + ')') '' '' }
    Set-Progress 0
    if ($script:lblStatus) { $script:lblStatus.Text = "Analysiere '$($t.Name)' ..." }
    Pump
    try { $r = Build-Plan $t }
    catch {
        if ($_.Exception.Message -eq 'DIRTOY_CANCEL') { [void](Add-Log "Aufgabe '$($t.Name)'" 'Abgebrochen (nichts wurde verändert).' ''); return @{ Copied = 0; Deleted = 0; Errors = 0; Cancelled = $true } }
        [void](Add-Log "Aufgabe '$($t.Name)'" '' "FEHLER: $($_.Exception.Message)"); return $null
    }
    foreach ($w in $script:warn) { [void](Add-Log 'Warnung' $w 'übersprungen') }
    if (-not $preview) {
        # liegengebliebene Zwischendateien frueherer, abgebrochener Laeufe aufraeumen
        foreach ($tf in @($script:tmpFiles)) {
            try {
                $fi = Get-Item -LiteralPath $tf -Force
                if (((Get-Date) - $fi.LastWriteTime).TotalMinutes -gt 5) { Remove-Item -LiteralPath $tf -Force; [void](Add-Log 'Aufgeräumt' $tf 'Zwischendatei gelöscht') }
            } catch { }
        }
    }
    $plan = $r.Plan
    $dels = @($plan | Where-Object { $_.Typ -eq 'Delete' -or $_.Typ -eq 'RmDir' }).Count
    if ($plan.Count -eq 0) { if (-not $preview) { try { Save-RunState $t $r $null } catch { } }; [void](Add-Log "Aufgabe '$($t.Name)'" 'Bereits synchron - nichts zu tun.' ''); return @{ Copied = 0; Deleted = 0; Errors = 0 } }

    $uiMax = 2000   # mehr Zeilen machen die Liste langsam; vollstaendig steht alles im Protokoll
    if ($preview) {
        if ($r.Mass) { [void](Add-Log 'Warnung' "Auffällig viele Löschungen: $($r.Mass)" 'bitte prüfen') }
        $script:bulk = $true
        if ($script:lv) { $script:lv.BeginUpdate() }
        try {
            $n = 0
            foreach ($p in $plan) { $n++; if ($n -gt $uiMax) { break }; [void](Add-Log $p.Text $p.Rel 'geplant') }
        } finally { $script:bulk = $false; if ($script:lv) { $script:lv.EndUpdate() } }
        if ($plan.Count -gt $uiMax) {
            $pf = Write-PreviewFile $t $plan
            $cnt = [ordered]@{}; foreach ($p in $plan) { if ($cnt.Contains($p.Text)) { $cnt[$p.Text]++ } else { $cnt[$p.Text] = 1 } }
            foreach ($k in $cnt.Keys) { [void](Add-Log "Insgesamt: $k" ('{0:N0} Aktion(en)' -f $cnt[$k]) '') }
            $it = Add-Log "... und $($plan.Count - $uiMax) weitere Aktionen" $(if ($pf) { '(Doppelklick: komplette Liste als CSV öffnen)' } else { "(Anzeige auf die ersten $uiMax begrenzt)" }) ''
            if ($it -and $pf) { $it.Tag = $pf }
        }
        [void](Add-Log "Aufgabe '$($t.Name)'" "Vorschau: $($plan.Count) Aktion(en), davon $dels Löschung(en)" '')
        return $null
    }
    if ($r.Mass -and $NoGui) {
        # Zeitplan: niemand kann nachfragen, also nichts veraendern
        [void](Add-Log "Aufgabe '$($t.Name)'" "Abgebrochen, nichts wurde verändert. $($r.Mass) Wenn das gewollt ist, die Aufgabe einmal von Hand starten." 'FEHLER: Auffällig viele Löschungen')
        return $null
    }
    if ($r.Mass) {
        $ans = (Show-Msg "Aufgabe '$($t.Name)': Auffällig viele Löschungen!`n`n$($r.Mass)`n`nIst das richtige Laufwerk verbunden und der richtige Ordner gewählt?`nTrotzdem löschen? (Papierkorb, sofern möglich)" 'Auffällig viele Löschungen' 'YesNo' 'Warning' 'Button2')
        if ($ans -ne 'Yes') { [void](Add-Log "Aufgabe '$($t.Name)'" '' 'Abgebrochen.'); return $null }
    }
    elseif ($dels -gt 0 -and -not $NoGui) {
        $ans = (Show-Msg "Aufgabe '$($t.Name)': $dels Datei(en)/Ordner werden gelöscht (Papierkorb, sofern möglich).`nFortfahren?" 'Löschen bestätigen' 'YesNo' 'Warning')
        if ($ans -ne 'Yes') { [void](Add-Log "Aufgabe '$($t.Name)'" '' 'Abgebrochen.'); return $null }
    }
    $copied = 0; $deleted = 0; $errors = 0; $i = 0; $cancelled = $false; $lastPump = [Environment]::TickCount - 1000
    $errList = New-Object System.Collections.Generic.List[string]; $script:bulk = $true
    $resItems = New-Object System.Collections.Generic.List[object]; $sum = [ordered]@{}; $bytes = [long]0; $skipped = 0; $t0 = Get-Date
    $ok = New-Object bool[] $plan.Count   # welche Aktionen erfolgreich waren (fuer den Zustand)
    foreach ($p in $plan) {
        if ($script:cancel) { $cancelled = $true; break }
        $i++
        if (([Environment]::TickCount - $lastPump) -gt 100) {
            $lastPump = [Environment]::TickCount
            if ($script:lblStatus) { $script:lblStatus.Text = "'$($t.Name)': $i / $($plan.Count)  ($([int](100 * $i / $plan.Count)) %)" }
            Set-Progress ($i / $plan.Count)
            if ($script:lv -and $script:lv.Items.Count -gt 0) {
                # Laufendes Fenster: aelteste Zeilen fliegen raus, es bleiben die letzten $uiMax (alles steht im Protokoll)
                $ex = $script:lv.Items.Count - $uiMax
                if ($ex -gt 0) { $script:lv.BeginUpdate(); try { for ($k = 0; $k -lt $ex; $k++) { $script:lv.Items.RemoveAt(0) } } finally { $script:lv.EndUpdate() } }
                $script:lv.EnsureVisible($script:lv.Items.Count - 1)
            }
            Pump
        }
        $it = $null
        $it = Add-Log $p.Text $p.Rel '...'
        try {
            $st = 'OK'
            switch ($p.Typ) {
                'Copy'     { $len = 0; try { $len = (New-Object System.IO.FileInfo $p.Src).Length } catch { }; Copy-One $p.Src $p.Dst; $copied++; $bytes += $len }
                'Delete'   { Delete-One $p.Src; $deleted++ }
                'MkDir'    { [void][System.IO.Directory]::CreateDirectory($p.Dst); $copied++ }
                'RmDir'    {
                    if (-not (Test-Path -LiteralPath $p.Src -PathType Container)) { $st = 'OK' }
                    else {
                        $en = [System.IO.Directory]::EnumerateFileSystemEntries($p.Src).GetEnumerator()
                        $hasAny = $en.MoveNext(); $en.Dispose()
                        if ($hasAny) { $st = 'übersprungen (nicht leer)' }
                        else { [System.IO.Directory]::Delete($p.Src); $deleted++ }
                    }
                }
                'Conflict' { $st = 'übersprungen' }
            }
            if ($script:logOn) { Write-LogLine $p.Text $p.Rel $st }
            if ($st -eq 'OK') { $ok[$i - 1] = $true }
            if ($st -eq 'OK') { if ($sum.Contains($p.Text)) { $sum[$p.Text]++ } else { $sum[$p.Text] = 1 } } elseif ($st -like 'übersprungen*') { $skipped++ }
            if (-not $script:headless) { $resItems.Add(@($p.Text, $p.Rel, $st)) }
            if ($it) { $it.SubItems[2].Text = $st; $it.ForeColor = (Get-StatusColor $st) }
        } catch {
            if ($_.Exception.Message -eq 'DIRTOY_CANCEL') {
                $cancelled = $true
                if ($script:logOn) { Write-LogLine $p.Text $p.Rel 'abgebrochen (Zieldatei unverändert)' }
                if (-not $script:headless) { $resItems.Add(@($p.Text, $p.Rel, 'abgebrochen')) }
                if ($it) { $it.SubItems[2].Text = 'abgebrochen'; $it.ForeColor = (Get-StatusColor 'abgebrochen') }
                break
            }
            $errors++
            $emsg = 'FEHLER: ' + $_.Exception.Message
            if ($errList.Count -lt 50) { $errList.Add($p.Text + ' | ' + $p.Rel + ' | ' + $emsg) }
            if (-not $script:headless) { $resItems.Add(@($p.Text, $p.Rel, $emsg)) }
            if ($it) {
                if ($script:logOn) { Write-LogLine $p.Text $p.Rel $emsg }
                $it.SubItems[2].Text = $emsg; $it.ForeColor = (Get-StatusColor 'FEHLER')
            } else { [void](Add-Log $p.Text $p.Rel $emsg) }   # Fehler immer anzeigen (Add-Log schreibt auch ins Protokoll)
        }
    }
    $script:bulk = $false
    $script:results.Add([pscustomobject]@{ Name = [string]$t.Name; Items = $resItems; Sum = $sum; Copied = $copied; Deleted = $deleted; Errors = $errors; Skipped = $skipped; Bytes = $bytes; Seconds = ((Get-Date) - $t0).TotalSeconds; Cancelled = $cancelled })
    if ($plan.Count -gt $uiMax) {
        if ($script:lv) { $script:lv.BeginUpdate(); try { while ($script:lv.Items.Count -gt $uiMax) { $script:lv.Items.RemoveAt(0) } } finally { $script:lv.EndUpdate() } }
        [void](Add-Log "Anzeige zeigt nur die letzten $uiMax Aktionen" 'Alle Aktionen stehen im Protokoll (sync.log)' '')
        if ($errList.Count -gt 0) { [void](Add-Log "Fehler dieses Laufs ($errors, höchstens 50 hier gelistet)" '' ''); foreach ($e in $errList) { [void](Add-Log $e '' '') } }
    }
    try { Save-RunState $t $r $ok } catch { [void](Add-Log 'Warnung' 'Zustand konnte nicht gespeichert werden' $_.Exception.Message) }
    if ($cancelled) {
        [void](Add-Log "Aufgabe '$($t.Name)' abgebrochen" "$copied kopiert, $deleted gelöscht, $errors Fehler - Lauf unvollständig, keine halben Dateien" '')
        return @{ Copied = $copied; Deleted = $deleted; Errors = $errors; Cancelled = $true }
    }
    Set-Progress 1
    [void](Add-Log "Aufgabe '$($t.Name)' fertig" "$copied kopiert, $deleted gelöscht, $errors Fehler" '')
    return @{ Copied = $copied; Deleted = $deleted; Errors = $errors }
}

