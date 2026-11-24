# ---- Update-Fenster (mode: new = neue Version da, current = aktuell, error = Pruefung fehlgeschlagen)
function Show-UpdateDialog($info, [string]$mode) {
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
    $new = ($mode -eq 'new')
    $dlg = New-Dlg 'DirToy - Update' 'Width="600" SizeToContent="Height" ResizeMode="NoResize"' ('<StackPanel Margin="24"><TextBlock x:Name="head" FontSize="20" FontWeight="SemiBold" Foreground="{DynamicResource Accent}"/><TextBlock x:Name="sub" Style="{StaticResource MutedText}" TextWrapping="Wrap" Margin="0,4,0,0"/>' +
        $(if ($new) { '<TextBlock Text="Änderungen" Style="{StaticResource MutedText}" Margin="0,16,0,6"/><TextBox x:Name="notes" Style="{StaticResource Multi}" Height="240" AutomationProperties.Name="Änderungen"/>' } else { '' }) +
        '<CheckBox x:Name="auto" Margin="0,18,0,0">Beim Start automatisch nach Updates suchen</CheckBox><DockPanel Margin="0,20,0,0" LastChildFill="False">' +
        $(if ($new) { '<Button x:Name="go" Style="{StaticResource Primary}" IsDefault="True" Margin="0,0,8,0">Jetzt aktualisieren</Button><Button x:Name="web">Release-Seite</Button><Button x:Name="later" DockPanel.Dock="Right" IsCancel="True">Später</Button>' } else { '<Button x:Name="later" DockPanel.Dock="Right" Style="{StaticResource Primary}" IsCancel="True" IsDefault="True">Schließen</Button>' }) + '</DockPanel></StackPanel>')
    $dlg.head.Text = $head; $dlg.sub.Text = $sub
    $dlg.auto.IsChecked = [bool](Get-Setting 'UpdateCheck' $true)
    $script:updAction = ''; $script:updDlg = $dlg
    if ($new) {
        $notes = [string]$info.Notes; if ($notes.Length -gt 3000) { $notes = $notes.Substring(0, 3000) + ' ...' }
        $dlg.notes.Text = $(if ($notes.Trim()) { $notes } else { '(keine Beschreibung)' })
        $dlg.go.Add_Click({ $script:updAction = 'install'; $script:updDlg.Win.Close() })
        $dlg.web.Add_Click({ $script:updAction = 'web'; $script:updDlg.Win.Close() })
    }
    $dlg.later.Add_Click({ $script:updDlg.Win.Close() })
    Show-Dlg $dlg
    Set-Setting 'UpdateCheck' ([bool]$dlg.auto.IsChecked)
    return $script:updAction
}
