# ---- Ergebnis-Fenster nach einem Lauf (Zusammenfassung wie bei SyncToy, Details sortier- und kopierbar)
function Format-Bytes([long]$b) {
    if ($b -ge 1GB) { return ('{0:N1} GB' -f ($b / 1GB)) }
    if ($b -ge 1MB) { return ('{0:N1} MB' -f ($b / 1MB)) }
    if ($b -ge 1KB) { return ('{0:N0} KB' -f ($b / 1KB)) }
    return "$b Bytes"
}
function Write-ResultFile($results) {
    try {
        $path = Join-Path $script:dataDir 'ergebnis.csv'
        $sw = New-Object System.IO.StreamWriter($path, $false, (New-Object System.Text.UTF8Encoding($true)))
        try {
            $sw.WriteLine('Aufgabe;Aktion;Ordner;Datei;Relativer Pfad;Status')
            foreach ($r in $results) {
                foreach ($it in $r.Items) {
                    $rel = [string]$it[1]; $isDir = $rel.EndsWith('\')
                    $x = $rel.TrimEnd('\'); $i = $x.LastIndexOf('\')
                    $dir = if ($i -ge 0) { $x.Substring(0, $i) } else { '' }
                    $name = if ($isDir) { '' } elseif ($i -ge 0) { $x.Substring($i + 1) } else { $x }
                    if ($isDir) { $dir = $x }
                    $cells = foreach ($c in @($r.Name, $it[0], $dir, $name, $rel, $it[2])) {
                        $c = [string]$c
                        if ($c.Length -gt 0 -and '=+-@'.Contains($c[0])) { $c = "'" + $c }
                        '"' + $c.Replace('"', '""') + '"'
                    }
                    $sw.WriteLine($cells -join ';')
                }
            }
        } finally { $sw.Dispose() }
        return $path
    } catch { return $null }
}
function Show-ResultDialog($results) {
    $multi = (@($results).Count -gt 1)
    $d = New-Object System.Windows.Forms.Form
    $d.Text = 'DirToy - Ergebnis'; $d.ClientSize = New-Object System.Drawing.Size(840, 620); $d.MinimumSize = New-Object System.Drawing.Size(620, 460)
    $d.StartPosition = 'CenterParent'; $d.ShowInTaskbar = $false; $d.BackColor = $th.Surface; $d.ForeColor = $th.Text; $d.Font = $fNormal
    $h = New-Object System.Windows.Forms.Label; $h.Font = $fBold; $h.AutoSize = $false; $h.TextAlign = 'MiddleLeft'; $h.BackColor = [System.Drawing.Color]::Transparent
    $h.Text = if ($multi) { "Ergebnis - $(@($results).Count) Aufgaben" } else { "Ergebnis - '$(@($results)[0].Name)'" }
    [void](Add-To $d $h 20 12 800 28)

    # Zusammenfassung
    $sv = New-Object System.Windows.Forms.ListView
    [void]$sv.Columns.Add('Zusammenfassung', 600); [void]$sv.Columns.Add('Anzahl', 180)
    Set-ListBehavior $sv $false 26
    $addRow = { param($a, $b, $col, $bold)
        $i = New-Object System.Windows.Forms.ListViewItem($a); [void]$i.SubItems.Add($b); $i.ForeColor = $col
        if ($bold) { $i.Font = $fBold }
        [void]$sv.Items.Add($i)
    }
    $tot = [pscustomobject]@{ Err = 0; Cancel = $false }
    foreach ($r in $results) {
        if ($multi) { & $addRow $r.Name '' $th.Text $true }
        foreach ($k in $r.Sum.Keys) { & $addRow ('   ' + $k) ('{0:N0}' -f $r.Sum[$k]) $th.Text $false }
        if ($r.Skipped -gt 0) { & $addRow '   Übersprungen' ('{0:N0}' -f $r.Skipped) $th.Muted $false }
        if ($r.Errors -gt 0) { & $addRow '   Fehler' ('{0:N0}' -f $r.Errors) $th.Err $false; $tot.Err += $r.Errors }
        $ts = [timespan]::FromSeconds([math]::Round($r.Seconds))
        & $addRow ('   Dauer ' + $ts.ToString('hh\:mm\:ss') + ', kopierte Datenmenge ' + (Format-Bytes $r.Bytes)) '' $th.Muted $false
        if ($r.Cancelled) { & $addRow '   Der Lauf wurde abgebrochen (unvollständig, keine halben Dateien)' '' $th.Err $false; $tot.Cancel = $true }
    }
    [void](Add-To $d $sv 20 46 800 170); $sv.Anchor = $A_TLR

    $l2 = New-Label $d 20 226 800 'Einzelne Aktionen (Fehler zuerst). Spaltenkopf anklicken zum Sortieren, Strg+C kopiert die markierten Zeilen.' $true
    $l2.Anchor = $A_TLR
    # Details (Fehler zuerst, hoechstens 2000 Zeilen)
    $dv = New-Object System.Windows.Forms.ListView
    if ($multi) { [void]$dv.Columns.Add('Aufgabe', 140) }
    [void]$dv.Columns.Add('Aktion', 210); [void]$dv.Columns.Add('Datei', 300); [void]$dv.Columns.Add('Status', 170)
    Set-ListBehavior $dv $true 26
    $max = 2000; $n = 0; $total = 0
    foreach ($r in $results) { $total += $r.Items.Count }
    $dv.BeginUpdate()
    foreach ($pass in 1, 2) {
        foreach ($r in $results) {
            foreach ($it in $r.Items) {
                $isErr = ([string]$it[2] -like 'FEHLER*')
                if (($pass -eq 1) -ne $isErr) { continue }
                if ($n -ge $max) { break }
                $cells = [string[]]$(if ($multi) { @($r.Name, $it[0], $it[1], $it[2]) } else { @($it[0], $it[1], $it[2]) })
                $li = New-Object System.Windows.Forms.ListViewItem($cells[0])
                for ($c = 1; $c -lt $cells.Count; $c++) { [void]$li.SubItems.Add($cells[$c]) }
                $li.ForeColor = Get-StatusColor ([string]$it[2])
                [void]$dv.Items.Add($li); $n++
            }
        }
    }
    $dv.EndUpdate()
    if ($total -gt $n) {
        $cells = [string[]]$(if ($multi) { @('', "... und $($total - $n) weitere Aktionen", '(komplette Liste: Button "Details als CSV öffnen")', '') } else { @("... und $($total - $n) weitere Aktionen", '(komplette Liste: Button "Details als CSV öffnen")', '') })
        $li = New-Object System.Windows.Forms.ListViewItem($cells[0]); for ($c = 1; $c -lt $cells.Count; $c++) { [void]$li.SubItems.Add($cells[$c]) }
        $li.ForeColor = $th.Muted; [void]$dv.Items.Add($li)
    }
    [void](Add-To $d $dv 20 250 800 300); $dv.Anchor = $A_ALL
    $dv.Add_Resize({
        $f = $this; $w = $f.ClientSize.Width; $last = $f.Columns.Count - 1
        $others = 0; for ($i = 0; $i -lt $f.Columns.Count; $i++) { if ($i -ne $last - 1) { $others += $f.Columns[$i].Width } }
        $nw = $w - $others; if ($nw -gt 150) { $f.Columns[$last - 1].Width = $nw }
    })

    $script:resList = $results
    $b1 = New-Btn $d 20 566 210 38 'Details als CSV öffnen' $false $th.Surface; $b1.Anchor = $A_BL
    $b2 = New-Btn $d 720 566 100 38 'Schließen' $true $null; $b2.Anchor = $A_BR
    $b1.Add_Click({
        $f = Write-ResultFile $script:resList
        if ($f) { try { Start-Process -FilePath $f -ErrorAction Stop } catch { Start-Process notepad.exe -ArgumentList "`"$f`"" } }
        else { [void](Show-Msg 'Die CSV-Datei konnte nicht geschrieben werden.' 'DirToy' 'OK' 'Warning') }
    })
    $script:resClose = $b2
    $b2.Add_Click({ $script:resClose.FindForm().Close() })
    $d.CancelButton = $b2
    $d.Add_HandleCreated({
        try { $v = if ($isDark) { 1 } else { 0 }; [void][Win32.Dwm]::DwmSetWindowAttribute($script:resClose.FindForm().Handle, 20, [ref]$v, 4) } catch { }
    })
    [void]$d.ShowDialog($form)
    $d.Dispose()
}
function Show-ResultsIfNeeded {
    if ($script:closeRequested -or -not [bool](Get-Setting 'ShowResult' $true)) { return }
    $list = @($script:results | Where-Object { ($_.Copied + $_.Deleted + $_.Errors + $_.Skipped) -gt 0 -or $_.Cancelled })
    if ($list.Count -eq 0) { return }
    Show-ResultDialog $list
}

