# ---- Hauptfenster (WPF)
$script:xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" xmlns:sys="clr-namespace:System;assembly=mscorlib"
        Width="1120" Height="780" MinWidth="900" MinHeight="660" WindowStartupLocation="CenterScreen"
        FontFamily="Segoe UI" FontSize="14" Background="{DynamicResource Bg}" Foreground="{DynamicResource Text}"
        UseLayoutRounding="True" TextOptions.TextFormattingMode="Display">
  <Window.TaskbarItemInfo><TaskbarItemInfo x:Name="task"/></Window.TaskbarItemInfo>
  <Window.Resources>
@@STILE@@
  </Window.Resources>
  <Grid x:Name="root" Background="{DynamicResource Bg}">
    <Grid.ColumnDefinitions><ColumnDefinition Width="250"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
    <Border Background="{DynamicResource Surface}">
      <DockPanel Margin="12,16,12,12">
        <StackPanel DockPanel.Dock="Top" Margin="10,0,0,14">
          <StackPanel Orientation="Horizontal"><TextBlock Text="&#xE895;" Style="{StaticResource Icon}" FontSize="22" Foreground="{DynamicResource Accent}" Margin="0,2,10,0"/><TextBlock Text="DirToy" FontSize="24" FontWeight="SemiBold" Foreground="{DynamicResource Accent}"/></StackPanel>
          <Button x:Name="lblVer" AutomationProperties.Name="Updates prüfen" Style="{StaticResource Ghost}" Height="24" Padding="0" FontSize="12" Foreground="{DynamicResource Muted}" HorizontalAlignment="Left" ToolTip="Nach Updates suchen"/>
        </StackPanel>
        <StackPanel DockPanel.Dock="Bottom">
          <Button x:Name="btnUpd" Style="{StaticResource Primary}" Visibility="Collapsed" Margin="0,0,0,8"/>
          <Button x:Name="btnLog" AutomationProperties.Name="Protokoll" Style="{StaticResource Ghost}" Height="34" ToolTip="Protokoll aller bisherigen Läufe (sync.log)"><StackPanel Orientation="Horizontal"><TextBlock Text="&#xE7C3;" Style="{StaticResource Icon}" Margin="0,0,10,0"/><TextBlock Text="Protokoll"/></StackPanel></Button>
          <Button x:Name="btnTheme" AutomationProperties.Name="Design" Style="{StaticResource Ghost}" Height="34" ToolTip="Automatisch (wie Windows), Hell oder Dunkel. DirToy startet dabei kurz neu."><StackPanel Orientation="Horizontal"><TextBlock Text="&#xE793;" Style="{StaticResource Icon}" Margin="0,0,10,0"/><TextBlock x:Name="lblTheme"/></StackPanel></Button>
          <Button x:Name="btnHelp" AutomationProperties.Name="Hilfe" Style="{StaticResource Ghost}" Height="34" ToolTip="Anleitung"><StackPanel Orientation="Horizontal"><TextBlock Text="&#xE897;" Style="{StaticResource Icon}" Margin="0,0,10,0"/><TextBlock Text="Hilfe"/></StackPanel></Button>
        </StackPanel>
        <Button x:Name="btnNew" AutomationProperties.Name="Neue Aufgabe" DockPanel.Dock="Bottom" Margin="0,8,0,12" ToolTip="Neue Aufgabe anlegen"><StackPanel Orientation="Horizontal"><TextBlock Text="&#xE710;" Style="{StaticResource Icon}" Margin="0,0,8,0"/><TextBlock Text="Neue Aufgabe"/></StackPanel></Button>
        <ListBox x:Name="lb" Style="{StaticResource PlainList}" Background="Transparent" BorderThickness="0" Foreground="{DynamicResource Text}" ScrollViewer.HorizontalScrollBarVisibility="Disabled" AutomationProperties.Name="Aufgaben">
          <ListBox.ItemTemplate><DataTemplate>
            <DockPanel><Ellipse DockPanel.Dock="Left" Width="9" Height="9" Fill="{Binding Dot}" Margin="0,0,10,0" VerticalAlignment="Center"/>
              <StackPanel><TextBlock Text="{Binding Name}" TextTrimming="CharacterEllipsis"/><TextBlock Text="{Binding Sub}" Style="{StaticResource MutedText}" TextTrimming="CharacterEllipsis"/></StackPanel></DockPanel>
          </DataTemplate></ListBox.ItemTemplate>
        </ListBox>
      </DockPanel>
    </Border>
    <Grid Grid.Column="1" Margin="24,18,24,16">
      <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
      <DockPanel>
        <Button x:Name="btnGear" DockPanel.Dock="Right" Style="{StaticResource Ghost}" ToolTip="Einstellungen der Aufgabe: Modus, Ausschlüsse, Ordnerauswahl, Löschen" AutomationProperties.Name="Einstellungen der Aufgabe"><TextBlock Text="&#xE713;" Style="{StaticResource Icon}" FontSize="18"/></Button>
        <Button x:Name="btnSched" AutomationProperties.Name="Zeitplan" DockPanel.Dock="Right" Style="{StaticResource Ghost}" ToolTip="Automatische Ausführung einrichten"><StackPanel Orientation="Horizontal"><TextBlock Text="&#xE823;" Style="{StaticResource Icon}" Margin="0,0,8,0"/><TextBlock x:Name="lblSched" MaxWidth="360" TextTrimming="CharacterEllipsis"/></StackPanel></Button>
        <TextBox x:Name="tbName" FontSize="22" FontWeight="SemiBold" Height="42" Background="Transparent" BorderBrush="Transparent" Padding="4,0" Margin="-5,0,8,0" AutomationProperties.Name="Name der Aufgabe" ToolTip="Name der Aufgabe (anklicken zum Ändern)"/>
      </DockPanel>
      <Border x:Name="gear" Grid.Row="1" Visibility="Collapsed" Background="{DynamicResource Surface}" CornerRadius="12" Padding="16" Margin="0,12,0,0">
        <StackPanel>
          <StackPanel x:Name="gearMode" Visibility="Collapsed" Margin="0,0,0,16">
            <TextBlock x:Name="lblGearMode" Text="Modus: legt fest, was ein Lauf tut. Nach dem ersten Lauf nur noch hier änderbar." Style="{StaticResource MutedText}" TextWrapping="Wrap" Margin="0,0,0,6"/>
          </StackPanel>
          <TextBlock Text="Nicht synchronisieren: Dateinamen oder Muster, mit ; getrennt (z. B. Thumbs.db;*.tmp;~$*;node_modules)" Style="{StaticResource MutedText}" TextWrapping="Wrap" Margin="0,0,0,6"/>
          <DockPanel><Button x:Name="btnDel" DockPanel.Dock="Right" Margin="8,0,0,0" Height="34" Foreground="{DynamicResource Err}" ToolTip="Aufgabe löschen (Dateien bleiben unverändert)">Aufgabe löschen</Button>
            <Button x:Name="btnDirs" DockPanel.Dock="Right" Margin="8,0,0,0" Height="34" ToolTip="Ordner abwählen, die nicht synchronisiert werden sollen"/>
            <TextBox x:Name="tbEx" AutomationProperties.Name="Ausschlussmuster"/></DockPanel>
        </StackPanel>
      </Border>
      <Grid Grid.Row="2" Margin="0,14,0,0">
        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="190"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
        <Border Background="{DynamicResource Surface}" CornerRadius="14" Padding="16">
          <StackPanel>
            <Path Data="M 1,8 Q 1,4 5,4 L 15,4 L 19,9 L 39,9 Q 43,9 43,13 L 43,31 Q 43,35 39,35 L 5,35 Q 1,35 1,31 Z" Stroke="{DynamicResource Accent}" StrokeThickness="2.5" StrokeLineJoin="Round" Width="46" Height="38" HorizontalAlignment="Center"/>
            <TextBlock x:Name="lblA" FontSize="16" FontWeight="SemiBold" HorizontalAlignment="Center" Margin="0,8,0,0" TextTrimming="CharacterEllipsis"/>
            <TextBlock Text="Ordner A" Style="{StaticResource MutedText}" HorizontalAlignment="Center" Margin="0,2,0,10"/>
            <DockPanel><Button x:Name="btnA" DockPanel.Dock="Right" Height="34" Padding="10,0" Margin="6,0,0,0" ToolTip="Ordner A wählen" AutomationProperties.Name="Ordner A wählen"><TextBlock Text="&#xE712;" Style="{StaticResource Icon}"/></Button><TextBox x:Name="tbA" ToolTip="{Binding Text, RelativeSource={RelativeSource Self}}" AutomationProperties.Name="Ordner A"/></DockPanel>
          </StackPanel>
        </Border>
        <Grid Grid.Column="1" HorizontalAlignment="Center" VerticalAlignment="Center" Width="150" Height="90">
          <Line x:Name="l1" X1="0" X2="138" Y1="28" Y2="28" Stroke="{DynamicResource Border}" StrokeThickness="1.5" StrokeDashArray="2 4"/>
          <Line x:Name="l2" X1="12" X2="150" Y1="62" Y2="62" Stroke="{DynamicResource Border}" StrokeThickness="1.5" StrokeDashArray="2 4"/>
          <Path x:Name="p1" Data="M 142,22 L 149,28 L 142,34" Stroke="{DynamicResource Muted}" StrokeThickness="2"/>
          <Path x:Name="p2" Data="M 8,56 L 1,62 L 8,68" Stroke="{DynamicResource Muted}" StrokeThickness="2"/>
          <Canvas x:Name="lane" Width="150" Height="90" Opacity="0"/>
          <Grid x:Name="done" Width="64" Height="64" Opacity="0" IsHitTestVisible="False" RenderTransformOrigin="0.5,0.5"><Grid.RenderTransform><ScaleTransform x:Name="doneScale"/></Grid.RenderTransform>
            <Ellipse x:Name="doneBg"/><Path x:Name="donePath" StrokeThickness="5" StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round" StrokeDashArray="14" StrokeDashOffset="14"/></Grid>
        </Grid>
        <Border Grid.Column="2" Background="{DynamicResource Surface}" CornerRadius="14" Padding="16">
          <StackPanel>
            <Path Data="M 1,8 Q 1,4 5,4 L 15,4 L 19,9 L 39,9 Q 43,9 43,13 L 43,31 Q 43,35 39,35 L 5,35 Q 1,35 1,31 Z" Stroke="{DynamicResource Accent}" StrokeThickness="2.5" StrokeLineJoin="Round" Width="46" Height="38" HorizontalAlignment="Center"/>
            <TextBlock x:Name="lblB" FontSize="16" FontWeight="SemiBold" HorizontalAlignment="Center" Margin="0,8,0,0" TextTrimming="CharacterEllipsis"/>
            <TextBlock Text="Ordner B" Style="{StaticResource MutedText}" HorizontalAlignment="Center" Margin="0,2,0,10"/>
            <DockPanel><Button x:Name="btnB" DockPanel.Dock="Right" Height="34" Padding="10,0" Margin="6,0,0,0" ToolTip="Ordner B wählen" AutomationProperties.Name="Ordner B wählen"><TextBlock Text="&#xE712;" Style="{StaticResource Icon}"/></Button><TextBox x:Name="tbB" ToolTip="{Binding Text, RelativeSource={RelativeSource Self}}" AutomationProperties.Name="Ordner B"/></DockPanel>
          </StackPanel>
        </Border>
      </Grid>
      <DockPanel x:Name="bar" Grid.Row="3" Margin="0,14,0,0" LastChildFill="False">
        <Border x:Name="modeBox" Background="{DynamicResource Surface}" CornerRadius="8" VerticalAlignment="Center" HorizontalAlignment="Left"><StackPanel Orientation="Horizontal">
          <RadioButton x:Name="m0" Style="{StaticResource Seg}" GroupName="m">Synchronisieren</RadioButton><RadioButton x:Name="m1" Style="{StaticResource Seg}" GroupName="m">Echo</RadioButton><RadioButton x:Name="m2" Style="{StaticResource Seg}" GroupName="m">Beitragen</RadioButton></StackPanel></Border>
        <Button x:Name="btnAll" DockPanel.Dock="Right" ToolTip="Alle Aufgaben nacheinander ausführen">Alle ausführen</Button>
        <Button x:Name="btnRun" AutomationProperties.Name="Starten" DockPanel.Dock="Right" Style="{StaticResource Primary}" Margin="8,0" MinWidth="120" ToolTip="Diese Aufgabe jetzt ausführen"><StackPanel Orientation="Horizontal"><TextBlock Text="&#xE768;" Style="{StaticResource Icon}" FontSize="13" Margin="0,0,8,0"/><TextBlock Text="Starten"/></StackPanel></Button>
        <Button x:Name="btnCancel" DockPanel.Dock="Right" Margin="8,0" MinWidth="120" Visibility="Collapsed" ToolTip="Bricht nach der aktuellen Datei ab. Es bleiben keine halben Dateien zurück.">Abbrechen</Button>
        <Button x:Name="btnPrev" DockPanel.Dock="Right" ToolTip="Zeigt nur an, was passieren würde">Vorschau</Button>
      </DockPanel>
      <TextBlock x:Name="lblMode" Grid.Row="4" Style="{StaticResource MutedText}" Margin="4,8,0,0"/>
      <StackPanel Grid.Row="5" Margin="0,14,0,10">
        <Border x:Name="track" Height="8" CornerRadius="4" Background="{DynamicResource Input}" ClipToBounds="True"><Grid HorizontalAlignment="Left"><Border x:Name="fill" Width="0" HorizontalAlignment="Left" CornerRadius="4" Background="{DynamicResource Accent}"/>
          <Canvas x:Name="shineBox" ClipToBounds="True" HorizontalAlignment="Left" Width="{Binding ActualWidth, ElementName=fill}"><Rectangle x:Name="shine" Width="90" Height="8" Visibility="Collapsed"><Rectangle.Fill><LinearGradientBrush StartPoint="0,0" EndPoint="1,0"><GradientStop Color="#00FFFFFF" Offset="0"/><GradientStop Color="#80FFFFFF" Offset="0.5"/><GradientStop Color="#00FFFFFF" Offset="1"/></LinearGradientBrush></Rectangle.Fill></Rectangle></Canvas></Grid></Border>
        <TextBlock x:Name="lblStatus" Style="{StaticResource MutedText}" Margin="4,6,0,0" Text="Bereit." TextTrimming="CharacterEllipsis"/>
      </StackPanel>
      <Border Grid.Row="6" Background="{DynamicResource Surface}" CornerRadius="12" Padding="4">
        <Grid>
          <ListView x:Name="lv" Background="Transparent" BorderThickness="0" FontSize="13" ScrollViewer.HorizontalScrollBarVisibility="Disabled" SelectionMode="Extended" VirtualizingPanel.IsVirtualizing="True" VirtualizingPanel.VirtualizationMode="Recycling" AutomationProperties.Name="Aktionen">
            <ListView.ContextMenu><ContextMenu><MenuItem x:Name="mi1" Header="Markierte Zeilen kopieren (Strg+C)"/><MenuItem x:Name="mi2" Header="Alle Zeilen kopieren"/><MenuItem x:Name="mi3" Header="Alles markieren (Strg+A)"/></ContextMenu></ListView.ContextMenu>
            <ListView.View><GridView AllowsColumnReorder="False">
              <GridViewColumn x:Name="c0" Width="250"><GridViewColumnHeader x:Name="h0" Tag="Aktion">Aktion</GridViewColumnHeader><GridViewColumn.CellTemplate><DataTemplate><StackPanel Orientation="Horizontal"><TextBlock Text="{Binding Icon}" Foreground="{Binding IconBrush}" Style="{StaticResource Icon}" FontSize="13" Width="22"/><TextBlock Text="{Binding Aktion}"/></StackPanel></DataTemplate></GridViewColumn.CellTemplate></GridViewColumn>
              <GridViewColumn x:Name="c1" Width="330"><GridViewColumnHeader x:Name="h1" Tag="Datei">Datei</GridViewColumnHeader><GridViewColumn.CellTemplate><DataTemplate><TextBlock Text="{Binding Datei}" TextTrimming="CharacterEllipsis" ToolTip="{Binding Datei}"/></DataTemplate></GridViewColumn.CellTemplate></GridViewColumn>
              <GridViewColumn x:Name="c2" Width="180"><GridViewColumnHeader x:Name="h2" Tag="Status">Status</GridViewColumnHeader><GridViewColumn.CellTemplate><DataTemplate><TextBlock Text="{Binding Status}" Foreground="{Binding StatusBrush}" TextTrimming="CharacterEllipsis" ToolTip="{Binding Status}"/></DataTemplate></GridViewColumn.CellTemplate></GridViewColumn>
            </GridView></ListView.View>
          </ListView>
          <StackPanel x:Name="empty" VerticalAlignment="Center" HorizontalAlignment="Center" IsHitTestVisible="False">
            <TextBlock Text="&#xE895;" Style="{StaticResource Icon}" FontSize="34" Foreground="{DynamicResource Border}" HorizontalAlignment="Center"/>
            <TextBlock Text="Noch nichts gelaufen. Mit „Vorschau“ siehst du, was passieren würde." Style="{StaticResource MutedText}" Margin="0,10,0,0"/>
          </StackPanel>
        </Grid>
      </Border>
    </Grid>
  </Grid>
</Window>
'@.Replace('@@STILE@@', $script:styles)
$script:win = [System.Windows.Markup.XamlReader]::Parse($script:xaml)
$win = $script:win
Limit-Window $win
$script:ui = @{}
foreach ($m in [regex]::Matches($script:xaml, 'x:Name="(\w+)"')) { $n = $m.Groups[1].Value; $e = $win.FindName($n); if ($e) { $script:ui[$n] = $e } }
$ui = $script:ui
Set-Brushes $win
$win.Title = "DirToy $($script:version)"
$ico = Get-AppIcon
if ($ico) { $win.Icon = [System.Windows.Interop.Imaging]::CreateBitmapSourceFromHIcon($ico.Handle, [System.Windows.Int32Rect]::Empty, [System.Windows.Media.Imaging.BitmapSizeOptions]::FromEmptyOptions()) }
$ui.lblVer.Content = "Version $($script:version)  ·  Updates prüfen"
$ui.lblTheme.Text = @{ auto = 'Design: Automatisch'; hell = 'Design: Hell'; dunkel = 'Design: Dunkel' }[$script:themeSetting]
# $form: Besitzer fuer die Dialoge
$script:form = New-Object DirToyOwner
$form = $script:form
$win.Add_SourceInitialized({ $form.H = (New-Object System.Windows.Interop.WindowInteropHelper $win).Handle })
Set-DarkTitle $win
$script:updTimer = New-Object System.Windows.Threading.DispatcherTimer; $script:updTimer.Interval = [TimeSpan]::FromMilliseconds(300)
$script:updTimer.Add_Tick({ if ($script:updTask -and $script:updTask.IsCompleted) { Finish-UpdateCheck } })

# Liste der Aktionen
$script:rows = [System.Collections.ObjectModel.ObservableCollection[DirToyRow]]::new()
$ui.lv.ItemsSource = $script:rows
$script:sortCol = ''; $script:sortAsc = $true
function Set-ListSort([string]$col, [bool]$asc) {
    $script:sortCol = $col; $script:sortAsc = $asc
    $v = [System.Windows.Data.CollectionViewSource]::GetDefaultView($script:rows)
    $v.SortDescriptions.Clear()
    if ($col) { $v.SortDescriptions.Add((New-Object System.ComponentModel.SortDescription($col, $(if ($asc) { 'Ascending' } else { 'Descending' })))) }
    foreach ($h in $ui.h0, $ui.h1, $ui.h2) { $h.Content = [string]$h.Tag + $(if ($h.Tag -eq $col) { if ($asc) { ' ' + [char]0x25B2 } else { ' ' + [char]0x25BC } } else { '' }) }
}
foreach ($h in $ui.h0, $ui.h1, $ui.h2) {
    $h.Add_Click({ if (-not $script:busy) { $c = [string]$this.Tag; Set-ListSort $c $(if ($script:sortCol -eq $c) { -not $script:sortAsc } else { $true }) } })
}
function Copy-Rows([bool]$all, $list = $ui.lv) {
    $items = if ($all) { @($list.Items) } else { @($list.Items | Where-Object { $list.SelectedItems.Contains($_) }) }
    if ($items.Count -eq 0) { return }
    $sb = New-Object System.Text.StringBuilder
    foreach ($r in $items) { [void]$sb.AppendLine("$($r.Aktion)`t$($r.Datei)`t$($r.Status)") }
    try { [System.Windows.Forms.Clipboard]::SetText($sb.ToString()) } catch { }
}
$ui.mi1.Add_Click({ Copy-Rows $false }); $ui.mi2.Add_Click({ Copy-Rows $true }); $ui.mi3.Add_Click({ $ui.lv.SelectAll() })
$ui.lv.Add_PreviewKeyDown({
    param($s, $e)
    if ($e.Key -eq 'C' -and [System.Windows.Input.Keyboard]::Modifiers -eq 'Control') { Copy-Rows $false; $e.Handled = $true }
})
$ui.lv.Add_MouseDoubleClick({
    $r = $ui.lv.SelectedItem
    if ($r -and $r.File -and $r.File.EndsWith('vorschau.csv') -and (Test-Path -LiteralPath $r.File)) {
        try { Start-Process -FilePath $r.File -ErrorAction Stop }
        catch { Start-Process notepad.exe -ArgumentList "`"$($r.File)`"" }   # keine Zuordnung fuer .csv: im Editor oeffnen
    }
})
$ui.lv.Add_SizeChanged({ $w = $ui.lv.ActualWidth - $ui.c0.Width - $ui.c2.Width - 34; if ($w -gt 120) { $ui.c1.Width = $w } })

# ---- Animation zwischen den Ordnern
$script:motion = [System.Windows.SystemParameters]::ClientAreaAnimation   # in Windows abgeschaltete Animationen respektieren
function New-Anim([double]$from, [double]$to, [int]$ms) {
    return (New-Object System.Windows.Media.Animation.DoubleAnimation($from, $to, [System.Windows.Duration][TimeSpan]::FromMilliseconds($ms)))
}
function Set-Opacity($el, [double]$to) {
    if (-not $script:motion) { $el.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null); $el.Opacity = $to; return }
    $el.BeginAnimation([System.Windows.UIElement]::OpacityProperty, (New-Anim $el.Opacity $to 250))
}
function Show-Direction([int]$mode) {
    $two = ($mode -eq 0)
    $ui.l2.X1 = $(if ($two) { 12 } else { 0 }); $ui.l2.X2 = $(if ($two) { 150 } else { 138 })
    $ui.p2.Data = [System.Windows.Media.Geometry]::Parse($(if ($two) { 'M 8,56 L 1,62 L 8,68' } else { 'M 142,56 L 149,62 L 142,68' }))
}
function Start-Flow([int]$mode, [bool]$preview) {
    Set-Opacity $ui.done 0
    if (-not $script:motion) { return }
    $ui.lane.Children.Clear()
    foreach ($i in 0..9) {
        $e = New-Object System.Windows.Shapes.Ellipse; $e.Width = 9; $e.Height = 9; $e.Opacity = 0
        $e.Fill = $(if ($preview) { $script:br.Muted } else { $script:br.Accent })
        [System.Windows.Controls.Canvas]::SetTop($e, $(if ($i % 2) { 57.5 } else { 23.5 }))
        [void]$ui.lane.Children.Add($e)
        $back = ($mode -eq 0 -and $i % 2)
        $x = New-Anim $(if ($back) { 141 } else { 0 }) $(if ($back) { 0 } else { 141 }) 1500
        $x.EasingFunction = New-Object System.Windows.Media.Animation.SineEase -Property @{ EasingMode = 'EaseInOut' }
        $o = New-Object System.Windows.Media.Animation.DoubleAnimationUsingKeyFrames; $o.Duration = $x.Duration
        foreach ($kf in @(0, 0), @(0.2, 1), @(0.8, 1), @(1, 0)) { [void]$o.KeyFrames.Add((New-Object System.Windows.Media.Animation.LinearDoubleKeyFrame($kf[1], [System.Windows.Media.Animation.KeyTime]::FromPercent($kf[0])))) }
        foreach ($a in $x, $o) { $a.BeginTime = [TimeSpan]::FromMilliseconds(150 * $i); $a.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever }
        $e.BeginAnimation([System.Windows.Controls.Canvas]::LeftProperty, $x)
        $e.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $o)
    }
    Set-Opacity $ui.lane 1
    $ui.shine.Visibility = 'Visible'
    $s = New-Anim -90 900 1800; $s.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
    $ui.shine.BeginAnimation([System.Windows.Controls.Canvas]::LeftProperty, $s)
}
# $result: ok, err, cancel oder '' (nichts zeigen)
function Stop-Flow([string]$result) {
    Set-Opacity $ui.lane 0
    $ui.lane.Children.Clear()   # beendet alle Punkt-Animationen
    $ui.shine.BeginAnimation([System.Windows.Controls.Canvas]::LeftProperty, $null); $ui.shine.Visibility = 'Collapsed'
    if (-not $result) { return }
    $ui.doneBg.Fill = switch ($result) { 'ok' { $script:br.Ok } 'err' { $script:br.Err } default { $script:br.Muted } }
    $ui.donePath.Stroke = $script:br.Bg
    $ui.donePath.Data = [System.Windows.Media.Geometry]::Parse($(switch ($result) { 'ok' { 'M 18,33 L 28,43 L 46,23' } 'err' { 'M 22,22 L 42,42 M 42,22 L 22,42' } default { 'M 20,32 L 44,32' } }))
    $dash = [System.Windows.Shapes.Shape]::StrokeDashOffsetProperty
    if (-not $script:motion) { $ui.donePath.StrokeDashOffset = 0; Set-Opacity $ui.done 1; return }
    Set-Opacity $ui.done 1
    $sc = New-Anim 0.6 1 350; $sc.EasingFunction = New-Object System.Windows.Media.Animation.BackEase -Property @{ EasingMode = 'EaseOut'; Amplitude = 0.5 }
    $ui.doneScale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleXProperty, $sc)
    $ui.doneScale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleYProperty, $sc)
    $d = New-Anim 14 0 450; $d.BeginTime = [TimeSpan]::FromMilliseconds(200)
    $ui.donePath.BeginAnimation($dash, $d)
}

