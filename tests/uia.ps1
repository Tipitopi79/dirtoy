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
        $e = $root.FindFirst('Descendants', (New-Object System.Windows.Automation.PropertyCondition($A::AutomationIdProperty, [string]$c.id)))
        $r = @{ ok = $true; found = [bool]$e }
        if ($e) {
            $p = $null
            switch ($c.op) {
                'click' {
                    if ($e.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$p)) { $p.Invoke() }
                    elseif ($e.TryGetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern, [ref]$p)) { $p.Select() }
                    else { throw 'nicht klickbar' }
                }
                'set' { $e.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue([string]$c.value) }
            }
            $r.name = $e.Current.Name; $r.enabled = $e.Current.IsEnabled; $r.visible = -not $e.Current.IsOffscreen
            if ($e.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$p)) { $r.value = $p.Current.Value }
        }
    } catch { $r = @{ ok = $false; error = [string]$_.Exception.Message } }
    [Console]::Out.WriteLine((ConvertTo-Json -Compress -InputObject $r))
}
