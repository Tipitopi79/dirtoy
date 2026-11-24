# Bedient WPF-Fenster fuer die Fenstertests (UI Automation). Liest Befehle als JSON-Zeilen, antwortet mit JSON-Zeilen.
#   {"op":"click|set|get","hwnd":123,"id":"btnRun","value":"..."}
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
[Console]::InputEncoding = New-Object System.Text.UTF8Encoding($false)
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$A = [System.Windows.Automation.AutomationElement]
[Console]::Out.WriteLine('{"ok":true}')
while ($null -ne ($line = [Console]::In.ReadLine())) {
    try {
        $c = ConvertFrom-Json $line
        $root = $A::FromHandle([IntPtr][long]$c.hwnd)
        $prop = if ($c.byname) { $A::NameProperty } else { $A::AutomationIdProperty }
        $cond = New-Object System.Windows.Automation.PropertyCondition($prop, [string]$c.id)
        if ($c.byname) { $cond = New-Object System.Windows.Automation.AndCondition($cond, (New-Object System.Windows.Automation.OrCondition((New-Object System.Windows.Automation.PropertyCondition($A::ControlTypeProperty, [System.Windows.Automation.ControlType]::Button)), (New-Object System.Windows.Automation.PropertyCondition($A::ControlTypeProperty, [System.Windows.Automation.ControlType]::CheckBox))))) }
        $e = $null; $all = $root.FindAll('Descendants', $cond); $ix = if ($c.index) { [int]$c.index } else { 0 }
        if ($all.Count -gt $ix) { $e = $all[$ix] }
        $r = @{ ok = $true; found = [bool]$e }
        if ($e) {
            $p = $null
            switch ($c.op) {
                'click' {
                    if ($e.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$p)) { $p.Invoke() }
                    elseif ($e.TryGetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern, [ref]$p)) { $p.Select() }
                    elseif ($e.TryGetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern, [ref]$p)) { $p.Toggle() }
                    else { throw 'nicht klickbar' }
                }
                'focus' { $e.SetFocus() }
                'expand' { $w = [System.Windows.Automation.TreeWalker]::RawViewWalker; $x = $e; while ($x -and -not $x.TryGetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern, [ref]$p)) { $x = $w.GetParent($x) }; $p.Expand() }
                'set' { $e.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue([string]$c.value) }
            }
            $r.name = $e.Current.Name; $r.enabled = $e.Current.IsEnabled; $r.visible = -not $e.Current.IsOffscreen
            if ($e.TryGetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern, [ref]$p)) { $r.on = ($p.Current.ToggleState -eq 'On') }
            if ($e.TryGetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern, [ref]$p)) { $r.on = $p.Current.IsSelected }
            if ($e.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$p)) { $r.value = $p.Current.Value }
        }
    } catch { $r = @{ ok = $false; error = [string]$_.Exception.Message } }
    [Console]::Out.WriteLine((ConvertTo-Json -Compress -InputObject $r))
}
