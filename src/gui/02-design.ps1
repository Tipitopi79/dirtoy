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
function Get-StatusColor([string]$st) {
    if (-not $script:th) { return $null }
    if ($st -like 'FEHLER*') { return $script:th.Err }
    if ($st -eq 'OK') { return $script:th.Ok }
    if ($st -eq 'geplant' -or $st -like 'übersprungen*' -or $st -like 'abgebrochen*') { return $script:th.Muted }
    return $script:th.Text
}

$fNormal = New-Object System.Drawing.Font('Segoe UI', 10)
$fSmall  = New-Object System.Drawing.Font('Segoe UI', 9)
$fBold   = New-Object System.Drawing.Font('Segoe UI Semibold', 10)
$fTitle  = New-Object System.Drawing.Font('Segoe UI Semibold', 18)

$AN = [System.Windows.Forms.AnchorStyles]
$A_TL = $AN::Top -bor $AN::Left; $A_TLR = $A_TL -bor $AN::Right; $A_TR = $AN::Top -bor $AN::Right
$A_TLB = $A_TL -bor $AN::Bottom; $A_BL = $AN::Bottom -bor $AN::Left; $A_BR = $AN::Bottom -bor $AN::Right; $A_BLR = $A_BL -bor $AN::Right; $A_ALL = $A_TLR -bor $AN::Bottom

function Add-To($parent, $c, $x, $y, $w, $h) {
    $c.Location = New-Object System.Drawing.Point($x, $y)
    if ($w -gt 0) { $c.Size = New-Object System.Drawing.Size($w, $h) }
    $parent.Controls.Add($c); return $c
}
function New-Label($parent, $x, $y, $w, $text, $muted) {
    $l = New-Object System.Windows.Forms.Label; $l.Text = $text; $l.AutoSize = $false; $l.Height = 20
    $l.BackColor = [System.Drawing.Color]::Transparent
    $l.Font = if ($muted) { $fSmall } else { $fNormal }
    $l.ForeColor = if ($muted) { $th.Muted } else { $th.Text }
    Add-To $parent $l $x $y $w 20
}
function New-Input($parent, $x, $y, $w) {
    $t = New-Object System.Windows.Forms.TextBox; $t.BorderStyle = 'FixedSingle'
    $t.BackColor = $th.Input; $t.ForeColor = $th.Text; $t.Font = $fNormal
    Add-To $parent $t $x $y $w 28
}
function New-Btn($parent, $x, $y, $w, $h, $text, [bool]$primary, $fill) {
    $b = New-Object System.Windows.Forms.Button; $b.Text = $text; $b.FlatStyle = 'Flat'; $b.Cursor = 'Hand'
    $b.UseVisualStyleBackColor = $false; $b.Font = $fBold
    if ($primary) {
        $b.BackColor = $th.Accent; $b.ForeColor = $th.AccentText
        $b.FlatAppearance.BorderSize = 0; $b.FlatAppearance.MouseOverBackColor = $th.AccentHover; $b.FlatAppearance.MouseDownBackColor = $th.AccentHover
    } else {
        $b.BackColor = $fill; $b.ForeColor = $th.Text
        $b.FlatAppearance.BorderSize = 1; $b.FlatAppearance.BorderColor = $th.Border
        $b.FlatAppearance.MouseOverBackColor = $th.SelBg; $b.FlatAppearance.MouseDownBackColor = $th.SelBg
    }
    Add-To $parent $b $x $y $w $h
}
function New-Card($parent, $x, $y, $w, $h) {
    $p = New-Object System.Windows.Forms.Panel; $p.BackColor = $th.Surface
    Add-To $parent $p $x $y $w $h
}

