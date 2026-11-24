# ---- Zeitplan-Dialog
function Show-ScheduleDialog($t) {
    $d = New-Object System.Windows.Forms.Form
    $d.Text = 'Zeitplan'; $d.ClientSize = New-Object System.Drawing.Size(470, 448); $d.StartPosition = 'CenterParent'
    $d.FormBorderStyle = 'FixedDialog'; $d.MaximizeBox = $false; $d.MinimizeBox = $false; $d.ShowInTaskbar = $false
    $d.BackColor = $th.Surface; $d.ForeColor = $th.Text; $d.Font = $fNormal
    $h = New-Object System.Windows.Forms.Label; $h.Text = "Zeitplan für  '$($t.Name)'"; $h.Font = $fBold; $h.AutoSize = $false; $h.TextAlign = 'MiddleLeft'
    [void](Add-To $d $h 20 14 430 28)
    [void](New-Label $d 20 52 300 'Wann ausführen?' $true)
    $script:dType = New-Object System.Windows.Forms.ComboBox; $script:dType.DropDownStyle = 'DropDownList'; $script:dType.FlatStyle = 'Flat'
    $script:dType.BackColor = $th.Input; $script:dType.ForeColor = $th.Text
    foreach ($x in @('Täglich', 'Wöchentlich', 'Wiederholt (alle X Minuten)', 'Bei Windows-Anmeldung')) { [void]$script:dType.Items.Add($x) }
    [void](Add-To $d $script:dType 20 74 430 28)
    $script:dLblTime = New-Label $d 20 114 200 'Uhrzeit' $true
    $script:dTime = New-Object System.Windows.Forms.DateTimePicker; $script:dTime.Format = 'Custom'; $script:dTime.CustomFormat = 'HH:mm'; $script:dTime.ShowUpDown = $true
    [void](Add-To $d $script:dTime 20 136 120 28)
    $script:dLblMin = New-Label $d 20 114 140 'Intervall in Minuten' $true
    $script:dMin = New-Object System.Windows.Forms.NumericUpDown; $script:dMin.Minimum = 1; $script:dMin.Maximum = 1440; $script:dMin.Value = 60
    $script:dMin.BackColor = $th.Input; $script:dMin.ForeColor = $th.Text
    [void](Add-To $d $script:dMin 20 136 120 28)
    # Wiederholung (nur bei Taeglich/Woechentlich): danach alle X Minuten fuer Y Stunden
    $script:dRep = New-Object System.Windows.Forms.CheckBox; $script:dRep.Text = 'Danach wiederholen alle'; $script:dRep.AutoSize = $false; $script:dRep.ForeColor = $th.Text
    [void](Add-To $d $script:dRep 20 176 168 28)
    $script:dRepMin = New-Object System.Windows.Forms.NumericUpDown; $script:dRepMin.Minimum = 1; $script:dRepMin.Maximum = 1440; $script:dRepMin.Value = 20
    $script:dRepMin.BackColor = $th.Input; $script:dRepMin.ForeColor = $th.Text
    [void](Add-To $d $script:dRepMin 192 176 62 28)
    $script:dRepL1 = New-Label $d 260 181 62 'Min. für' $false
    $script:dRepHr = New-Object System.Windows.Forms.NumericUpDown; $script:dRepHr.Minimum = 1; $script:dRepHr.Maximum = 24; $script:dRepHr.Value = 10
    $script:dRepHr.BackColor = $th.Input; $script:dRepHr.ForeColor = $th.Text
    [void](Add-To $d $script:dRepHr 326 176 56 28)
    $script:dRepL2 = New-Label $d 388 181 60 'Std.' $false
    $script:dLblDays = New-Label $d 20 216 300 'Wochentage' $true
    $script:dDays = @(); $names = @('Mo', 'Di', 'Mi', 'Do', 'Fr', 'Sa', 'So'); $en = @('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday')
    for ($k = 0; $k -lt 7; $k++) {
        $cb = New-Object System.Windows.Forms.CheckBox; $cb.Text = $names[$k]; $cb.Tag = $en[$k]; $cb.AutoSize = $false; $cb.ForeColor = $th.Text
        [void](Add-To $d $cb (20 + $k * 60) 238 58 26); $script:dDays += $cb
    }
    [void](New-Label $d 20 276 430 'Windows-Meldung nach dem Lauf' $true)
    $script:dNotify = New-Object System.Windows.Forms.ComboBox; $script:dNotify.DropDownStyle = 'DropDownList'; $script:dNotify.FlatStyle = 'Flat'
    $script:dNotify.BackColor = $th.Input; $script:dNotify.ForeColor = $th.Text
    foreach ($x in @('Keine Meldung', 'Wenn etwas synchronisiert wurde oder Fehler auftraten', 'Nur bei Fehlern')) { [void]$script:dNotify.Items.Add($x) }
    [void](Add-To $d $script:dNotify 20 298 430 28)
    $script:dInfo = New-Label $d 20 342 430 '' $true
    $script:dInfo.Height = 36
    $script:dSave = New-Btn $d 20 394 140 34 'Aktivieren' $true $null
    $script:dRemove = New-Btn $d 170 394 160 34 'Zeitplan entfernen' $false $th.Surface
    $script:dCancel = New-Btn $d 340 394 110 34 'Abbrechen' $false $th.Surface
    $script:dTask = $t

    # vorhandene Werte laden
    $sc = $t.Schedule
    # Startzeit beim Intervall: bei neuen Zeitplaenen und Altbestand ohne Startzeit ist der Vorschlag "jetzt"
    $script:dNowSet = [bool]($sc -and [int]$sc.Type -eq 2 -and [bool]$sc.Start2)
    $script:dType.SelectedIndex = if ($sc) { [int]$sc.Type } else { 0 }
    $script:dNotify.SelectedIndex = if ($sc -and $null -ne $sc.Notify) { [int]$sc.Notify } else { 1 }
    if ($sc) {
        try { $hm = ([string]$sc.Time).Split(':'); $script:dTime.Value = [datetime]::Today.AddHours([int]$hm[0]).AddMinutes([int]$hm[1]) } catch { }
        if ($sc.Minutes) { $script:dMin.Value = [int]$sc.Minutes }
        foreach ($cb in $script:dDays) { $cb.Checked = (@($sc.Days) -contains $cb.Tag) }
        if ([bool]$sc.Repeat) {
            $script:dRep.Checked = $true
            if ($sc.RepMinutes) { $script:dRepMin.Value = [int]$sc.RepMinutes }
            if ($sc.RepHours) { $script:dRepHr.Value = [int]$sc.RepHours }
        }
    } else { $script:dTime.Value = [datetime]::Today.AddHours(22); foreach ($cb in $script:dDays) { $cb.Checked = ($cb.Tag -notin @('Saturday', 'Sunday')) } }
    $script:dRemove.Enabled = [bool]$t.SchedName
    if ($t.SchedName) { $script:dSave.Text = 'Speichern' }

    $upd = {
        $ty = $script:dType.SelectedIndex
        $script:dLblTime.Visible = $script:dTime.Visible = ($ty -ge 0 -and $ty -le 2)
        # Beim Intervall steht die Startzeit rechts neben dem Intervall, sonst an der Stelle der Uhrzeit
        $tx = if ($ty -eq 2) { 170 } else { 20 }
        $script:dLblTime.Location = New-Object System.Drawing.Point($tx, 114); $script:dTime.Location = New-Object System.Drawing.Point($tx, 136)
        $script:dLblTime.Text = if ($ty -eq 2) { 'Startzeit (erster Lauf)' } else { 'Uhrzeit' }
        $script:dLblMin.Visible = $script:dMin.Visible = ($ty -eq 2)
        if ($ty -eq 2 -and -not $script:dNowSet) { $script:dNowSet = $true; $script:dTime.Value = [datetime]::Now }
        $vis = ($ty -ge 0 -and $ty -le 1)
        $on = ($vis -and $script:dRep.Checked)
        $script:dRep.Visible = $script:dRepMin.Visible = $script:dRepHr.Visible = $script:dRepL1.Visible = $script:dRepL2.Visible = $vis
        $script:dRepMin.Enabled = $script:dRepHr.Enabled = $on
        $script:dLblDays.Visible = ($ty -eq 1); foreach ($cb in $script:dDays) { $cb.Visible = ($ty -eq 1) }
        $script:dInfo.Text = if ($ty -eq 2 -or $on) { 'Die Aufgabe läuft im Hintergrund, solange du angemeldet bist. Verpasste Läufe werden bei Intervallen nicht nachgeholt.' }
                             else { 'Die Aufgabe läuft im Hintergrund, solange du angemeldet bist. Verpasste Läufe werden nachgeholt.' }
    }
    $script:dType.Add_SelectedIndexChanged($upd)
    $script:dRep.Add_CheckedChanged($upd)
    $script:dType.SelectedIndex = -1; $script:dType.SelectedIndex = if ($sc) { [int]$sc.Type } else { 0 }

    $script:dSave.Add_Click({
        $ty = $script:dType.SelectedIndex
        $days = @($script:dDays | Where-Object { $_.Checked } | ForEach-Object { [string]$_.Tag })
        if ($ty -eq 1 -and $days.Count -eq 0) { [void](Show-Msg 'Bitte mindestens einen Wochentag wählen.' 'Zeitplan'); return }
        $rp = ($ty -le 1 -and $script:dRep.Checked)
        if ($rp -and [int]$script:dRepMin.Value -gt [int]$script:dRepHr.Value * 60) { [void](Show-Msg 'Das Intervall darf nicht länger sein als der Zeitraum.' 'Zeitplan'); return }
        $tt = $script:dTask
        $new = [pscustomobject]@{ Type = $ty; Time = $script:dTime.Value.ToString('HH:mm'); Days = $days; Minutes = [int]$script:dMin.Value; Start2 = ($ty -eq 2); Repeat = $rp; RepMinutes = [int]$script:dRepMin.Value; RepHours = [int]$script:dRepHr.Value; Notify = $script:dNotify.SelectedIndex }
        try { Register-Sched $tt $new; Save-Tasks; $script:dSave.FindForm().DialogResult = 'OK' }
        catch { Show-ManualSchedDialog $tt $new $_.Exception.Message $script:dSave.FindForm() }
    })
    $script:dRemove.Add_Click({
        $tt = $script:dTask
        try { Unregister-Sched $tt; $tt.Schedule = $null; Save-Tasks; $script:dSave.FindForm().DialogResult = 'OK' }
        catch { [void](Show-Msg $_.Exception.Message 'Fehler' 'OK' 'Error') }
    })
    $script:dCancel.Add_Click({ $script:dSave.FindForm().DialogResult = 'Cancel' })
    $d.Add_HandleCreated({
        try { $v = if ($isDark) { 1 } else { 0 }; [void][Win32.Dwm]::DwmSetWindowAttribute($script:dSave.FindForm().Handle, 20, [ref]$v, 4) } catch { }
    })
    [void]$d.ShowDialog($form)
    $d.Dispose()
}
function Update-SchedLabel {
    $t = $script:cur
    if (-not $t) { $ui.lblSched.Text = ''; return }
    $info = Get-SchedInfo $t
    if ($info) {
        $n = if ($info.Next -and $info.Next.Year -gt 2000) { '  ·  nächster Lauf ' + $info.Next.ToString('dd.MM. HH:mm') } else { '' }
        $ui.lblSched.Text = 'Zeitplan: ' + (Get-SchedText $t.Schedule) + $n
    } elseif ($t.SchedName) { $ui.lblSched.Text = 'ACHTUNG: Zeitplan fehlt im Aufgabenplaner, bitte hier neu aktivieren' }
    elseif ($t.AutoLnk -and (Test-Path -LiteralPath ([string]$t.AutoLnk))) { $ui.lblSched.Text = 'Läuft bei jeder Windows-Anmeldung (Autostart-Ordner)' }
    elseif ($t.Schedule) { $ui.lblSched.Text = 'ACHTUNG: Zeitplan ist nicht angelegt, bitte hier neu aktivieren' }
    else { $ui.lblSched.Text = 'Kein Zeitplan' }
}
