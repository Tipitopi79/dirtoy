# ---- Anleitung, wenn der Zeitplan nicht angelegt werden konnte (z. B. ohne Admin-Rechte)
function Show-ManualSchedDialog($t, $s, [string]$err) {
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
    $dlg = New-Dlg 'Zeitplan von Hand anlegen' 'Width="720" Height="600" ResizeMode="NoResize"' '<DockPanel Margin="20">
      <WrapPanel DockPanel.Dock="Bottom" Margin="0,16,0,0"><Button x:Name="b1" Style="{StaticResource Primary}" Margin="0,0,8,8">Befehl kopieren</Button><Button x:Name="b2" Margin="0,0,8,8">Argumente kopieren</Button><Button x:Name="b3" Margin="0,0,8,8">Aufgabenplaner öffnen</Button><Button x:Name="b5" Margin="0,0,8,8">Beim Anmelden starten</Button><Button x:Name="b4" IsCancel="True" Margin="0,0,0,8">Schließen</Button></WrapPanel>
      <TextBox x:Name="tb" Style="{StaticResource Multi}"/></DockPanel>'
    $dlg.tb.Text = $txt
    $script:mCmd = $cmd; $script:mArgs = $psArgs; $script:mTask = $t; $script:mDlg = $dlg
    $dlg.b1.Add_Click({ try { [System.Windows.Forms.Clipboard]::SetText($script:mCmd); [void](Show-Msg 'Der Befehl liegt in der Zwischenablage.' 'DirToy') } catch { } })
    $dlg.b2.Add_Click({ try { [System.Windows.Forms.Clipboard]::SetText($script:mArgs); [void](Show-Msg 'Die Argumente liegen in der Zwischenablage.' 'DirToy') } catch { } })
    $dlg.b3.Add_Click({ try { Start-Process 'taskschd.msc' } catch { [void](Show-Msg ('Der Aufgabenplaner ließ sich nicht öffnen (Windows-Taste, "Aufgabenplanung" tippen).') 'DirToy') } })
    $dlg.b4.Add_Click({ $script:mDlg.Win.Close() })
    $dlg.b5.Add_Click({
        $lnk = New-AutostartLink $script:mTask
        if ($lnk) { Save-Tasks; [void](Show-Msg "Eingerichtet. DirToy führt die Aufgabe ab jetzt bei jeder Windows-Anmeldung aus.`n`n$lnk" 'DirToy') }
        else { [void](Show-Msg 'Der Eintrag im Autostart-Ordner ließ sich nicht anlegen.' 'DirToy' 'OK' 'Warning') }
    })
    Show-Dlg $dlg
}

