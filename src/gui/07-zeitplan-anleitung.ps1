# ---- Anleitung, wenn der Zeitplan nicht angelegt werden konnte (z. B. ohne Admin-Rechte)
function Show-ManualSchedDialog($t, $s, [string]$err, $owner) {
    $cmd = Get-SchtasksCommand $t $s
    $name = 'DirToy - ' + (([string]$t.Name -replace '[\\/:*?"<>|]', '_').Trim())
    $psArgs = "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$($script:scriptPath)`" -Task `"$($t.Id)`""
    $wann = Get-SchedText $s
    $txt = @(
        'Der Zeitplan konnte NICHT im Windows-Aufgabenplaner angelegt werden. DirToy hat daher nichts eingetragen.',
        '',
        "Grund: $err",
        '',
        'Meist fehlen auf diesem Rechner die nötigen Rechte. So geht es trotzdem von Hand:',
        '',
        'Möglichkeit 1 - Befehl (am einfachsten)',
        '  1. Windows-Taste drücken, "cmd" tippen, Enter (Eingabeaufforderung).',
        '  2. Button "Befehl kopieren" klicken, im Fenster mit Rechtsklick einfügen, Enter.',
        '',
        'Möglichkeit 2 - Aufgabenplaner-Fenster (Button "Aufgabenplaner öffnen")',
        ('  1. Rechts "Aufgabe erstellen ..." wählen. Name: ' + $name),
        ('  2. Reiter "Trigger" > Neu: ' + $wann),
        '  3. Reiter "Aktionen" > Neu > Programm starten:',
        '       Programm:  powershell.exe',
        ('       Argumente: ' + $psArgs),
        '       (Button "Argumente kopieren")',
        '  4. Mit OK speichern.',
        '',
        'Möglichkeit 3 - Notlösung ohne Aufgabenplaner',
        '  Button "Beim Anmelden starten": DirToy führt die Aufgabe dann bei jeder Windows-Anmeldung einmal aus (Autostart-Ordner).',
        '  Ein zeitlicher Plan oder ein Intervall ist damit nicht möglich.'
    ) -join "`r`n"
    $f = New-Object System.Windows.Forms.Form
    $f.Text = 'Zeitplan von Hand anlegen'; $f.ClientSize = New-Object System.Drawing.Size(640, 520); $f.StartPosition = 'CenterParent'
    $f.FormBorderStyle = 'FixedDialog'; $f.MaximizeBox = $false; $f.MinimizeBox = $false; $f.ShowInTaskbar = $false
    $f.BackColor = $th.Surface; $f.ForeColor = $th.Text; $f.Font = $fNormal
    $tb = New-Object System.Windows.Forms.TextBox; $tb.Multiline = $true; $tb.ReadOnly = $true; $tb.ScrollBars = 'Vertical'; $tb.BorderStyle = 'FixedSingle'
    $tb.BackColor = $th.Input; $tb.ForeColor = $th.Text; $tb.Font = $fNormal; $tb.Text = $txt
    [void](Add-To $f $tb 16 14 608 396)
    $tb.Select(0, 0)
    $b1 = New-Btn $f 16 424 140 34 'Befehl kopieren' $true $null
    $b2 = New-Btn $f 164 424 160 34 'Argumente kopieren' $false $th.Surface
    $b3 = New-Btn $f 332 424 190 34 'Aufgabenplaner öffnen' $false $th.Surface
    $b4 = New-Btn $f 530 424 94 34 'Schließen' $false $th.Surface
    $b5 = New-Btn $f 16 468 250 34 'Beim Anmelden starten' $false $th.Surface
    $script:mCmd = $cmd; $script:mArgs = $psArgs; $script:mTask = $t
    $b1.Add_Click({ try { [System.Windows.Forms.Clipboard]::SetText($script:mCmd); [void](Show-Msg 'Der Befehl liegt in der Zwischenablage.' 'DirToy') } catch { } })
    $b2.Add_Click({ try { [System.Windows.Forms.Clipboard]::SetText($script:mArgs); [void](Show-Msg 'Die Argumente liegen in der Zwischenablage.' 'DirToy') } catch { } })
    $b3.Add_Click({ try { Start-Process 'taskschd.msc' } catch { [void](Show-Msg ('Der Aufgabenplaner ließ sich nicht öffnen (Windows-Taste, "Aufgabenplanung" tippen).') 'DirToy') } })
    $b4.Add_Click({ $b4.FindForm().Close() })
    $b5.Add_Click({
        $lnk = New-AutostartLink $script:mTask
        if ($lnk) { Save-Tasks; [void](Show-Msg "Eingerichtet. DirToy führt die Aufgabe ab jetzt bei jeder Windows-Anmeldung aus.`n`n$lnk" 'DirToy') }
        else { [void](Show-Msg 'Der Eintrag im Autostart-Ordner ließ sich nicht anlegen.' 'DirToy' 'OK' 'Warning') }
    })
    $f.Add_HandleCreated({ try { $v = if ($isDark) { 1 } else { 0 }; [void][Win32.Dwm]::DwmSetWindowAttribute($this.Handle, 20, [ref]$v, 4) } catch { } })
    [void]$f.ShowDialog($owner)
    $f.Dispose()
}
