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
    $cell = '<GridViewColumn Width="{0}"><GridViewColumnHeader Tag="{1}">{1}</GridViewColumnHeader><GridViewColumn.CellTemplate><DataTemplate><TextBlock Text="{{Binding {1}}}" {2} TextTrimming="CharacterEllipsis" ToolTip="{{Binding {1}}}"/></DataTemplate></GridViewColumn.CellTemplate></GridViewColumn>'
    $cols = $(if ($multi) { ($cell -f 130, 'Task', '').Replace('>Task<', '>Aufgabe<') } else { '' }) + ($cell -f 220, 'Aktion', '') + ($cell -f $(if ($multi) { 270 } else { 380 }), 'Datei', '') + ($cell -f 190, 'Status', 'Foreground="{Binding StatusBrush}"')
    $dlg = New-Dlg 'DirToy - Ergebnis' 'Width="900" Height="680" MinWidth="620" MinHeight="460"' ('<DockPanel Margin="24">
      <TextBlock x:Name="head" DockPanel.Dock="Top" FontSize="20" FontWeight="SemiBold" Margin="0,0,0,12"/>
      <DockPanel DockPanel.Dock="Bottom" Margin="0,16,0,0" LastChildFill="False"><Button x:Name="csv">Details als CSV öffnen</Button><Button x:Name="close" DockPanel.Dock="Right" Style="{StaticResource Primary}" IsCancel="True" IsDefault="True">Schließen</Button></DockPanel>
      <Border DockPanel.Dock="Top" Background="{DynamicResource Surface}" CornerRadius="12" Padding="16,12" MaxHeight="230"><ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel x:Name="sum"/></ScrollViewer></Border>
      <TextBlock DockPanel.Dock="Top" Style="{StaticResource MutedText}" Margin="4,14,0,8" TextWrapping="Wrap" Text="Einzelne Aktionen (Fehler zuerst). Spaltenkopf anklicken zum Sortieren, Strg+C kopiert die markierten Zeilen."/>
      <Border Background="{DynamicResource Surface}" CornerRadius="12" Padding="4"><ListView x:Name="dv" Background="Transparent" BorderThickness="0" FontSize="13" ScrollViewer.HorizontalScrollBarVisibility="Disabled"><ListView.View><GridView AllowsColumnReorder="False">' + $cols + '</GridView></ListView.View></ListView></Border></DockPanel>')
    $dlg.head.Text = if ($multi) { "Ergebnis: $(@($results).Count) Aufgaben" } else { "Ergebnis: $(@($results)[0].Name)" }
    $add = { param([string]$a, [string]$b, $brush, [bool]$bold)
        $p = New-Object System.Windows.Controls.DockPanel; $p.Margin = '0,2'
        $r = New-Object System.Windows.Controls.TextBlock; $r.Text = $b; $r.Foreground = $brush; [System.Windows.Controls.DockPanel]::SetDock($r, 'Right')
        $l = New-Object System.Windows.Controls.TextBlock; $l.Text = $a; $l.Foreground = $brush; $l.TextWrapping = 'Wrap'
        if ($bold) { $l.FontWeight = 'SemiBold' }
        [void]$p.Children.Add($r); [void]$p.Children.Add($l); [void]$dlg.sum.Children.Add($p)
    }
    foreach ($r in $results) {
        if ($multi) { & $add $r.Name '' $script:br.Text $true }
        foreach ($k in $r.Sum.Keys) { & $add $k ('{0:N0}' -f $r.Sum[$k]) $script:br.Text $false }
        if ($r.Skipped -gt 0) { & $add 'Übersprungen' ('{0:N0}' -f $r.Skipped) $script:br.Muted $false }
        if ($r.Errors -gt 0) { & $add 'Fehler' ('{0:N0}' -f $r.Errors) $script:br.Err $false }
        $ts = [timespan]::FromSeconds([math]::Round($r.Seconds))
        & $add ('Dauer ' + $ts.ToString('hh\:mm\:ss') + ', kopierte Datenmenge ' + (Format-Bytes $r.Bytes)) '' $script:br.Muted $false
        if ($r.Cancelled) { & $add 'Der Lauf wurde abgebrochen (unvollständig, keine halben Dateien)' '' $script:br.Err $false }
    }
    # Details (Fehler zuerst, hoechstens 2000 Zeilen)
    $rows = [System.Collections.ObjectModel.ObservableCollection[DirToyRow]]::new()
    $max = 2000; $total = 0
    foreach ($r in $results) { $total += $r.Items.Count }
    foreach ($pass in 1, 2) {
        foreach ($r in $results) {
            foreach ($it in $r.Items) {
                if (($pass -eq 1) -ne ([string]$it[2] -like 'FEHLER*')) { continue }
                if ($rows.Count -ge $max) { break }
                $x = [DirToyRow]::new(); $x.Task = [string]$r.Name; $x.Aktion = [string]$it[0]; $x.Datei = [string]$it[1]; $x.Status = [string]$it[2]; $x.StatusBrush = Get-StatusBrush ([string]$it[2])
                $rows.Add($x)
            }
        }
    }
    if ($total -gt $rows.Count) {
        $x = [DirToyRow]::new(); $x.Aktion = "... und $($total - $rows.Count) weitere Aktionen"; $x.Datei = 'komplette Liste: „Details als CSV öffnen“'; $rows.Add($x)
    }
    $dlg.dv.ItemsSource = $rows
    $script:resDlg = $dlg; $script:resList = $results; $script:resSort = ''; $script:resAsc = $true
    $dlg.dv.AddHandler([System.Windows.Controls.GridViewColumnHeader]::ClickEvent, [System.Windows.RoutedEventHandler] {
        param($s, $e)
        $h = $e.OriginalSource
        if ($h -isnot [System.Windows.Controls.GridViewColumnHeader] -or -not $h.Tag) { return }
        $script:resAsc = if ($script:resSort -eq $h.Tag) { -not $script:resAsc } else { $true }
        $script:resSort = [string]$h.Tag
        $v = [System.Windows.Data.CollectionViewSource]::GetDefaultView($script:resDlg.dv.ItemsSource)
        $v.SortDescriptions.Clear()
        $v.SortDescriptions.Add((New-Object System.ComponentModel.SortDescription($script:resSort, $(if ($script:resAsc) { 'Ascending' } else { 'Descending' }))))
    })
    $dlg.dv.Add_PreviewKeyDown({
        param($s, $e)
        if ($e.Key -eq 'C' -and [System.Windows.Input.Keyboard]::Modifiers -eq 'Control') { Copy-Rows $false $script:resDlg.dv; $e.Handled = $true }
    })
    $dlg.csv.Add_Click({
        $f = Write-ResultFile $script:resList
        if ($f) { try { Start-Process -FilePath $f -ErrorAction Stop } catch { Start-Process notepad.exe -ArgumentList "`"$f`"" } }
        else { [void](Show-Msg 'Die CSV-Datei konnte nicht geschrieben werden.' 'DirToy' 'OK' 'Warning') }
    })
    $dlg.close.Add_Click({ $script:resDlg.Win.Close() })
    Show-Dlg $dlg
}
function Show-ResultsIfNeeded {
    if ($script:closeRequested -or -not [bool](Get-Setting 'ShowResult' $true)) { return }
    $list = @($script:results | Where-Object { ($_.Copied + $_.Deleted + $_.Errors + $_.Skipped) -gt 0 -or $_.Cancelled })
    if ($list.Count -eq 0) { return }
    Show-ResultDialog $list
}

