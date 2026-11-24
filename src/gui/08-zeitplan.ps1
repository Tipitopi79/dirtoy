# ---- Zeitplan-Dialog
function Get-SchedInput {   # liest die Eingaben; Rueckgabe: Zeitplan oder Fehlertext
    $d = $script:sd
    $ty = 0; foreach ($k in 0..3) { if ($d["t$k"].IsChecked) { $ty = $k } }
    $num = { param([string]$v, [int]$lo, [int]$hi) $n = 0; if ([int]::TryParse($v.Trim(), [ref]$n) -and $n -ge $lo -and $n -le $hi) { $n } else { $null } }
    $time = [datetime]::MinValue
    $okTime = [datetime]::TryParseExact($d.time.Text.Trim(), [string[]]@('H:mm', 'HH:mm'), [Globalization.CultureInfo]::InvariantCulture, 'None', [ref]$time)
    if ($ty -le 2 -and -not $okTime) { return 'Bitte eine Uhrzeit im Format HH:MM eingeben, z. B. 18:30.' }
    $min = & $num $d.min.Text 1 1440; $rm = & $num $d.repMin.Text 1 1440; $rh = & $num $d.repHr.Text 1 24
    if ($ty -eq 2 -and $null -eq $min) { return 'Das Intervall muss zwischen 1 und 1440 Minuten liegen.' }
    $days = @(foreach ($k in $script:sdDays) { if ($d[$k[0]].IsChecked) { $k[1] } })
    if ($ty -eq 1 -and $days.Count -eq 0) { return 'Bitte mindestens einen Wochentag wählen.' }
    $rp = ($ty -le 1 -and [bool]$d.rep.IsChecked)
    if ($rp -and ($null -eq $rm -or $null -eq $rh)) { return 'Wiederholung: 1 bis 1440 Minuten, für 1 bis 24 Stunden.' }
    if ($rp -and $rm -gt $rh * 60) { return 'Das Intervall darf nicht länger sein als der Zeitraum.' }
    $nt = 1; foreach ($k in 0..2) { if ($d["n$k"].IsChecked) { $nt = $k } }
    return [pscustomobject]@{ Type = $ty; Time = $(if ($okTime) { $time.ToString('HH:mm') } else { '22:00' }); Days = $days; Minutes = $(if ($null -eq $min) { 60 } else { $min }); Start2 = ($ty -eq 2); Repeat = $rp; RepMinutes = $(if ($null -eq $rm) { 20 } else { $rm }); RepHours = $(if ($null -eq $rh) { 10 } else { $rh }); Notify = $nt }
}
function Update-SchedDialog {
    $d = $script:sd
    $ty = 0; foreach ($k in 0..3) { if ($d["t$k"].IsChecked) { $ty = $k } }
    $vis = { param([bool]$x) if ($x) { 'Visible' } else { 'Collapsed' } }
    $d.pTime.Visibility = & $vis ($ty -le 2)
    $d.lTime.Text = if ($ty -eq 2) { 'Startzeit (erster Lauf)' } else { 'Uhrzeit' }
    $d.pMin.Visibility = & $vis ($ty -eq 2)
    if ($ty -eq 2 -and -not $script:sdNowSet) { $script:sdNowSet = $true; $d.time.Text = [datetime]::Now.ToString('HH:mm') }
    $d.pRep.Visibility = & $vis ($ty -le 1)
    $on = ($ty -le 1 -and [bool]$d.rep.IsChecked)
    $d.repMin.IsEnabled = $d.repHr.IsEnabled = $on
    $d.pDays.Visibility = & $vis ($ty -eq 1)
    $d.info.Text = 'Die Aufgabe läuft im Hintergrund, solange du angemeldet bist. ' + $(if ($ty -eq 2 -or $on) { 'Verpasste Läufe werden bei Intervallen nicht nachgeholt.' } else { 'Verpasste Läufe werden nachgeholt.' })
}
$script:sdDays = @(@('d0', 'Monday'), @('d1', 'Tuesday'), @('d2', 'Wednesday'), @('d3', 'Thursday'), @('d4', 'Friday'), @('d5', 'Saturday'), @('d6', 'Sunday'))
function Show-ScheduleDialog($t) {
    $dlg = New-Dlg 'Zeitplan' 'Width="600" SizeToContent="Height" ResizeMode="NoResize"' '<StackPanel Margin="24">
      <TextBlock x:Name="head" FontSize="20" FontWeight="SemiBold" TextTrimming="CharacterEllipsis" Margin="0,0,0,16"/>
      <TextBlock Text="Wann ausführen?" Style="{StaticResource MutedText}" Margin="0,0,0,6"/>
      <Border Background="{DynamicResource Surface}" CornerRadius="8" HorizontalAlignment="Left"><StackPanel Orientation="Horizontal"><RadioButton x:Name="t0" GroupName="t" Style="{StaticResource Seg}">Täglich</RadioButton><RadioButton x:Name="t1" GroupName="t" Style="{StaticResource Seg}">Wöchentlich</RadioButton><RadioButton x:Name="t2" GroupName="t" Style="{StaticResource Seg}">Alle X Minuten</RadioButton><RadioButton x:Name="t3" GroupName="t" Style="{StaticResource Seg}">Bei Anmeldung</RadioButton></StackPanel></Border>
      <StackPanel Orientation="Horizontal" Margin="0,16,0,0">
        <StackPanel x:Name="pMin" Margin="0,0,20,0"><TextBlock Text="Intervall in Minuten" Style="{StaticResource MutedText}" Margin="0,0,0,6"/><TextBox x:Name="min" Width="120" AutomationProperties.Name="Intervall in Minuten"/></StackPanel>
        <StackPanel x:Name="pTime"><TextBlock x:Name="lTime" Style="{StaticResource MutedText}" Margin="0,0,0,6"/><TextBox x:Name="time" Width="120" AutomationProperties.Name="Uhrzeit"/></StackPanel></StackPanel>
      <StackPanel x:Name="pDays" Orientation="Horizontal" Margin="0,16,0,0"><CheckBox x:Name="d0" Style="{StaticResource Chip}">Mo</CheckBox><CheckBox x:Name="d1" Style="{StaticResource Chip}">Di</CheckBox><CheckBox x:Name="d2" Style="{StaticResource Chip}">Mi</CheckBox><CheckBox x:Name="d3" Style="{StaticResource Chip}">Do</CheckBox><CheckBox x:Name="d4" Style="{StaticResource Chip}">Fr</CheckBox><CheckBox x:Name="d5" Style="{StaticResource Chip}">Sa</CheckBox><CheckBox x:Name="d6" Style="{StaticResource Chip}">So</CheckBox></StackPanel>
      <StackPanel x:Name="pRep" Orientation="Horizontal" Margin="0,16,0,0"><CheckBox x:Name="rep" VerticalAlignment="Center">Danach wiederholen alle</CheckBox><TextBox x:Name="repMin" Width="60" Margin="10,0" AutomationProperties.Name="Wiederholung in Minuten"/><TextBlock Text="Min. für" VerticalAlignment="Center"/><TextBox x:Name="repHr" Width="50" Margin="10,0" AutomationProperties.Name="Wiederholung für Stunden"/><TextBlock Text="Std." VerticalAlignment="Center"/></StackPanel>
      <TextBlock Text="Windows-Meldung nach dem Lauf" Style="{StaticResource MutedText}" Margin="0,20,0,8"/>
      <RadioButton x:Name="n0" GroupName="n" Margin="0,0,0,8">Keine Meldung</RadioButton><RadioButton x:Name="n1" GroupName="n" Margin="0,0,0,8">Wenn etwas synchronisiert wurde oder Fehler auftraten</RadioButton><RadioButton x:Name="n2" GroupName="n">Nur bei Fehlern</RadioButton>
      <TextBlock x:Name="info" Style="{StaticResource MutedText}" TextWrapping="Wrap" Margin="0,20,0,0"/>
      <DockPanel Margin="0,20,0,0" LastChildFill="False"><Button x:Name="save" Style="{StaticResource Primary}" IsDefault="True" MinWidth="120" Margin="0,0,8,0">Aktivieren</Button><Button x:Name="remove">Zeitplan entfernen</Button><Button x:Name="cancel" DockPanel.Dock="Right" IsCancel="True">Abbrechen</Button></DockPanel>
    </StackPanel>'
    $script:sd = $dlg; $script:sdTask = $t
    $dlg.head.Text = "Zeitplan für $($t.Name)"
    $sc = $t.Schedule
    # Startzeit beim Intervall: bei neuen Zeitplaenen und Altbestand ohne Startzeit ist der Vorschlag "jetzt"
    $script:sdNowSet = [bool]($sc -and [int]$sc.Type -eq 2 -and [bool]$sc.Start2)
    $dlg.time.Text = '22:00'; $dlg.min.Text = '60'; $dlg.repMin.Text = '20'; $dlg.repHr.Text = '10'
    $ty = if ($sc) { [int]$sc.Type } else { 0 }
    $dlg["t$ty"].IsChecked = $true
    $dlg["n$(if ($sc -and $null -ne $sc.Notify) { [int]$sc.Notify } else { 1 })"].IsChecked = $true
    foreach ($k in $script:sdDays) { $dlg[$k[0]].IsChecked = $(if ($sc) { @($sc.Days) -contains $k[1] } else { $k[1] -notin @('Saturday', 'Sunday') }) }
    if ($sc) {
        if ([string]$sc.Time) { $dlg.time.Text = [string]$sc.Time }
        if ($sc.Minutes) { $dlg.min.Text = [string]$sc.Minutes }
        if ([bool]$sc.Repeat) {
            $dlg.rep.IsChecked = $true
            if ($sc.RepMinutes) { $dlg.repMin.Text = [string]$sc.RepMinutes }
            if ($sc.RepHours) { $dlg.repHr.Text = [string]$sc.RepHours }
        }
    }
    $dlg.remove.IsEnabled = [bool]$t.SchedName
    if ($t.SchedName) { $dlg.save.Content = 'Speichern' }
    foreach ($k in 't0', 't1', 't2', 't3') { $dlg[$k].Add_Checked({ Update-SchedDialog }) }
    $dlg.rep.Add_Checked({ Update-SchedDialog }); $dlg.rep.Add_Unchecked({ Update-SchedDialog })
    Update-SchedDialog
    $dlg.save.Add_Click({
        $new = Get-SchedInput
        if ($new -is [string]) { [void](Show-Msg $new 'Zeitplan' 'OK' 'Warning'); return }
        try { Register-Sched $script:sdTask $new; Save-Tasks; $script:sd.Win.Close() }
        catch { Show-ManualSchedDialog $script:sdTask $new $_.Exception.Message }
    })
    $dlg.remove.Add_Click({
        try { Unregister-Sched $script:sdTask; $script:sdTask.Schedule = $null; Save-Tasks; $script:sd.Win.Close() }
        catch { [void](Show-Msg $_.Exception.Message 'Fehler' 'OK' 'Error') }
    })
    $dlg.cancel.Add_Click({ $script:sd.Win.Close() })
    Show-Dlg $dlg
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
