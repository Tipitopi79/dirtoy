# Prototyp fuer 2.0: WPF-Fenster, Sync im eigenen Thread (Runspace), Kern unveraendert aus DirToy.ps1.
# Arbeitet nur mit eigenen Testdateien im Temp-Ordner.
#   powershell -NoProfile -ExecutionPolicy Bypass -STA -File prototyp\prototyp.ps1          zum Ansehen
#   ... -Auto -Bild <png>                                                                    misst und beendet sich
param([switch]$Auto, [string]$Bild, [int]$Klein = 1500, [int]$GrossMB = 250)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
$kern = Join-Path (Split-Path $PSScriptRoot) 'DirToy.ps1'
$base = Join-Path ([IO.Path]::GetTempPath()) ('dirtoy-proto-' + [guid]::NewGuid().ToString('N'))
$env:DIRTOY_DATA = Join-Path $base 'daten'
[void][IO.Directory]::CreateDirectory($env:DIRTOY_DATA)

# Misst die Abstaende zwischen gezeichneten Bildern (in C#, damit das Messen selbst nicht bremst)
Add-Type -ReferencedAssemblies PresentationCore, WindowsBase -TypeDefinition @'
using System; using System.Collections.Generic; using System.Diagnostics; using System.Windows.Media;
public static class Bilder {
    static List<double> g = new List<double>(); static TimeSpan last; static Stopwatch sw = Stopwatch.StartNew(); static double prev = -1; static bool on;
    public static void Start() { g.Clear(); prev = -1; if (!on) { CompositionTarget.Rendering += Tick; on = true; } }
    static void Tick(object s, EventArgs e) {
        TimeSpan t = ((RenderingEventArgs)e).RenderingTime; if (t == last) return; last = t;
        double n = sw.Elapsed.TotalMilliseconds; if (prev >= 0) g.Add(n - prev); prev = n;
    }
    public static string Ergebnis() {
        if (g.Count == 0) return "keine Bilder";
        List<double> s = new List<double>(g); s.Sort(); double sum = 0; int lang = 0;
        foreach (double d in s) { sum += d; if (d > 100) lang++; }
        return String.Format("{0:0.0} s, {1:0} Bilder/s, 99% unter {2:0} ms, laengste Pause {3:0} ms, Pausen ueber 100 ms: {4}", sum / 1000, 1000 * s.Count / sum, s[(int)(s.Count * 0.99)], s[s.Count - 1], lang);
    }
}
'@

function New-Daten {
    $a = Join-Path $base 'A'; [void][IO.Directory]::CreateDirectory($a)
    $buf = New-Object byte[] (20KB); (New-Object Random 1).NextBytes($buf)
    for ($i = 0; $i -lt $Klein; $i++) { $d = "$a\ordner$($i % 20)"; [void][IO.Directory]::CreateDirectory($d); [IO.File]::WriteAllBytes("$d\datei$i.bin", $buf) }
    $mb = New-Object byte[] (1MB); (New-Object Random 2).NextBytes($mb)
    foreach ($n in 1, 2) { $fs = [IO.File]::Create("$a\gross$n.bin"); try { for ($i = 0; $i -lt $GrossMB; $i++) { $fs.Write($mb, 0, $mb.Length) } } finally { $fs.Dispose() } }
}

[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="DirToy 2.0 Prototyp" Width="720" Height="420" Background="#2D2D30" WindowStartupLocation="CenterScreen" FontFamily="Segoe UI" FontSize="14">
  <Grid x:Name="Root" Background="#2D2D30"><Grid Margin="24">
    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
    <TextBlock Text="Testaufgabe" FontSize="24" Foreground="#4CC2FF"/>
    <Grid Grid.Row="1">
      <Grid.ColumnDefinitions><ColumnDefinition Width="170"/><ColumnDefinition Width="*"/><ColumnDefinition Width="170"/></Grid.ColumnDefinitions>
      <Border Background="#3A3A3D" BorderBrush="#5A5A5E" BorderThickness="1" CornerRadius="12" VerticalAlignment="Center" Padding="16">
        <StackPanel><TextBlock Text="&#xE8B7;" FontFamily="Segoe MDL2 Assets" FontSize="40" Foreground="#4CC2FF" HorizontalAlignment="Center"/><TextBlock Text="Ordner A" Foreground="#F2F2F2" HorizontalAlignment="Center" Margin="0,8,0,0"/></StackPanel></Border>
      <Canvas x:Name="Bahn" Grid.Column="1" Height="60" Width="300" VerticalAlignment="Center" Opacity="0"/>
      <TextBlock x:Name="Haken" Grid.Column="1" Text="&#xE73E;" FontFamily="Segoe MDL2 Assets" FontSize="48" Foreground="#6CCB5F" HorizontalAlignment="Center" VerticalAlignment="Center" Opacity="0"/>
      <Border Grid.Column="2" Background="#3A3A3D" BorderBrush="#5A5A5E" BorderThickness="1" CornerRadius="12" VerticalAlignment="Center" Padding="16">
        <StackPanel><TextBlock Text="&#xE8B7;" FontFamily="Segoe MDL2 Assets" FontSize="40" Foreground="#4CC2FF" HorizontalAlignment="Center"/><TextBlock Text="Ordner B" Foreground="#F2F2F2" HorizontalAlignment="Center" Margin="0,8,0,0"/></StackPanel></Border>
    </Grid>
    <Border x:Name="Spur" Grid.Row="2" Height="8" CornerRadius="4" Background="#28282B"><Border x:Name="Balken" HorizontalAlignment="Left" Width="0" CornerRadius="4" Background="#4CC2FF"/></Border>
    <TextBlock x:Name="Status" Grid.Row="3" Text="Bereit" Foreground="#B4B4B4" Margin="0,8,0,16" TextTrimming="CharacterEllipsis"/>
    <StackPanel Grid.Row="4" Orientation="Horizontal"><Button x:Name="Start" Content="Starten" Padding="24,8" Margin="0,0,8,0"/><Button x:Name="Stopp" Content="Abbrechen" Padding="24,8"/></StackPanel>
  </Grid></Grid>
</Window>
'@
$win = [Windows.Markup.XamlReader]::Load((New-Object Xml.XmlNodeReader $xaml))
$ui = @{}; foreach ($n in 'Root', 'Bahn', 'Haken', 'Spur', 'Balken', 'Status', 'Start', 'Stopp') { $ui[$n] = $win.FindName($n) }
foreach ($i in 0..9) {
    $e = New-Object Windows.Shapes.Ellipse; $e.Width = 10; $e.Height = 10; $e.Fill = $ui.Balken.Background
    [Windows.Controls.Canvas]::SetTop($e, $(if ($i % 2) { 38 } else { 12 })); [void]$ui.Bahn.Children.Add($e)
    $x = New-Object Windows.Media.Animation.DoubleAnimation
    if ($i % 2) { $x.From = 290; $x.To = 0 } else { $x.From = 0; $x.To = 290 }
    $x.Duration = [Windows.Duration][TimeSpan]::FromMilliseconds(1400); $x.BeginTime = [TimeSpan]::FromMilliseconds(140 * $i)
    $x.RepeatBehavior = [Windows.Media.Animation.RepeatBehavior]::Forever
    $x.EasingFunction = New-Object Windows.Media.Animation.SineEase -Property @{ EasingMode = 'EaseInOut' }
    $e.BeginAnimation([Windows.Controls.Canvas]::LeftProperty, $x)
}
function Set-Fade($el, [double]$to) {
    $f = New-Object Windows.Media.Animation.DoubleAnimation; $f.To = $to; $f.Duration = [Windows.Duration][TimeSpan]::FromMilliseconds(300)
    $el.BeginAnimation([Windows.UIElement]::OpacityProperty, $f)
}

# ---- Sync im eigenen Thread: der Kern meldet nur in $meld, die Oberflaeche holt es ab
$script:meld = $null; $script:job = $null
function Start-Job2([string]$id, [string]$a, [string]$b) {
    $script:meld = [hashtable]::Synchronized(@{ Frac = 0.0; Text = ''; Cancel = $false; Ergebnis = $null; Fehler = '' })
    $rs = [runspacefactory]::CreateRunspace(); $rs.ApartmentState = 'STA'; $rs.ThreadOptions = 'ReuseThread'; $rs.Open()
    $p = [powershell]::Create(); $p.Runspace = $rs
    [void]$p.AddScript({
        param($meld, $kernPfad, $jobId, $jobA, $jobB)
        try {
            . $kernPfad -NoGui
            function Set-Progress([double]$frac) { $meld.Frac = $frac }
            function Add-Log([string]$aktion, [string]$datei, [string]$status) { $meld.Text = "$aktion  $datei"; if ($status -like 'FEHLER*') { $meld.Fehler = $status }; return $null }
            function Pump { if ($meld.Cancel) { $script:cancel = $true } }
            $script:pumpMs = 30
            $jt = New-Task 'Prototyp'; $jt.Id = $jobId; $jt.A = $jobA; $jt.B = $jobB
            $meld.Ergebnis = Run-Task $jt $false
        } catch { $meld.Fehler = [string]$_ }
    }).AddArgument($script:meld).AddArgument($kern).AddArgument($id).AddArgument($a).AddArgument($b)
    $script:job = @{ Ps = $p; Rs = $rs; H = $p.BeginInvoke() }
    $ui.Balken.Width = 0; Set-Fade $ui.Haken 0; Set-Fade $ui.Bahn 1; $ui.Start.IsEnabled = $false
}
function Update-Ui {
    if (-not $script:job) { return }
    $ui.Balken.Width = $ui.Spur.ActualWidth * [math]::Max(0.0, [math]::Min(1.0, $script:meld.Frac))   # 0.0/1.0: mit 0/1 rundet PowerShell auf ganze Zahlen
    $ui.Status.Text = [string]$script:meld.Text
    if ($script:job.H.IsCompleted) {
        try { [void]$script:job.Ps.EndInvoke($script:job.H) } catch { $script:meld.Fehler = [string]$_ }
        $script:job.Ps.Dispose(); $script:job.Rs.Dispose(); $script:job = $null
        Set-Fade $ui.Bahn 0; $ui.Start.IsEnabled = $true
        $r = $script:meld.Ergebnis
        if ($script:meld.Fehler) { $ui.Status.Text = $script:meld.Fehler }
        elseif ($r -and $r.Cancelled) { $ui.Status.Text = 'Abgebrochen' }
        elseif ($r) { Set-Fade $ui.Haken 1; $ui.Status.Text = "$($r.Copied) kopiert, $($r.Errors) Fehler" }
    }
}
$tick = New-Object Windows.Threading.DispatcherTimer; $tick.Interval = [TimeSpan]::FromMilliseconds(60); $tick.Add_Tick({ Update-Ui }); $tick.Start()
$ui.Stopp.Add_Click({ if ($script:meld) { $script:meld.Cancel = $true } })
function New-B([string]$n) { $d = Join-Path $base "B-$n"; [void][IO.Directory]::CreateDirectory($d); return $d }
function Wait-Ui([scriptblock]$cond, [double]$maxSec) {
    $frame = New-Object Windows.Threading.DispatcherFrame; $w = New-Object Windows.Threading.DispatcherTimer; $w.Interval = [TimeSpan]::FromMilliseconds(40)
    $end = (Get-Date).AddSeconds($maxSec)
    $w.Add_Tick({ if ((& $cond) -or (Get-Date) -gt $end) { $w.Stop(); $frame.Continue = $false } }.GetNewClosure()); $w.Start()
    [Windows.Threading.Dispatcher]::PushFrame($frame)
}
function Get-Fertig { return ($null -eq $script:job) }
function Test-Gleich([string]$b) {
    $a = Join-Path $base 'A'; $n = 0
    foreach ($f in [IO.Directory]::GetFiles($a, '*', 'AllDirectories')) {
        $z = $b + $f.Substring($a.Length)
        if (-not [IO.File]::Exists($z) -or (Get-FileHash -LiteralPath $f).Hash -ne (Get-FileHash -LiteralPath $z).Hash) { $n++ }
    }
    return $n
}

try {
    New-Daten
    if (-not $Auto) {
        $script:lauf = 0
        $ui.Start.Add_Click({ $script:lauf++; Start-Job2 ([guid]::NewGuid().ToString('N')) (Join-Path $base 'A') (New-B $script:lauf) })
        $win.Add_Closing({ if ($script:job) { $script:meld.Cancel = $true; [void]$script:job.H.AsyncWaitHandle.WaitOne(10000) } })
        [void]$win.ShowDialog()
        return
    }
    $A = Join-Path $base 'A'
    $win.ShowActivated = $false; $win.Show(); Wait-Ui { $false } 1.5
    $ui.Bahn.Opacity = 1
    [Bilder]::Start(); Wait-Ui { $false } 4; Write-Output ("Leerlauf:         " + [Bilder]::Ergebnis())

    # neu: eigener Thread
    $b = New-B 'thread'; [Bilder]::Start(); Start-Job2 ([guid]::NewGuid().ToString('N')) $A $b
    Wait-Ui { $script:meld.Frac -gt 0.3 -or (Get-Fertig) } 120
    if ($Bild) {
        $rt = New-Object Windows.Media.Imaging.RenderTargetBitmap([int]$ui.Root.ActualWidth, [int]$ui.Root.ActualHeight, 96, 96, [Windows.Media.PixelFormats]::Pbgra32); $rt.Render($ui.Root)
        $enc = New-Object Windows.Media.Imaging.PngBitmapEncoder; $enc.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($rt))
        $fs = [IO.File]::Create($Bild); try { $enc.Save($fs) } finally { $fs.Dispose() }
    }
    Wait-Ui { Get-Fertig } 180
    Write-Output ("Eigener Thread:   " + [Bilder]::Ergebnis())
    Write-Output "  Ergebnis: $($script:meld.Ergebnis.Copied) kopiert, $($script:meld.Ergebnis.Errors) Fehler, Meldung '$($script:meld.Fehler)', falsche Dateien: $(Test-Gleich $b)"

    # Abbrechen mitten im Lauf
    $b = New-B 'abbruch'; Start-Job2 ([guid]::NewGuid().ToString('N')) $A $b
    Wait-Ui { $script:meld.Frac -gt 0.3 -or (Get-Fertig) } 120
    $sw = [Diagnostics.Stopwatch]::StartNew(); $script:meld.Cancel = $true; Wait-Ui { Get-Fertig } 30
    Write-Output "Abbrechen:        nach $($sw.ElapsedMilliseconds) ms beendet, abgebrochen=$($script:meld.Ergebnis.Cancelled), Zwischendateien: $([IO.Directory]::GetFiles($b, '*.dirtoy-tmp', 'AllDirectories').Count)"

    # alt: gleicher Thread, Oberflaeche wird nur zwischendurch bedient
    . $kern -NoGui
    function Pump { [Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([action] { }, [Windows.Threading.DispatcherPriority]::Background) }
    function Add-Log([string]$aktion, [string]$datei, [string]$status) { $ui.Status.Text = "$aktion  $datei"; return $null }
    $ui.Bahn.BeginAnimation([Windows.UIElement]::OpacityProperty, $null); $ui.Bahn.Opacity = 1
    $b = New-B 'alt'; $t0 = New-Task 'alt'; $t0.A = $A; $t0.B = $b
    [Bilder]::Start(); $r = Run-Task $t0 $false; Wait-Ui { $false } 0.2
    Write-Output ("Wie bisher:       " + [Bilder]::Ergebnis())
    Write-Output "  Ergebnis: $($r.Copied) kopiert, $($r.Errors) Fehler"
    $win.Close()
} finally {
    try { [IO.Directory]::Delete($base, $true) } catch { Write-Output "Testordner nicht entfernt: $base" }
}
