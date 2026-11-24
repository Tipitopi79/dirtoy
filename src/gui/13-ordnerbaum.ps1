# ---- Ordnerbaum-Fenster: Ordner abwaehlen, die nicht synchronisiert werden sollen
function Get-ParentPath([string]$p) {
    $x = $p.TrimEnd('\'); $i = $x.LastIndexOf('\')
    if ($i -lt 0) { return '' } else { return $x.Substring(0, $i + 1) }
}
function Test-ExistsAny([string]$rel) {
    return ([System.IO.Directory]::Exists((Join-Path $script:fdRootA $rel)) -or [System.IO.Directory]::Exists((Join-Path $script:fdRootB $rel)))
}
function Test-EffExcluded([string]$path) {
    foreach ($x in $script:fdSet) { if ($path.StartsWith($x, [StringComparison]::OrdinalIgnoreCase)) { return $true } }
    return $false
}
function Test-AncExcluded([string]$path) {
    foreach ($x in $script:fdSet) { if ($path.Length -gt $x.Length -and $path.StartsWith($x, [StringComparison]::OrdinalIgnoreCase)) { return $true } }
    return $false
}
function New-TreeNodeFor([string]$text, [string]$path, [string]$kind, [string]$root) {
    $n = [DirToyNode]::new(); $n.Text = $text; $n.Path = $path; $n.Kind = $kind; $n.Root = $root; $n.Loaded = ($kind -ne 'normal')
    if ($kind -eq 'normal') { $x = [DirToyNode]::new(); $x.Text = '...'; $x.Kind = 'dummy'; $x.Loaded = $true; $n.Nodes.Add($x) }   # Platzhalter fuer Pfeil
    return $n
}
function Fill-Nodes($coll, [string]$parentPath, [string]$root) {
    $coll.Clear()
    $abs = Join-Path $root $parentPath
    try { $dirs = @((New-Object System.IO.DirectoryInfo $abs).GetDirectories() | Sort-Object Name) } catch { $dirs = @() }
    foreach ($d in $dirs) {
        if ($d.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { continue }
        $p = $parentPath + $d.Name + '\'
        if (Test-Excluded $d.Name $script:fdPats) { $coll.Add((New-TreeNodeFor ($d.Name + '   (durch Muster ausgeschlossen)') $p 'pattern' $root)) }
        else { $coll.Add((New-TreeNodeFor $d.Name $p 'normal' $root)) }
    }
    # abgewaehlte Ordner, die es nirgends mehr gibt
    foreach ($x in @($script:fdSet | Sort-Object)) {
        if (Test-ExistsAny $x) { continue }
        $par = Get-ParentPath $x
        $orphan = ($par -ne '') -and -not (Test-ExistsAny $par)
        if ($parentPath -eq '' -and $orphan) { $coll.Add((New-TreeNodeFor ($x.TrimEnd('\') + '   (nicht vorhanden)') $x 'missing' $root)) }
        elseif ($par -eq $parentPath -and -not $orphan) {
            $name = $x.TrimEnd('\').Substring($par.Length)
            $coll.Add((New-TreeNodeFor ($name + '   (nicht vorhanden)') $x 'missing' $root))
        }
    }
}
function Update-TreeChecks($nodes) {
    foreach ($n in $nodes) {
        if ($n.Kind -eq 'dummy') { continue }
        $excl = ($n.Kind -ne 'normal') -or (Test-EffExcluded $n.Path)
        $n.Checked = -not $excl
        $n.Brush = $(if ($excl) { $script:br.Muted } else { $script:br.Text })
        if ($n.Loaded -and $n.Nodes.Count -gt 0) { Update-TreeChecks $n.Nodes }
    }
}
function Refresh-Trees {
    foreach ($c in @($script:fdA, $script:fdB)) { Update-TreeChecks $c }
    $script:fdDlg.count.Text = "$($script:fdSet.Count) Ordner abgewählt"
}
function Remove-MissingIn($coll, [string]$path) {
    for ($i = $coll.Count - 1; $i -ge 0; $i--) {
        $n = $coll[$i]
        if ($n.Kind -eq 'missing' -and $n.Path -ieq $path) { $coll.RemoveAt($i) }
        elseif ($n.Loaded -and $n.Nodes.Count -gt 0) { Remove-MissingIn $n.Nodes $path }
    }
}
function Show-FolderDialog($t) {
    try {
        $script:fdRootA = [System.IO.Path]::GetFullPath([string]$t.A).TrimEnd('\')
        $script:fdRootB = [System.IO.Path]::GetFullPath([string]$t.B).TrimEnd('\')
    } catch { $script:fdRootA = ''; $script:fdRootB = '' }
    if (-not $t.A -or -not $t.B -or -not (Test-Path -LiteralPath $script:fdRootA -PathType Container) -or -not (Test-Path -LiteralPath $script:fdRootB -PathType Container)) {
        [void](Show-Msg ('Bitte zuerst Ordner A und Ordner B angeben (beide müssen existieren).') 'Ordner wählen')
        return
    }
    $script:fdTask = $t
    $script:fdPats = Get-Patterns $t
    $script:fdSet = Get-ExcludeDirs $t
    $tree = '<TreeView x:Name="{0}" Background="Transparent" BorderThickness="0" AutomationProperties.Name="{1}"><TreeView.ItemTemplate><HierarchicalDataTemplate ItemsSource="{{Binding Nodes}}"><CheckBox IsChecked="{{Binding Checked, Mode=TwoWay}}" AutomationProperties.Name="{{Binding Text}}"><TextBlock Text="{{Binding Text}}" Foreground="{{Binding Brush}}"/></CheckBox></HierarchicalDataTemplate></TreeView.ItemTemplate></TreeView>'
    $dlg = New-Dlg 'Ordner auswählen' 'Width="1020" Height="720" MinWidth="700" MinHeight="460"' ('<DockPanel Margin="24">
      <TextBlock DockPanel.Dock="Top" Text="Ordner auswählen" FontSize="20" FontWeight="SemiBold"/>
      <TextBlock DockPanel.Dock="Top" Style="{StaticResource MutedText}" TextWrapping="Wrap" Margin="0,4,0,14" Text="Haken entfernen = Ordner samt Unterordnern wird nicht synchronisiert. Neue Ordner sind standardmäßig dabei (Haken gesetzt)."/>
      <DockPanel DockPanel.Dock="Bottom" Margin="0,14,0,0" LastChildFill="False"><Button x:Name="all">Alle wieder einschließen</Button><TextBlock x:Name="count" Style="{StaticResource MutedText}" VerticalAlignment="Center" Margin="14,0"/><Button x:Name="cancel" DockPanel.Dock="Right" IsCancel="True">Abbrechen</Button><Button x:Name="ok" DockPanel.Dock="Right" Style="{StaticResource Primary}" IsDefault="True" MinWidth="100" Margin="0,0,8,0">OK</Button></DockPanel>
      <TextBlock x:Name="hint" DockPanel.Dock="Bottom" Style="{StaticResource MutedText}" Foreground="{DynamicResource Warn}" Margin="0,10,0,0"/>
      <Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="16"/><ColumnDefinition/></Grid.ColumnDefinitions>
        <Border Background="{DynamicResource Surface}" CornerRadius="12" Padding="12"><DockPanel><TextBlock x:Name="la" DockPanel.Dock="Top" Style="{StaticResource MutedText}" TextTrimming="CharacterEllipsis" Margin="4,0,0,8"/>' + ($tree -f 'tvA', 'Ordner A') + '</DockPanel></Border>
        <Border Grid.Column="2" Background="{DynamicResource Surface}" CornerRadius="12" Padding="12"><DockPanel><TextBlock x:Name="lb" DockPanel.Dock="Top" Style="{StaticResource MutedText}" TextTrimming="CharacterEllipsis" Margin="4,0,0,8"/>' + ($tree -f 'tvB', 'Ordner B') + '</DockPanel></Border></Grid></DockPanel>')
    $script:fdDlg = $dlg
    $dlg.la.Text = 'A:  ' + $script:fdRootA; $dlg.lb.Text = 'B:  ' + $script:fdRootB
    $script:fdA = [System.Collections.ObjectModel.ObservableCollection[DirToyNode]]::new()
    $script:fdB = [System.Collections.ObjectModel.ObservableCollection[DirToyNode]]::new()
    $dlg.tvA.ItemsSource = $script:fdA; $dlg.tvB.ItemsSource = $script:fdB
    $expand = [System.Windows.RoutedEventHandler] {
        param($s, $e)
        $n = $e.OriginalSource.DataContext
        if ($n -is [DirToyNode] -and -not $n.Loaded) { $n.Loaded = $true; Fill-Nodes $n.Nodes $n.Path $n.Root; Refresh-Trees }
    }
    $checked = [System.Windows.RoutedEventHandler] {
        param($s, $e)
        if ($e.OriginalSource -isnot [System.Windows.Controls.CheckBox]) { return }
        $n = $e.OriginalSource.DataContext
        if ($n -isnot [DirToyNode] -or $n.Kind -eq 'dummy') { return }
        # kam die Aenderung aus dem Baum selbst (Haken passt schon zur Auswahl)? Dann nichts tun
        if ($n.Checked -eq ($n.Kind -eq 'normal' -and -not (Test-EffExcluded $n.Path))) { return }
        $script:fdDlg.hint.Text = ''
        if ($n.Kind -eq 'pattern') { $n.Checked = $false; $script:fdDlg.hint.Text = 'Dieser Ordner ist durch ein Muster im Ausschlussfeld ausgeschlossen.'; return }
        if ($n.Checked -and (Test-AncExcluded $n.Path)) { $n.Checked = $false; $script:fdDlg.hint.Text = 'Ein übergeordneter Ordner ist abgewählt. Dort zuerst den Haken wieder setzen.'; return }
        if ($n.Checked) {
            [void]$script:fdSet.Remove($n.Path)
            if ($n.Kind -eq 'missing') { Remove-MissingIn $script:fdA $n.Path; Remove-MissingIn $script:fdB $n.Path }
        } else { [void]$script:fdSet.Add($n.Path) }
        Refresh-Trees
    }
    foreach ($tv in $dlg.tvA, $dlg.tvB) {
        $tv.AddHandler([System.Windows.Controls.TreeViewItem]::ExpandedEvent, $expand)
        $tv.AddHandler([System.Windows.Controls.Primitives.ToggleButton]::CheckedEvent, $checked)
        $tv.AddHandler([System.Windows.Controls.Primitives.ToggleButton]::UncheckedEvent, $checked)
    }
    $dlg.all.Add_Click({
        $script:fdSet.Clear()
        Fill-Nodes $script:fdA '' $script:fdRootA; Fill-Nodes $script:fdB '' $script:fdRootB
        Refresh-Trees
    })
    $dlg.ok.Add_Click({
        $script:fdTask.ExcludeDirs = [string[]]@($script:fdSet | Sort-Object)
        Save-Tasks
        $script:fdDlg.Win.Close()
    })
    $dlg.cancel.Add_Click({ $script:fdDlg.Win.Close() })
    Fill-Nodes $script:fdA '' $script:fdRootA
    Fill-Nodes $script:fdB '' $script:fdRootB
    Refresh-Trees
    Show-Dlg $dlg
}
