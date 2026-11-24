# ---- Theme (folgt dem Windows-Hell/Dunkel-Modus)
function C([string]$hex) { [System.Drawing.ColorTranslator]::FromHtml($hex) }
function Get-ThemeSetting {
    $v = [string](Get-Setting 'Theme' 'auto')
    if ($v -in @('auto', 'hell', 'dunkel')) { return $v } else { return 'auto' }
}
function Set-ThemeSetting([string]$v) { Set-Setting 'Theme' $v }
$script:themeSetting = Get-ThemeSetting
$isDark = $false
if ($script:themeSetting -eq 'dunkel') { $isDark = $true }
elseif ($script:themeSetting -eq 'auto') {
    try { $isDark = ((Get-ItemPropertyValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name AppsUseLightTheme) -eq 0) } catch { }
}
if ($isDark) {
    $script:th = @{ Bg = (C '#2D2D30'); Surface = (C '#3A3A3D'); Input = (C '#28282B'); Text = (C '#F2F2F2'); Muted = (C '#B4B4B4')
        Border = (C '#5A5A5E'); Accent = (C '#4CC2FF'); AccentText = (C '#000000'); AccentHover = (C '#7AD2FF'); SelBg = (C '#4A4A4F')
        Ok = (C '#6CCB5F'); Err = (C '#FF99A4') }
} else {
    $script:th = @{ Bg = (C '#F3F3F3'); Surface = (C '#FFFFFF'); Input = (C '#FFFFFF'); Text = (C '#1B1B1B'); Muted = (C '#6B6B6B')
        Border = (C '#D6D6D6'); Accent = (C '#0067C0'); AccentText = (C '#FFFFFF'); AccentHover = (C '#1A7FD6'); SelBg = (C '#E5F1FB')
        Ok = (C '#0F7B0F'); Err = (C '#C42B1C') }
}
$th = $script:th
