# ---- Meldungen im DirToy-Look (wie MessageBox): OK oder YesNo, Rueckgabe 'OK', 'Yes' oder 'No'. Esc/Schliessen = Nein
function Show-Msg([string]$text, [string]$title = 'DirToy', [string]$buttons = 'OK', [string]$icon = 'Information', [string]$default = 'Button1') {
    $d = New-Object System.Windows.Forms.Form
    $d.Text = $title; $d.FormBorderStyle = 'FixedDialog'; $d.MaximizeBox = $false; $d.MinimizeBox = $false; $d.ShowInTaskbar = $false
    $d.StartPosition = 'CenterParent'; $d.BackColor = $th.Surface; $d.ForeColor = $th.Text; $d.Font = $fNormal
    $sz = [System.Windows.Forms.TextRenderer]::MeasureText($text, $fNormal, (New-Object System.Drawing.Size(400, 0)), 'WordBreak, NoPrefix')
    $h = [math]::Max(48, $sz.Height + 8)
    $d.ClientSize = New-Object System.Drawing.Size(520, ($h + 112))
    $g = New-Object System.Windows.Forms.Label; $g.BackColor = [System.Drawing.Color]::Transparent; $g.UseMnemonic = $false
    $g.Font = New-Object System.Drawing.Font('Segoe MDL2 Assets', 26)
    switch ($icon) {
        'Warning'  { $g.Text = [string][char]0xE7BA; $g.ForeColor = $(if ($isDark) { C '#FFB900' } else { C '#9D5D00' }) }
        'Error'    { $g.Text = [string][char]0xEA39; $g.ForeColor = $th.Err }
        'Question' { $g.Text = [string][char]0xE897; $g.ForeColor = $th.Accent }
        default    { $g.Text = [string][char]0xE946; $g.ForeColor = $th.Accent }
    }
    [void](Add-To $d $g 20 24 64 48)
    $l = New-Label $d 92 24 408 $text $false; $l.UseMnemonic = $false; $l.Size = New-Object System.Drawing.Size(408, $h)
    $y = $h + 52
    if ($buttons -eq 'YesNo') {
        $no2 = ($default -eq 'Button2')
        $bn = New-Btn $d 384 $y 112 38 'Nein' $no2 $th.Surface; $bn.DialogResult = 'No'
        $by = New-Btn $d 260 $y 112 38 'Ja' (-not $no2) $th.Surface; $by.DialogResult = 'Yes'
        $by.TabIndex = 1; $bn.TabIndex = 2
        $def = if ($no2) { $bn } else { $by }; $d.CancelButton = $bn
    } else {
        $def = New-Btn $d 384 $y 112 38 'OK' $true $null; $def.DialogResult = 'OK'; $d.CancelButton = $def
    }
    $d.AcceptButton = $def; $d.ActiveControl = $def
    $d.Add_HandleCreated({ try { $v = if ($isDark) { 1 } else { 0 }; [void][Win32.Dwm]::DwmSetWindowAttribute($this.Handle, 20, [ref]$v, 4) } catch { } })
    $owner = [System.Windows.Forms.Form]::ActiveForm; if (-not $owner) { $owner = $form }
    if ($icon -eq 'Warning' -or $icon -eq 'Error') { [System.Media.SystemSounds]::Exclamation.Play() }
    try { $r = [string]$d.ShowDialog($owner) } finally { $d.Dispose() }
    if ($buttons -ne 'YesNo') { return 'OK' }
    if ($r -eq 'Yes') { return 'Yes' }
    return 'No'
}

