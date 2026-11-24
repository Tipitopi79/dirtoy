# ---- Update-Fenster (mode: new = neue Version da, current = aktuell, error = Pruefung fehlgeschlagen)
function Show-UpdateDialog($info, [string]$mode) {
    $d = New-Object System.Windows.Forms.Form
    $d.Text = 'DirToy - Update'; $d.ClientSize = New-Object System.Drawing.Size(560, 420)
    $d.FormBorderStyle = 'FixedDialog'; $d.MaximizeBox = $false; $d.MinimizeBox = $false
    $d.StartPosition = 'CenterParent'; $d.ShowInTaskbar = $false; $d.BackColor = $th.Surface; $d.ForeColor = $th.Text; $d.Font = $fNormal
    $head = switch ($mode) {
        'new' { "Neue Version verfügbar: $($info.Version)" }
        'current' { 'DirToy ist aktuell' }
        default { 'Update-Prüfung nicht möglich' }
    }
    $sub = switch ($mode) {
        'new' { "Installiert ist Version $($script:version)." }
        'current' { "Du hast die neueste Version ($($script:version))." }
        default { 'Es konnte keine Verbindung zu GitHub hergestellt werden (oder es gibt noch keinen Release).' }
    }
    $l1 = New-Label $d 24 18 512 $head $false; $l1.Font = $fBold; $l1.ForeColor = $th.Accent
    $l2 = New-Label $d 24 44 512 $sub $true
    $btnY = 366
    if ($mode -eq 'new') {
        [void](New-Label $d 24 76 512 'Änderungen' $true)
        $rb = New-Object System.Windows.Forms.RichTextBox
        $rb.ReadOnly = $true; $rb.BorderStyle = 'None'; $rb.BackColor = $th.Input; $rb.ForeColor = $th.Text; $rb.Font = $fSmall; $rb.DetectUrls = $false
        $rb.Location = New-Object System.Drawing.Point(24, 100); $rb.Size = New-Object System.Drawing.Size(512, 190)
        $notes = [string]$info.Notes; if ($notes.Length -gt 3000) { $notes = $notes.Substring(0, 3000) + ' ...' }
        $rb.Text = $(if ($notes.Trim()) { $notes } else { '(keine Beschreibung)' })
        $d.Controls.Add($rb)
    }
    $cb = New-Object System.Windows.Forms.CheckBox
    $cb.Text = 'Beim Start automatisch nach Updates suchen'; $cb.AutoSize = $true; $cb.BackColor = [System.Drawing.Color]::Transparent
    $cb.Checked = [bool](Get-Setting 'UpdateCheck' $true)
    $cb.Location = New-Object System.Drawing.Point(24, 308); $d.Controls.Add($cb)
    $script:updAction = ''
    $script:updForm = $d
    if ($mode -eq 'new') {
        $bu = New-Btn $d 24 $btnY 170 38 'Jetzt aktualisieren' $true $null
        $bw = New-Btn $d 204 $btnY 170 38 'Release-Seite' $false $th.Surface
        $bl = New-Btn $d 384 $btnY 152 38 'Später' $false $th.Surface
        $bu.Add_Click({ $script:updAction = 'install'; $script:updForm.Close() })
        $bw.Add_Click({ $script:updAction = 'web'; $script:updForm.Close() })
        $bl.Add_Click({ $script:updForm.Close() })
        $d.CancelButton = $bl
    } else {
        $bl = New-Btn $d 384 $btnY 152 38 'Schließen' $true $null
        $bl.Add_Click({ $script:updForm.Close() })
        $d.CancelButton = $bl
    }
    $d.Add_HandleCreated({
        try { $v = if ($isDark) { 1 } else { 0 }; [void][Win32.Dwm]::DwmSetWindowAttribute($script:updForm.Handle, 20, [ref]$v, 4) } catch { }
    })
    [void]$d.ShowDialog($form)
    Set-Setting 'UpdateCheck' $cb.Checked
    $d.Dispose()
    return $script:updAction
}
