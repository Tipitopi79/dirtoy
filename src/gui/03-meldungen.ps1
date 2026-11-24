# ---- Klassen, Stile und Dialog-Grundlage (WPF)
if (-not ('DirToyRow' -as [type])) {
    Add-Type -ReferencedAssemblies PresentationCore, PresentationFramework, WindowsBase, System.Xaml, System.Windows.Forms -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Windows.Media;
public class DirToyItem : INotifyPropertyChanged {
    public event PropertyChangedEventHandler PropertyChanged;
    protected void Raise(string n) { if (PropertyChanged != null) PropertyChanged(this, new PropertyChangedEventArgs(n)); }
}
public class DirToyRow : DirToyItem {
    string st; Brush br;
    public string Icon { get; set; } public Brush IconBrush { get; set; }
    public string Aktion { get; set; } public string Datei { get; set; } public string Task { get; set; } public string File { get; set; }
    public string Status { get { return st; } set { st = value; Raise("Status"); } }
    public Brush StatusBrush { get { return br; } set { br = value; Raise("StatusBrush"); } }
}
public class DirToyTask : DirToyItem {
    string n, s; Brush d;
    public string Id { get; set; }
    public string Name { get { return n; } set { n = value; Raise("Name"); } }
    public string Sub { get { return s; } set { s = value; Raise("Sub"); } }
    public Brush Dot { get { return d; } set { d = value; Raise("Dot"); } }
    public override string ToString() { return n; }
}
public class DirToyNode : DirToyItem {
    bool c; Brush b;
    public DirToyNode() { Nodes = new System.Collections.ObjectModel.ObservableCollection<DirToyNode>(); }
    public string Text { get; set; } public string Path { get; set; } public string Kind { get; set; } public string Root { get; set; } public bool Loaded { get; set; }
    public System.Collections.ObjectModel.ObservableCollection<DirToyNode> Nodes { get; set; }
    public bool Checked { get { return c; } set { c = value; Raise("Checked"); } }
    public Brush Brush { get { return b; } set { b = value; Raise("Brush"); } }
}
public class DirToyOwner : System.Windows.Forms.IWin32Window {
    public IntPtr H; public IntPtr Handle { get { return H; } }
}
'@
}
$script:styles = @'
    <sys:Double x:Key="{x:Static SystemParameters.VerticalScrollBarButtonHeightKey}">72</sys:Double>
    <Style x:Key="Icon" TargetType="TextBlock">
      <Setter Property="FontFamily" Value="Segoe MDL2 Assets"/><Setter Property="VerticalAlignment" Value="Center"/><Setter Property="FontSize" Value="15"/><Setter Property="TextOptions.TextRenderingMode" Value="Grayscale"/>
    </Style>
    <Style x:Key="MutedText" TargetType="TextBlock"><Setter Property="Foreground" Value="{DynamicResource Muted}"/><Setter Property="FontSize" Value="12"/></Style>
    <Style TargetType="Button">
      <Setter Property="Foreground" Value="{DynamicResource Text}"/><Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderBrush" Value="{DynamicResource Border}"/><Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="16,0"/><Setter Property="Height" Value="38"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
        <Grid>
          <Border x:Name="b" CornerRadius="8" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}"/>
          <Border x:Name="h" CornerRadius="8" Background="{DynamicResource Text}" Opacity="0"/>
          <ContentPresenter Margin="{TemplateBinding Padding}" HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}" VerticalAlignment="Center" RecognizesAccessKey="False"/>
        </Grid>
        <ControlTemplate.Triggers>
          <Trigger Property="IsMouseOver" Value="True">
            <Trigger.EnterActions><BeginStoryboard><Storyboard><DoubleAnimation Storyboard.TargetName="h" Storyboard.TargetProperty="Opacity" To="0.10" Duration="0:0:0.12"/></Storyboard></BeginStoryboard></Trigger.EnterActions>
            <Trigger.ExitActions><BeginStoryboard><Storyboard><DoubleAnimation Storyboard.TargetName="h" Storyboard.TargetProperty="Opacity" To="0" Duration="0:0:0.2"/></Storyboard></BeginStoryboard></Trigger.ExitActions>
          </Trigger>
          <Trigger Property="IsPressed" Value="True"><Setter TargetName="b" Property="Opacity" Value="0.75"/></Trigger>
          <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.45"/><Setter Property="Cursor" Value="Arrow"/></Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style x:Key="Primary" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
      <Setter Property="Background" Value="{DynamicResource Accent}"/><Setter Property="Foreground" Value="{DynamicResource AccentText}"/>
      <Setter Property="BorderThickness" Value="0"/><Setter Property="FontWeight" Value="SemiBold"/>
    </Style>
    <Style x:Key="Ghost" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
      <Setter Property="BorderThickness" Value="0"/><Setter Property="Padding" Value="10,0"/><Setter Property="HorizontalContentAlignment" Value="Left"/>
    </Style>
    <Style TargetType="TextBox">
      <Setter Property="Background" Value="{DynamicResource Input}"/><Setter Property="Foreground" Value="{DynamicResource Text}"/><Setter Property="CaretBrush" Value="{DynamicResource Text}"/>
      <Setter Property="BorderBrush" Value="{DynamicResource Border}"/><Setter Property="Height" Value="34"/><Setter Property="SelectionBrush" Value="{DynamicResource Accent}"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/><Setter Property="Padding" Value="4,0"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="TextBox">
        <Border x:Name="b" CornerRadius="8" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1">
          <ScrollViewer x:Name="PART_ContentHost" Margin="{TemplateBinding Padding}" VerticalAlignment="Center"/></Border>
        <ControlTemplate.Triggers>
          <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="b" Property="BorderBrush" Value="{DynamicResource Accent}"/></Trigger>
          <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.5"/></Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style x:Key="Seg" TargetType="RadioButton">
      <Setter Property="Foreground" Value="{DynamicResource Text}"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="RadioButton">
        <Border x:Name="b" CornerRadius="6" Background="Transparent" Padding="14,0" Height="30" Margin="3">
          <ContentPresenter VerticalAlignment="Center" HorizontalAlignment="Center"/></Border>
        <ControlTemplate.Triggers>
          <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="{DynamicResource SelBg}"/></Trigger>
          <Trigger Property="IsChecked" Value="True"><Setter TargetName="b" Property="Background" Value="{DynamicResource Accent}"/><Setter Property="Foreground" Value="{DynamicResource AccentText}"/></Trigger>
          <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.5"/></Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style TargetType="ScrollBar">
      <Setter Property="Background" Value="Transparent"/><Setter Property="Width" Value="10"/><Setter Property="MinWidth" Value="10"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ScrollBar">
        <Track x:Name="PART_Track" Orientation="Vertical" IsDirectionReversed="True"><Track.Thumb><Thumb MinHeight="36"><Thumb.Template><ControlTemplate TargetType="Thumb">
          <Border CornerRadius="4" Margin="2" Background="{DynamicResource Border}"/></ControlTemplate></Thumb.Template></Thumb></Track.Thumb></Track>
      </ControlTemplate></Setter.Value></Setter>
      <Style.Triggers><Trigger Property="Orientation" Value="Horizontal"><Setter Property="Width" Value="Auto"/><Setter Property="Height" Value="10"/>
        <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ScrollBar">
          <Track x:Name="PART_Track"><Track.Thumb><Thumb MinWidth="36"><Thumb.Template><ControlTemplate TargetType="Thumb"><Border CornerRadius="4" Margin="2" Background="{DynamicResource Border}"/></ControlTemplate></Thumb.Template></Thumb></Track.Thumb></Track>
        </ControlTemplate></Setter.Value></Setter></Trigger></Style.Triggers>
    </Style>
    <Style TargetType="ToolTip"><Setter Property="Background" Value="{DynamicResource Surface}"/><Setter Property="Foreground" Value="{DynamicResource Text}"/><Setter Property="BorderBrush" Value="{DynamicResource Border}"/></Style>
    <Style x:Key="PlainList" TargetType="ListBox">
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ListBox"><Grid x:Name="g"><ScrollViewer Focusable="False"><ItemsPresenter/></ScrollViewer></Grid>
        <ControlTemplate.Triggers><Trigger Property="IsEnabled" Value="False"><Setter TargetName="g" Property="Opacity" Value="0.6"/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style TargetType="ListBoxItem">
      <Setter Property="Foreground" Value="{DynamicResource Text}"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ListBoxItem">
        <Border x:Name="b" CornerRadius="8" Padding="12,9" Margin="0,1" Background="Transparent"><ContentPresenter/></Border>
        <ControlTemplate.Triggers>
          <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="{DynamicResource SelBg}"/></Trigger>
          <Trigger Property="IsSelected" Value="True"><Setter TargetName="b" Property="Background" Value="{DynamicResource SelBg}"/></Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style TargetType="ListViewItem">
      <Setter Property="HorizontalContentAlignment" Value="Stretch"/><Setter Property="Foreground" Value="{DynamicResource Text}"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ListViewItem">
        <Border x:Name="b" Background="Transparent" Padding="6,5" BorderBrush="{DynamicResource Border}" BorderThickness="0,0,0,0.5"><GridViewRowPresenter VerticalAlignment="Center"/></Border>
        <ControlTemplate.Triggers>
          <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="{DynamicResource Hover}"/></Trigger>
          <Trigger Property="IsSelected" Value="True"><Setter TargetName="b" Property="Background" Value="{DynamicResource SelBg}"/></Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style TargetType="GridViewColumnHeader">
      <Setter Property="Foreground" Value="{DynamicResource Muted}"/><Setter Property="FontSize" Value="12"/><Setter Property="HorizontalContentAlignment" Value="Left"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="GridViewColumnHeader">
        <Border Background="Transparent" Padding="12,7"><ContentPresenter/></Border></ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style TargetType="CheckBox">
      <Setter Property="Foreground" Value="{DynamicResource Text}"/><Setter Property="Cursor" Value="Hand"/><Setter Property="VerticalContentAlignment" Value="Center"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="CheckBox">
        <StackPanel Orientation="Horizontal" Background="Transparent">
          <Border x:Name="b" Width="18" Height="18" CornerRadius="4" BorderThickness="1.5" BorderBrush="{DynamicResource Muted}" Background="{DynamicResource Input}" VerticalAlignment="Center"><TextBlock x:Name="t" Text="&#xE73E;" FontFamily="Segoe MDL2 Assets" FontSize="12" Foreground="{DynamicResource AccentText}" HorizontalAlignment="Center" VerticalAlignment="Center" Visibility="Hidden"/></Border>
          <ContentPresenter Margin="8,0,0,0" VerticalAlignment="Center"/></StackPanel>
        <ControlTemplate.Triggers>
          <Trigger Property="IsChecked" Value="True"><Setter TargetName="t" Property="Visibility" Value="Visible"/><Setter TargetName="b" Property="Background" Value="{DynamicResource Accent}"/><Setter TargetName="b" Property="BorderBrush" Value="{DynamicResource Accent}"/></Trigger>
          <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.45"/></Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style x:Key="Chip" TargetType="CheckBox">
      <Setter Property="Foreground" Value="{DynamicResource Text}"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="CheckBox">
        <Border x:Name="b" CornerRadius="8" Width="50" Height="34" Margin="0,0,8,0" Background="{DynamicResource Input}" BorderBrush="{DynamicResource Border}" BorderThickness="1"><ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>
        <ControlTemplate.Triggers><Trigger Property="IsChecked" Value="True"><Setter TargetName="b" Property="Background" Value="{DynamicResource Accent}"/><Setter Property="Foreground" Value="{DynamicResource AccentText}"/></Trigger></ControlTemplate.Triggers>
      </ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style TargetType="RadioButton">
      <Setter Property="Foreground" Value="{DynamicResource Text}"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="RadioButton">
        <StackPanel Orientation="Horizontal" Background="Transparent"><Grid Width="18" Height="18"><Ellipse x:Name="o" Stroke="{DynamicResource Muted}" StrokeThickness="1.5" Fill="{DynamicResource Input}"/><Ellipse x:Name="i" Width="8" Height="8" Fill="{DynamicResource Accent}" Visibility="Hidden"/></Grid><ContentPresenter Margin="8,0,0,0" VerticalAlignment="Center"/></StackPanel>
        <ControlTemplate.Triggers><Trigger Property="IsChecked" Value="True"><Setter TargetName="i" Property="Visibility" Value="Visible"/><Setter TargetName="o" Property="Stroke" Value="{DynamicResource Accent}"/></Trigger></ControlTemplate.Triggers>
      </ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style x:Key="Multi" TargetType="TextBox" BasedOn="{StaticResource {x:Type TextBox}}">
      <Setter Property="Height" Value="Auto"/><Setter Property="VerticalContentAlignment" Value="Top"/><Setter Property="Padding" Value="8"/><Setter Property="IsReadOnly" Value="True"/><Setter Property="TextWrapping" Value="Wrap"/><Setter Property="VerticalScrollBarVisibility" Value="Auto"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="TextBox"><Border CornerRadius="8" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1"><ScrollViewer x:Name="PART_ContentHost" Margin="{TemplateBinding Padding}"/></Border></ControlTemplate></Setter.Value></Setter>
    </Style>
    <Style TargetType="TreeViewItem">
      <Setter Property="Foreground" Value="{DynamicResource Text}"/>
      <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="TreeViewItem">
        <StackPanel><StackPanel Orientation="Horizontal" Margin="0,3">
          <ToggleButton x:Name="e" IsChecked="{Binding IsExpanded, RelativeSource={RelativeSource TemplatedParent}, Mode=TwoWay}" ClickMode="Press" Width="22" Focusable="False"><ToggleButton.Template><ControlTemplate TargetType="ToggleButton"><Border Background="Transparent"><TextBlock x:Name="t" Text="&#xE76C;" FontFamily="Segoe MDL2 Assets" FontSize="10" Foreground="{DynamicResource Muted}" HorizontalAlignment="Center" VerticalAlignment="Center"/></Border><ControlTemplate.Triggers><Trigger Property="IsChecked" Value="True"><Setter TargetName="t" Property="Text" Value="&#xE70D;"/></Trigger></ControlTemplate.Triggers></ControlTemplate></ToggleButton.Template></ToggleButton>
          <ContentPresenter ContentSource="Header"/></StackPanel>
          <ItemsPresenter x:Name="c" Margin="20,0,0,0" Visibility="Collapsed"/></StackPanel>
        <ControlTemplate.Triggers><Trigger Property="IsExpanded" Value="True"><Setter TargetName="c" Property="Visibility" Value="Visible"/></Trigger><Trigger Property="HasItems" Value="False"><Setter TargetName="e" Property="Visibility" Value="Hidden"/></Trigger></ControlTemplate.Triggers>
      </ControlTemplate></Setter.Value></Setter>
    </Style>
'@
try {
    Add-Type -Namespace Win32 -Name Dwm -MemberDefinition '[System.Runtime.InteropServices.DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(System.IntPtr hwnd, int attr, ref int val, int size);'
} catch { }
# Farben des Designs
$script:br = @{}
foreach ($k in $th.Keys) { $c = $th[$k]; $script:br[$k] = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromRgb($c.R, $c.G, $c.B)) }
$script:br['Hover'] = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromArgb(14, $th.Text.R, $th.Text.G, $th.Text.B))
$script:br['Warn'] = [System.Windows.Media.SolidColorBrush]::new($(if ($isDark) { [System.Windows.Media.Color]::FromRgb(0xFF, 0xB9, 0x00) } else { [System.Windows.Media.Color]::FromRgb(0x9D, 0x5D, 0x00) }))
foreach ($b in $script:br.Values) { $b.Freeze() }
function Set-Brushes($w) { foreach ($k in $script:br.Keys) { $w.Resources[$k] = $script:br[$k] } }
function Set-DarkTitle($w) {
    $w.Add_SourceInitialized({
        try { $v = if ($isDark) { 1 } else { 0 }; [void][Win32.Dwm]::DwmSetWindowAttribute((New-Object System.Windows.Interop.WindowInteropHelper $this).Handle, 20, [ref]$v, 4) } catch { }
    })
}
$script:winStack = New-Object System.Collections.ArrayList   # offene Dialoge, der oberste ist Besitzer des naechsten
# Baut einen Dialog; Rueckgabe: Tabelle mit Win und allen benannten Elementen. $size: z. B. 'Width="520" SizeToContent="Height" ResizeMode="NoResize"'
function New-Dlg([string]$title, [string]$size, [string]$body) {
    $x = '<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" xmlns:sys="clr-namespace:System;assembly=mscorlib" ' + $size +
        ' ShowInTaskbar="False" FontFamily="Segoe UI" FontSize="14" Background="{DynamicResource Bg}" Foreground="{DynamicResource Text}" UseLayoutRounding="True" TextOptions.TextFormattingMode="Display"><Window.Resources>' + $script:styles + '</Window.Resources>' + $body + '</Window>'
    $w = [System.Windows.Markup.XamlReader]::Parse($x)
    $w.Title = $title
    if ($script:win.Icon) { $w.Icon = $script:win.Icon }
    Set-Brushes $w; Set-DarkTitle $w
    $r = @{ Win = $w; Result = '' }
    foreach ($m in [regex]::Matches($body, 'x:Name="(\w+)"')) { $n = $m.Groups[1].Value; $e = $w.FindName($n); if ($e) { $r[$n] = $e } }
    return $r
}
function Show-Dlg($dlg) {
    $o = if ($script:winStack.Count) { $script:winStack[$script:winStack.Count - 1] } else { $script:win }
    if ($o -and $o.IsVisible) { $dlg.Win.Owner = $o; $dlg.Win.WindowStartupLocation = 'CenterOwner' } else { $dlg.Win.WindowStartupLocation = 'CenterScreen' }
    [void]$script:winStack.Add($dlg.Win)
    try { [void]$dlg.Win.ShowDialog() } finally { $script:winStack.Remove($dlg.Win) }
}
# ---- Meldungen (wie MessageBox): OK oder YesNo, Rueckgabe 'OK', 'Yes' oder 'No'. Esc/Schliessen = Nein
function Show-Msg([string]$text, [string]$title = 'DirToy', [string]$buttons = 'OK', [string]$icon = 'Information', [string]$default = 'Button1') {
    $yn = ($buttons -eq 'YesNo'); $no2 = ($yn -and $default -eq 'Button2')
    $btns = if ($yn) {
        '<Button x:Name="yes" Width="116" Margin="0,0,8,0" ' + $(if ($no2) { '' } else { 'IsDefault="True" Style="{StaticResource Primary}"' }) + '>Ja</Button><Button x:Name="no" Width="116" IsCancel="True" ' + $(if ($no2) { 'IsDefault="True" Style="{StaticResource Primary}"' } else { '' }) + '>Nein</Button>'
    } else { '<Button x:Name="no" Width="116" IsCancel="True" IsDefault="True" Style="{StaticResource Primary}">OK</Button>' }
    $g = switch ($icon) { 'Warning' { @('E7BA', 'Warn') } 'Error' { @('EA39', 'Err') } 'Question' { @('E897', 'Accent') } default { @('E946', 'Accent') } }
    $dlg = New-Dlg $title 'Width="540" SizeToContent="Height" MaxHeight="640" ResizeMode="NoResize"' ('<DockPanel Margin="24"><StackPanel DockPanel.Dock="Bottom" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,24,0,0">' + $btns + '</StackPanel>' +
        '<TextBlock DockPanel.Dock="Left" Text="&#x' + $g[0] + ';" Style="{StaticResource Icon}" FontSize="36" Foreground="{DynamicResource ' + $g[1] + '}" VerticalAlignment="Top" Margin="0,2,20,0"/>' +
        '<ScrollViewer VerticalScrollBarVisibility="Auto"><TextBlock x:Name="msgText" TextWrapping="Wrap" LineHeight="21"/></ScrollViewer></DockPanel>')
    $dlg.msgText.Text = $text
    $script:msgDlg = $dlg
    if ($yn) { $dlg.yes.Add_Click({ $script:msgDlg.Result = 'Yes'; $script:msgDlg.Win.Close() }) }
    $dlg.no.Add_Click({ $script:msgDlg.Win.Close() })
    [void]$(if ($yn -and -not $no2) { $dlg.yes } else { $dlg.no }).Focus()
    if ($icon -eq 'Warning' -or $icon -eq 'Error') { [System.Media.SystemSounds]::Exclamation.Play() }
    Show-Dlg $dlg
    if (-not $yn) { return 'OK' }
    if ($dlg.Result -eq 'Yes') { return 'Yes' }
    return 'No'
}

